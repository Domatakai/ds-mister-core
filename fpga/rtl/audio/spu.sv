//============================================================================
// NDS MiSTer Test — sound processing unit (SPU), sixteen channels
//
// The DS mixes sixteen hardware channels. Each is a small sampler: a 16-bit
// counter runs in the 16.757 MHz half-rate domain (33.513982 MHz / 2), and
// every wrap the channel takes one more sample out of main RAM, scales it
// and drops it into the stereo accumulator.
//
// Register window — ARM7 only, 0x04000400..0x0400051F (main_bus decodes it;
// from the ARM9 the same addresses are the geometry engine, as on hardware):
//
//   4000400h+x*10h  SOUNDxCNT  (32-bit)
//     0-6    volume multiplier  (N/128; 127 counts as 128, 0 = silent)
//     7      unused
//     8-9    volume divider     (0=/1, 1=/2, 2=/4, 3=/16)
//     10-14  unused
//     15     hold               (keep the last sample after a one-shot end)
//     16-22  panning            (0 = left, 64 = centre, 127 counts as 128)
//     23     unused
//     24-26  wave duty          (PSG only — PSG is not modelled)
//     27-28  repeat mode        (0 manual, 1 loop infinite, 2 one-shot,
//                                3 prohibited; both non-loop values stop)
//     29-30  format             (0 PCM8, 1 PCM16, 2 IMA-ADPCM, 3 PSG/noise)
//     31     start/busy         (write 1 to start, 0 to stop; reads live)
//   4000404h  SOUNDxSAD  (32-bit, bits 26:0, word-aligned) sample address
//   4000408h  SOUNDxTMR  (16-bit) reload: sample period = 65536-TMR ticks
//   400040Ah  SOUNDxPNT  (16-bit) loop start, in words
//   400040Ch  SOUNDxLEN  (32-bit, bits 21:0) length, in words
//   4000500h  SOUNDCNT   (bits 0-6 master volume, bit 15 master enable)
//   4000504h  SOUNDBIAS  (stored and read back; see the note below)
//
// Playback length is GBATEK's: one-shot plays PNT+LEN words; in loop mode
// the first PNT words run once and the following LEN words repeat forever.
// Both fields count words (4 bytes), so a segment is 4*PNT and 4*LEN bytes.
// PNT+LEN below four words hangs the channel — busy stays set, no sound
// comes out — exactly as documented, and format 3 (PSG/noise) holds the
// same way here because this core does not synthesise a square wave yet.
//
// Sample formats:
//   PCM8    signed 8-bit, used as sample<<8 (so 80h = -32768)    1 byte
//   PCM16   signed 16-bit little-endian                          2 bytes
//   ADPCM   one 32-bit header word (signed predictor in bits 0-15, step
//           index in bits 16-22) followed by packed nibbles, low nibble
//           first. A segment of W words therefore decodes 8*(W-1) samples,
//           the count GBATEK documents.
//           Looping: GBATEK says to set the loop start to the data part
//           rather than the header, "the index and pcm16 values are reloaded
//           to the values that have originally appeared at that location" —
//           so the decoder state as the position passes 4*PNT is snapshotted
//           and restored on every loop, and the bytes there decode as
//           ordinary nibbles on the first pass. melonDS (ADPCMValLoop /
//           ADPCMIndexLoop, refreshed when Pos == LoopPos) and DeSmuME
//           (loop_pcm16b / loop_index, captured at pos == loopstart<<3) both
//           do exactly this. A loop point of 0 is the exception: it is where
//           the header lives, so the header is read again (melonDS re-reads
//           it whenever Pos == 0).
//           Nibble decode is the documented staged-shift form, stepped from
//           an 89-entry size table:
//             step = table[index]; diff = step>>3
//             + (step>>2 if bit0) + (step>>1 if bit1) + step if bit2
//             predictor +/- diff (bit3 = sign), clamped to +/-7FFF
//             index += {-1,-1,-1,-1,+2,+4,+6,+8}[nibble&7], clamped to 88
//
// Mixing chain, signed end to end:
//   sample -> x volume/128 -> >> divider -> pan left/right
//   left = v*(128-pan)/128, right = v*pan/128 (centre = half each)
//   the sixteen channels sum, then x master volume/128, then the OSD master
//   volume, then clamp to 16-bit. One channel at full volume and centre pan
//   is half scale per side, so two can reach full scale before clipping;
//   the hardware clips there too and games sit well below it.
//
// Structure: sixteen parallel decoders would need sixteen step-table ROMs
// and forty-eight multipliers, so the channels are serviced one at a time by
// a shared four-phase engine — latch, decode, scale, pan/write-back — with a
// single 89-entry ROM, one nibble decoder and three multipliers for the
// whole SPU. A channel whose counter wraps raises `c_evt`; the engine walks
// a round-robin over the pending channels and the counter is held while its
// event waits, so no sample is lost, only delayed by a few clocks.
//
// Every channel-state array is written from one sequential block (software
// register writes, the service write-back and the fetch hand-off are made
// mutually exclusive per channel), which is what keeps the arrays single
// driver for synthesis.
//
// Sample fetches go out as their own mem_arbiter master, lowest priority,
// one 16-bit word per request: two PCM8 samples, one PCM16 sample or four
// ADPCM nibbles. The word is taken from main RAM at SAD+pos, mirrored inside
// 4 MB. A channel that is due before its word has landed holds the previous
// sample for that tick — a one-sample stall under bus contention, never a
// wrong sample. A word also belongs to the channel state it was requested
// for, so a register write to that channel — a key-on onto a channel that is
// still playing is the usual case — drops a word that is parked or in flight
// for it, and the new playback cannot begin by replaying the old one's buffer.
//
// Not modelled: sound capture (4000508h..), the SOUNDCNT output-source
// routing bits (8-13, stored and read back only), PSG duty/noise, the
// sound-bias offset (SOUNDBIAS is stored; the MiSTer audio path takes signed
// samples), DSi sound extensions, and the hardware mixer's own 1.048 MHz
// rate — this core mixes at 48 kHz, the rate the audio path runs at, while
// the channel counters keep the hardware's half-rate timing.
//============================================================================
module spu (
	input             clk,
	input             reset,

	// ---- ARM7 register window (halfword beats, decoded by main_bus) ----
	input             reg_acc,
	input             reg_we,
	input      [15:0] reg_addr,
	input      [15:0] reg_wdata,
	output reg [15:0] reg_rdata,

	// ---- sample fetch master -> mem_arbiter (main RAM, 16-bit words) ----
	output reg        mem_req,
	output reg [24:0] mem_addr,
	input             mem_ready,
	input      [15:0] mem_rdata,

	// ---- OSD ----
	input      [3:0]  volume,     // 0..10 -> 0%..100%
	input      [1:0]  mix_mode,   // Stereo/Mono/Headphones (not modelled)

	// ---- output ----
	output reg        sample_tick, // 48 kHz strobe for the audio filter
	output reg [15:0] audio_l,
	output reg [15:0] audio_r
);

// GBATEK 40004x0h bit 29-30
localparam FMT_PCM8  = 2'd0,
           FMT_PCM16 = 2'd1,
           FMT_ADPCM = 2'd2,
           FMT_PSG   = 2'd3;

//------------------------------------------------------------------
// ADPCM tables
//------------------------------------------------------------------
reg [15:0] adpcm_step [0:88];
reg  [3:0] adpcm_didx [0:8];

initial begin
	adpcm_step[ 0] = 16'h0007; adpcm_step[ 1] = 16'h0008;
	adpcm_step[ 2] = 16'h0009; adpcm_step[ 3] = 16'h000A;
	adpcm_step[ 4] = 16'h000B; adpcm_step[ 5] = 16'h000C;
	adpcm_step[ 6] = 16'h000D; adpcm_step[ 7] = 16'h000E;
	adpcm_step[ 8] = 16'h0010; adpcm_step[ 9] = 16'h0011;
	adpcm_step[10] = 16'h0013; adpcm_step[11] = 16'h0015;
	adpcm_step[12] = 16'h0017; adpcm_step[13] = 16'h0019;
	adpcm_step[14] = 16'h001C; adpcm_step[15] = 16'h001F;
	adpcm_step[16] = 16'h0022; adpcm_step[17] = 16'h0025;
	adpcm_step[18] = 16'h0029; adpcm_step[19] = 16'h002D;
	adpcm_step[20] = 16'h0032; adpcm_step[21] = 16'h0037;
	adpcm_step[22] = 16'h003C; adpcm_step[23] = 16'h0042;
	adpcm_step[24] = 16'h0049; adpcm_step[25] = 16'h0050;
	adpcm_step[26] = 16'h0058; adpcm_step[27] = 16'h0061;
	adpcm_step[28] = 16'h006B; adpcm_step[29] = 16'h0076;
	adpcm_step[30] = 16'h0082; adpcm_step[31] = 16'h008F;
	adpcm_step[32] = 16'h009D; adpcm_step[33] = 16'h00AD;
	adpcm_step[34] = 16'h00BE; adpcm_step[35] = 16'h00D1;
	adpcm_step[36] = 16'h00E6; adpcm_step[37] = 16'h00FD;
	adpcm_step[38] = 16'h0117; adpcm_step[39] = 16'h0133;
	adpcm_step[40] = 16'h0151; adpcm_step[41] = 16'h0173;
	adpcm_step[42] = 16'h0198; adpcm_step[43] = 16'h01C1;
	adpcm_step[44] = 16'h01EE; adpcm_step[45] = 16'h0220;
	adpcm_step[46] = 16'h0256; adpcm_step[47] = 16'h0292;
	adpcm_step[48] = 16'h02D4; adpcm_step[49] = 16'h031C;
	adpcm_step[50] = 16'h036C; adpcm_step[51] = 16'h03C3;
	adpcm_step[52] = 16'h0424; adpcm_step[53] = 16'h048E;
	adpcm_step[54] = 16'h0502; adpcm_step[55] = 16'h0583;
	adpcm_step[56] = 16'h0610; adpcm_step[57] = 16'h06AB;
	adpcm_step[58] = 16'h0756; adpcm_step[59] = 16'h0812;
	adpcm_step[60] = 16'h08E0; adpcm_step[61] = 16'h09C3;
	adpcm_step[62] = 16'h0ABD; adpcm_step[63] = 16'h0BD0;
	adpcm_step[64] = 16'h0CFF; adpcm_step[65] = 16'h0E4C;
	adpcm_step[66] = 16'h0FBA; adpcm_step[67] = 16'h114C;
	adpcm_step[68] = 16'h1307; adpcm_step[69] = 16'h14EE;
	adpcm_step[70] = 16'h1706; adpcm_step[71] = 16'h1954;
	adpcm_step[72] = 16'h1BDC; adpcm_step[73] = 16'h1EA5;
	adpcm_step[74] = 16'h21B6; adpcm_step[75] = 16'h2515;
	adpcm_step[76] = 16'h28CA; adpcm_step[77] = 16'h2CDF;
	adpcm_step[78] = 16'h315B; adpcm_step[79] = 16'h364B;
	adpcm_step[80] = 16'h3BB9; adpcm_step[81] = 16'h41B2;
	adpcm_step[82] = 16'h4844; adpcm_step[83] = 16'h4F7E;
	adpcm_step[84] = 16'h5771; adpcm_step[85] = 16'h602F;
	adpcm_step[86] = 16'h69CE; adpcm_step[87] = 16'h7462;
	adpcm_step[88] = 16'h7FFF;

	adpcm_didx[0] = 4'd1; adpcm_didx[1] = 4'd1;   // -1 (subtracted)
	adpcm_didx[2] = 4'd1; adpcm_didx[3] = 4'd1;
	adpcm_didx[4] = 4'd2; adpcm_didx[5] = 4'd4;
	adpcm_didx[6] = 4'd6; adpcm_didx[7] = 4'd8;
	adpcm_didx[8] = 4'd0;
end

//------------------------------------------------------------------
// Channel register file and live state (16 entries)
//------------------------------------------------------------------
reg [31:0] c_cnt [0:15];   // SOUNDxCNT as written (bit 31 mirrored in c_busy)
reg [26:0] c_sad [0:15];   // SOUNDxSAD
reg [15:0] c_tmr [0:15];   // SOUNDxTMR
reg [15:0] c_pnt [0:15];   // SOUNDxPNT
reg [21:0] c_len [0:15];   // SOUNDxLEN

reg        c_busy [0:15];  // playing
reg        c_hang [0:15];  // busy without sound (short length or PSG)
reg [15:0] c_tc   [0:15];  // live counter (counts up, reloads at TMR)
reg [23:0] c_pos  [0:15];  // bytes consumed from SAD
reg [1:0]  c_hdr  [0:15];  // ADPCM header words still to read
reg [15:0] c_buf  [0:15];  // the word the units come out of
reg [2:0]  c_rem  [0:15];  // units left in c_buf
reg [1:0]  c_uix  [0:15];  // unit index inside c_buf
reg [16:0] c_pred [0:15];  // ADPCM predictor (signed)
reg [7:0]  c_aix  [0:15];  // ADPCM step index 0..88
reg [16:0] c_lpred[0:15];  // ADPCM loop-point snapshot, predictor
reg [7:0]  c_laix [0:15];  // ADPCM loop-point snapshot, step index
reg        c_evt  [0:15];  // sample due, waiting for the service engine
reg        c_need [0:15];  // wants a fetch
reg        c_zf   [0:15];  // one-shot ended: silence after the next mix tick
reg signed [16:0] c_l [0:15];  // scaled contribution, left
reg signed [16:0] c_r [0:15];  // scaled contribution, right

// global registers
reg [15:0] snd_cnt  = 16'h0000;  // SOUNDCNT
reg [15:0] snd_bias = 16'h0000;  // SOUNDBIAS
// raised by the mixer on the tick that latches a mix; the channel block uses
// it to silence a one-shot that has just played its last sample
reg        mx_took  = 1'b0;

// the mixer declares its own state up here: the service engine below has to
// know when a mix pass is running so it does not change a channel mid-pass
// (the pass reads one channel per clock, so a late write would be summed at a
// different instant from its neighbours)
localparam MX_IDLE  = 3'd0,
           MX_SCAN  = 3'd1,   // one channel per clock
           MX_LATCH = 3'd2,   // the pass is complete: publish it
           MX_MUL1  = 3'd3,
           MX_MUL2  = 3'd4;
reg  [2:0] mx_st = MX_IDLE;

//------------------------------------------------------------------
// Addresses inside the window
//
// 0x400..0x4FF are the sixteen channel blocks (bit 8 clear); 0x500/0x504
// are SOUNDCNT/SOUNDBIAS; 0x508+ are the capture units, which read zero.
//------------------------------------------------------------------
wire        is_chan = (reg_addr[15:9] == 7'd2) && !reg_addr[8];
wire        is_scnt = (reg_addr[15:0] == 16'h0500);
wire        is_sbia = (reg_addr[15:0] == 16'h0504);
wire [3:0]  wr_ch   = reg_addr[7:4];
wire [2:0]  wr_hw   = reg_addr[3:1];
wire        wr_en   = reg_acc && reg_we;

// read-side snapshot of the addressed channel
wire [31:0] rd_cnt  = c_cnt [reg_addr[7:4]];
wire [26:0] rd_sad  = c_sad [reg_addr[7:4]];
wire [15:0] rd_tmr  = c_tmr [reg_addr[7:4]];
wire [15:0] rd_pnt  = c_pnt [reg_addr[7:4]];
wire [21:0] rd_len  = c_len [reg_addr[7:4]];
wire        rd_busy = c_busy[reg_addr[7:4]];

//------------------------------------------------------------------
// Ticks
//
// The core now runs on the DS's 67.0274 MHz, so the two rates fall out exactly:
//
//   half-rate domain   16.756991 MHz = 67.0274 / 4, a plain divider (the DS's
//                      own 33.513982 / 2)
//   sample tick        exactly 48 kHz, the rate the audio path runs at, by
//                      accumulating 48000 against 67027400
//------------------------------------------------------------------
reg  [1:0] hdiv  = 2'd0;
reg        htick = 1'b0;

reg  [26:0] aacc  = 27'd0;
reg         atick = 1'b0;
wire [26:0] asum  = aacc + 27'd48000;

always @(posedge clk) begin
	hdiv  <= hdiv + 2'd1;
	htick <= (hdiv == 2'd3);

	atick <= 1'b0;
	if (asum >= 27'd67_027_400) begin
		aacc  <= asum - 27'd67_027_400;
		atick <= 1'b1;
	end else begin
		aacc <= asum;
	end
end

//------------------------------------------------------------------
// Service engine
//
// One pending channel per pass, four phases: latch the channel's state,
// decode one unit, scale it by volume and divider, pan it into left/right
// and write the state back. One unit is one sample, or one ADPCM header
// word.
//------------------------------------------------------------------
localparam SV_IDLE = 3'd0, SV_LATCH = 3'd1, SV_DEC = 3'd2,
           SV_SCL  = 3'd3, SV_PAN   = 3'd4;

reg  [2:0] sv_st  = SV_IDLE;
reg  [3:0] sv_ch  = 4'd0;
reg  [3:0] sv_ptr = 4'd0;

integer pi;
reg  [3:0] sv_pick;
reg        sv_any;
always @(*) begin
	sv_pick = 4'd0;
	sv_any  = 1'b0;
	for (pi = 0; pi < 16; pi = pi + 1) begin
		if (!sv_any && c_evt[(sv_ptr + pi[3:0]) & 4'hF]) begin
			sv_pick = (sv_ptr + pi[3:0]) & 4'hF;
			sv_any  = 1'b1;
		end
	end
end

// a software write to the channel being serviced aborts the service, so a
// key-on or a pointer change can never race the write-back
wire sv_abort = wr_en && is_chan && (wr_ch == sv_ch) && (sv_st != SV_IDLE);

// latched snapshot (SV_LATCH)
reg [1:0]  srv_fmt;
reg [2:0]  srv_rem;
reg [1:0]  srv_uix;
reg [15:0] srv_buf;
reg [1:0]  srv_hdr;
reg [16:0] srv_pred;
reg [7:0]  srv_aix;
reg [23:0] srv_pos;
reg [1:0]  srv_rep;
reg        srv_hold;
reg [15:0] srv_pnt;
reg [21:0] srv_len;
reg [7:0]  srv_volm;   // volume multiplier, 1..128
reg [2:0]  srv_divs;   // divider shift: 0, 1, 2 or 4
reg [7:0]  srv_panl;   // 128 - pan, 0..128
reg [7:0]  srv_panr;   // pan, 1..128

wire [31:0] sv_cnt  = c_cnt[sv_ch];
wire [6:0]  sv_vraw = sv_cnt[6:0];
wire [6:0]  sv_praw = sv_cnt[22:16];
wire [7:0]  sv_panr = (sv_praw == 7'd127) ? 8'd128 : {1'b0, sv_praw};

// decode results (SV_DEC)
reg signed [16:0] d_smp;
reg signed [16:0] d_pred;
reg [7:0]  d_aix;
reg [1:0]  d_hdr;
reg [23:0] d_pos;
reg [2:0]  d_rem;
reg [1:0]  d_uix;
reg        d_need;
reg        d_busy;
reg        d_lsnap;  // take the loop-point snapshot this unit
reg [16:0] d_lpred;  // ... and what to take
reg [7:0]  d_laix;
reg        d_prod;   // this unit yields a sample
reg        d_sil;    // silence the channel now
reg        d_zf;     // silence it after this sample has been mixed

// Scaling (SV_SCL) and pan (SV_PAN) arithmetic.
//
// The products deliberately live in 25-bit wires: an assignment's context
// width propagates into the expression, so writing the shift chain straight
// into a 17- or 18-bit destination would truncate the product *before* the
// shift and wrap a loud sample (16384 x 128 wrapped to 0 that way).
reg signed [24:0] sc_chv;
wire signed [24:0] sv_sclmul = d_smp * $signed({1'b0, srv_volm});
wire signed [24:0] sv_sclval = sv_sclmul >>> 7 >>> srv_divs;
wire signed [24:0] sv_panlml = (sc_chv * $signed({1'b0, srv_panl})) >>> 7;
wire signed [24:0] sv_panrml = (sc_chv * $signed({1'b0, srv_panr})) >>> 7;

// unit selection out of the fetched word
wire [7:0] pcm8_byte = srv_uix[0] ? srv_buf[15:8] : srv_buf[7:0];
wire [3:0] adp_nib   = (srv_uix == 2'd0) ? srv_buf[3:0]  :
                       (srv_uix == 2'd1) ? srv_buf[7:4]  :
                       (srv_uix == 2'd2) ? srv_buf[11:8] :
                                           srv_buf[15:12];

// ADPCM staged-shift decode
wire [15:0] astep  = adpcm_step[srv_aix];
wire [17:0] ad3    = {1'b0, astep} >> 3;
wire [17:0] ad2    = adp_nib[0] ? ({1'b0, astep} >> 2) : 18'd0;
wire [17:0] ad1    = adp_nib[1] ? ({1'b0, astep} >> 1) : 18'd0;
wire [17:0] ad0    = adp_nib[2] ? {1'b0, astep}        : 18'd0;
wire [17:0] adiff  = ad3 + ad2 + ad1 + ad0;
wire signed [18:0] apre  = $signed({{2{srv_pred[16]}}, srv_pred});
wire signed [18:0] apnew = adp_nib[3] ? (apre - $signed({1'b0, adiff}))
                                      : (apre + $signed({1'b0, adiff}));
wire signed [16:0] apclamp = (apnew >  19'sd32767) ?  17'sd32767 :
                             (apnew < -19'sd32767) ? -17'sd32767 : apnew[16:0];

// step-index step: signed, because the four low deltas decrement it and the
// result must clamp at 0 rather than wrap up to 88
wire [3:0] adidx = adpcm_didx[adp_nib[2:0]];
wire signed [9:0] aix_n = (adp_nib[2:0] < 3'd4)
                        ? ($signed({1'b0, srv_aix}) - $signed({1'b0, adidx}))
                        : ($signed({1'b0, srv_aix}) + $signed({1'b0, adidx}));
wire [7:0] aix_c = (aix_n < 10'sd0)  ? 8'd0  :
                   (aix_n > 10'sd88) ? 8'd88 : aix_n[7:0];

// header words: the first carries the predictor, the second the index
wire [7:0] hdr_aix = (srv_buf[6:0] > 7'd88) ? 8'd88 : {1'b0, srv_buf[6:0]};

// what this unit produces
wire signed [16:0] dec_smp = (srv_fmt == FMT_PCM8)  ? $signed({pcm8_byte[7], pcm8_byte, 8'h00}) :
                             (srv_fmt == FMT_PCM16) ? $signed({srv_buf[15], srv_buf}) :
                                                      apclamp;

// position advance: one byte for PCM8, two for PCM16, one byte per two
// ADPCM nibbles
wire [23:0] pos_adv = (srv_fmt == FMT_PCM8)  ? (srv_pos + 24'd1) :
                      (srv_fmt == FMT_PCM16) ? (srv_pos + 24'd2) :
                      (srv_uix[0] ? (srv_pos + 24'd1) : srv_pos);

// segment end = 4*(PNT+LEN) bytes; loop restart at 4*PNT
wire [27:0] srv_end  = {6'd0, srv_pnt, 2'b00} + {4'd0, srv_len, 2'b00};
wire [23:0] end_ofs  = srv_end[23:0];
wire [23:0] loop_ofs = {6'd0, srv_pnt, 2'b00};
wire [23:0] loop_len = {srv_len, 2'b00};
wire        at_end   = (pos_adv >= end_ofs);
wire        do_loop  = at_end && (srv_rep == 2'd1) && (loop_len != 24'd0);

// the first nibble of the byte at 4*PNT: the moment the position passes the
// loop point, where the decoder state to restore on every loop is taken
wire at_loop = (srv_pos == loop_ofs) && !srv_uix[0] && (srv_fmt == FMT_ADPCM);

//------------------------------------------------------------------
// Fetch engine
//
// One word in flight. A completed fetch is parked (fc_*) until no service
// is running for that channel and software is not writing it, so the arrays
// stay single-writer.
//------------------------------------------------------------------
localparam FC_IDLE = 2'd0, FC_WAIT = 2'd1;

reg  [1:0] fc_st  = FC_IDLE;
reg  [3:0] fc_ch  = 4'd0;
reg  [3:0] fc_ptr = 4'd0;

reg        fc_done  = 1'b0;   // a fetched word is parked
reg  [3:0] fc_dch   = 4'd0;
reg [15:0] fc_dbuf  = 16'd0;
reg  [2:0] fc_dunit = 3'd0;
reg        fc_kill  = 1'b0;   // software rewrote the channel in flight

// units in the word about to be fetched
wire [2:0] fc_units = (c_hdr[fc_ch] != 2'd0)                      ? 3'd1 :
                      (c_cnt[fc_ch][30:29] == FMT_PCM8)           ? 3'd2 :
                      (c_cnt[fc_ch][30:29] == FMT_PCM16)          ? 3'd1 : 3'd4;

integer fi;
reg  [3:0] fc_pick;
reg        fc_any;
always @(*) begin
	fc_pick = 4'd0;
	fc_any  = 1'b0;
	for (fi = 0; fi < 16; fi = fi + 1) begin
		if (!fc_any && !fc_done && c_need[(fc_ptr + fi[3:0]) & 4'hF] &&
		    !(wr_en && is_chan && (wr_ch == ((fc_ptr + fi[3:0]) & 4'hF))) &&
		    !((sv_st != SV_IDLE) && (sv_ch == ((fc_ptr + fi[3:0]) & 4'hF)))) begin
			fc_pick = (fc_ptr + fi[3:0]) & 4'hF;
			fc_any  = 1'b1;
		end
	end
end

// SAD + pos, into the 4 MB main-RAM window as 16-bit words.  The address is
// built from the channel selected *this* cycle: fc_ch still holds the previous
// selection until it is latched, so reading the address through it would fetch
// the previous channel's word (and tag it with the new channel).
wire [21:0] fc_byte = c_sad[fc_pick][21:0] + c_pos[fc_pick][21:0];

// the parked word may only land when nothing else is touching that channel
wire fc_free  = !((sv_st != SV_IDLE) && (sv_ch == fc_dch));
wire fc_wrcl  = wr_en && is_chan && (wr_ch == fc_dch);

// A word belongs to the channel state it was requested for.  Software can
// rewrite that state while the word is on its way (a key-on onto a channel
// that is still playing is the common case), so a fetch whose channel is
// written while it is in flight is dropped when it lands — c_need is still
// set, so the channel simply fetches again from its new address.
wire fc_kill_now = fc_kill || (wr_en && is_chan && (fc_st == FC_WAIT) &&
                               (wr_ch == fc_ch));

//------------------------------------------------------------------
// The one sequential block that owns every channel array: counter wrap,
// software register writes (with key-on/key-off), the service write-back
// and the fetch hand-off.
//------------------------------------------------------------------
integer k;
always @(posedge clk) begin

	// ---- counters: up-count, sample on wrap (period = 65536 - TMR) ----
	if (htick) begin
		for (k = 0; k < 16; k = k + 1) begin
			if (c_busy[k] && !c_hang[k] && !c_evt[k]) begin
				if (c_tc[k] == 16'hFFFF) begin
					c_tc[k]  <= c_tmr[k];
					c_evt[k] <= 1'b1;
				end else begin
					c_tc[k] <= c_tc[k] + 16'd1;
				end
			end
		end
	end

	// ---- software register writes ----
	if (wr_en) begin
		if (is_chan) begin
			// the word parked or in flight for this channel was fetched for
			// the state being replaced here
			if (fc_done && (fc_dch == wr_ch)) fc_done <= 1'b0;
			if ((fc_st == FC_WAIT) && (fc_ch == wr_ch)) fc_kill <= 1'b1;
			case (wr_hw)
			3'd0: c_cnt[wr_ch][15:0]  <= reg_wdata;
			3'd1: begin
				c_cnt[wr_ch][31:16] <= reg_wdata;
				c_busy[wr_ch] <= reg_wdata[15];
				if (reg_wdata[15]) begin
					// start from SAD with a fresh decode state; PNT/LEN
					// are already written (GBATEK's order)
					c_pos [wr_ch] <= 24'd0;
					c_hdr [wr_ch] <= (reg_wdata[14:13] == FMT_ADPCM) ? 2'd2
					                                                : 2'd0;
					c_rem [wr_ch] <= 3'd0;
					c_uix [wr_ch] <= 2'd0;
					c_tc  [wr_ch] <= c_tmr[wr_ch];
					c_evt [wr_ch] <= 1'b0;
					// PNT+LEN below four words hangs; so does a loop with
					// an empty body, and PSG, which is not modelled
					c_hang[wr_ch] <= (reg_wdata[14:13] == FMT_PSG) ||
					                 (({7'd0, c_pnt[wr_ch]} + {1'b0, c_len[wr_ch]}) < 23'd4) ||
					                 ((reg_wdata[12:11] == 2'd1) &&
					                  (c_len[wr_ch] == 22'd0));
					c_need[wr_ch] <= !((reg_wdata[14:13] == FMT_PSG) ||
					                   (({7'd0, c_pnt[wr_ch]} + {1'b0, c_len[wr_ch]}) < 23'd4) ||
					                   ((reg_wdata[12:11] == 2'd1) &&
					                    (c_len[wr_ch] == 22'd0)));
					c_l   [wr_ch] <= 17'sd0;
					c_r   [wr_ch] <= 17'sd0;
					c_zf  [wr_ch] <= 1'b0;
				end else begin
					// stop: hold keeps the position and the last sample
					c_evt [wr_ch] <= 1'b0;
					c_hang[wr_ch] <= 1'b0;
					c_zf  [wr_ch] <= 1'b0;
					if (!c_cnt[wr_ch][15]) begin
						c_pos [wr_ch] <= 24'd0;
						c_rem [wr_ch] <= 3'd0;
						c_uix [wr_ch] <= 2'd0;
						c_need[wr_ch] <= 1'b0;
						c_l   [wr_ch] <= 17'sd0;
						c_r   [wr_ch] <= 17'sd0;
					end
				end
			end
			3'd2: c_sad[wr_ch][15:0]  <= {reg_wdata[15:2], 2'b00};
			3'd3: c_sad[wr_ch][26:16] <= reg_wdata[10:0];
			3'd4: c_tmr[wr_ch]        <= reg_wdata;
			3'd5: c_pnt[wr_ch]        <= reg_wdata;
			3'd6: c_len[wr_ch][15:0]  <= reg_wdata;
			3'd7: c_len[wr_ch][21:16] <= reg_wdata[5:0];
			default: ;
			endcase
		end else if (is_scnt) begin
			snd_cnt <= reg_wdata;
		end else if (is_sbia) begin
			snd_bias <= reg_wdata;
		end
	end

	// ---- fetch hand-off ----
	if (fc_done && fc_free) begin
		if (fc_wrcl) fc_done <= 1'b0;   // software moved the channel: drop it
		else begin
			c_buf [fc_dch] <= fc_dbuf;
			c_rem [fc_dch] <= fc_dunit;
			c_uix [fc_dch] <= 2'd0;
			c_need[fc_dch] <= 1'b0;
			fc_done <= 1'b0;
		end
	end

	// ---- fetch master ----
	mem_req <= 1'b0;
	case (fc_st)
	FC_IDLE: begin
		if (fc_any) begin
			fc_ch    <= fc_pick;
			fc_ptr   <= fc_pick + 4'd1;
			mem_addr <= {3'd0, 1'b1, fc_byte[21:1]};
			mem_req  <= 1'b1;
			fc_st    <= FC_WAIT;
		end
	end
	FC_WAIT: begin
		// hold the request until the word lands (mem_arbiter grants it in
		// the first free slot and only releases once the requester drops)
		mem_req <= 1'b1;
		if (mem_ready) begin
			if (!fc_kill_now) begin
				fc_dch   <= fc_ch;
				fc_dbuf  <= mem_rdata;
				fc_dunit <= fc_units;
				fc_done  <= 1'b1;
			end
			fc_kill  <= 1'b0;
			mem_req  <= 1'b0;
			fc_st    <= FC_IDLE;
		end
	end
	default: fc_st <= FC_IDLE;
	endcase

	// ---- service engine ----
	if (sv_abort) begin
		sv_st <= SV_IDLE;
	end else begin
	case (sv_st)
	SV_IDLE: begin
		if (sv_any) begin
			sv_ch  <= sv_pick;
			sv_ptr <= sv_pick + 4'd1;
			sv_st  <= SV_LATCH;
		end
	end

	SV_LATCH: begin
		srv_fmt  <= c_cnt[sv_ch][30:29];
		srv_rep  <= c_cnt[sv_ch][28:27];
		srv_hold <= c_cnt[sv_ch][15];
		srv_volm <= (sv_vraw == 7'd127) ? 8'd128 : {1'b0, sv_vraw};
		srv_panr <= sv_panr;
		srv_panl <= 8'd128 - sv_panr;
		case (c_cnt[sv_ch][9:8])
		2'd0: srv_divs <= 3'd0;
		2'd1: srv_divs <= 3'd1;
		2'd2: srv_divs <= 3'd2;
		default: srv_divs <= 3'd4;
		endcase
		srv_rem  <= c_rem[sv_ch];
		srv_uix  <= c_uix[sv_ch];
		srv_buf  <= c_buf[sv_ch];
		srv_hdr  <= c_hdr[sv_ch];
		srv_pred <= c_pred[sv_ch];
		srv_aix  <= c_aix[sv_ch];
		srv_pos  <= c_pos[sv_ch];
		srv_pnt  <= c_pnt[sv_ch];
		srv_len  <= c_len[sv_ch];
		sv_st <= SV_DEC;
	end

	SV_DEC: begin
		if (srv_rem == 3'd0) begin
			// the word has not landed: hold the sample and ask again
			d_prod <= 1'b0;
			d_sil  <= 1'b0;
			d_zf   <= 1'b0;
			d_need <= 1'b1;
			d_busy <= 1'b1;
			d_lsnap<= 1'b0;
			d_pos  <= srv_pos;
			d_rem  <= 3'd0;
			d_uix  <= srv_uix;
			d_pred <= srv_pred;
			d_aix  <= srv_aix;
			d_hdr  <= srv_hdr;
		end else if (srv_hdr != 2'd0) begin
			// ADPCM header word: decoder state, no sample
			d_prod <= 1'b0;
			d_sil  <= 1'b0;
			d_zf   <= 1'b0;
			d_need <= 1'b1;
			d_busy <= 1'b1;
			d_pos  <= srv_pos + 24'd2;
			d_rem  <= 3'd0;
			d_uix  <= 2'd0;
			d_pred <= (srv_hdr == 2'd2) ? $signed({srv_buf[15], srv_buf})
			                            : srv_pred;
			d_aix  <= (srv_hdr == 2'd2) ? srv_aix : hdr_aix;
			d_hdr  <= srv_hdr - 2'd1;
			// the header is complete on its second word, and a loop point of
			// 0 loops back to it: that state is the one to restore
			d_lsnap<= (srv_hdr == 2'd1);
			d_lpred<= srv_pred;
			d_laix <= hdr_aix;
		end else begin
			d_smp  <= dec_smp;
			d_pred <= (srv_fmt == FMT_ADPCM) ? apclamp : srv_pred;
			d_aix  <= (srv_fmt == FMT_ADPCM) ? aix_c   : srv_aix;
			d_rem  <= srv_rem - 3'd1;
			d_uix  <= srv_uix + 2'd1;
			d_hdr  <= 2'd0;
			d_need <= (srv_rem == 3'd1);
			d_lsnap<= at_loop;
			d_lpred<= srv_pred;
			d_laix <= srv_aix;
			if (at_end) begin
				if (do_loop) begin
					// last sample of the segment, then back to 4*PNT
					d_pos  <= loop_ofs;
					d_rem  <= 3'd0;
					d_uix  <= 2'd0;
					d_need <= 1'b1;
					d_busy <= 1'b1;
					d_prod <= 1'b1;
					d_sil  <= 1'b0;
					d_zf   <= 1'b0;
					// the loop point is in the data, so its state comes from the
					// snapshot — unless it is 0, where the header itself lives
					if (srv_fmt == FMT_ADPCM) begin
						if (loop_ofs == 24'd0) d_hdr <= 2'd2;
						else begin
							d_pred <= c_lpred[sv_ch];
							d_aix  <= c_laix[sv_ch];
						end
					end else d_hdr <= 2'd0;
				end else begin
					// one-shot end: the final sample is still produced (a
					// W-word segment plays all of its samples), and then the
					// channel either keeps it (hold) or falls silent at the
					// next 48 kHz mix tick — melonDS and DeSmuME zero the
					// current sample on the pass after the end as well
					d_pos  <= srv_hold ? srv_pos : 24'd0;
					d_rem  <= 3'd0;
					d_uix  <= 2'd0;
					d_need <= 1'b0;
					d_busy <= 1'b0;
					d_prod <= 1'b1;
					d_sil  <= 1'b0;
					d_zf   <= !srv_hold;
				end
			end else begin
				d_busy <= 1'b1;
				d_prod <= 1'b1;
				d_sil  <= 1'b0;
				d_zf   <= 1'b0;
				d_pos  <= pos_adv;
			end
		end
		sv_st <= SV_SCL;
	end

	SV_SCL: begin
		sc_chv <= sv_sclval;
		sv_st  <= SV_PAN;
	end

	SV_PAN: begin
		// the mixer pass reads one channel per clock: hold this channel's new
		// sample until the pass is over, or the sum would mix two instants
		if (mx_st != MX_SCAN) begin
		if (d_prod) begin
			c_l[sv_ch] <= sv_panlml[16:0];
			c_r[sv_ch] <= sv_panrml[16:0];
		end
		if (d_sil) begin
			c_l[sv_ch] <= 17'sd0;
			c_r[sv_ch] <= 17'sd0;
		end
		c_pos [sv_ch] <= d_pos;
		c_rem [sv_ch] <= d_rem;
		c_uix [sv_ch] <= (d_rem == 3'd0) ? 2'd0 : d_uix;
		c_pred[sv_ch] <= d_pred;
		c_aix [sv_ch] <= d_aix;
		c_hdr [sv_ch] <= (d_rem == 3'd0) ? d_hdr : srv_hdr;
		if (d_lsnap) begin
			c_lpred[sv_ch] <= d_lpred;
			c_laix [sv_ch] <= d_laix;
		end
		c_need[sv_ch] <= d_need;
		c_busy[sv_ch] <= d_busy;
		c_zf  [sv_ch] <= d_prod ? d_zf : (d_sil ? 1'b0 : c_zf[sv_ch]);
		c_evt [sv_ch] <= 1'b0;
		sv_st <= SV_IDLE;
		end
	end

	default: sv_st <= SV_IDLE;
	endcase
	end

	// ---- a one-shot that has ended falls silent once its last sample has
	// been mixed: the mixer raises mx_took on the tick that latches it ----
	if (mx_took) begin
		for (k = 0; k < 16; k = k + 1) begin
			if (c_zf[k]) begin
				c_l[k]  <= 17'sd0;
				c_r[k]  <= 17'sd0;
				c_zf[k] <= 1'b0;
			end
		end
	end

	// ---- reset last, so it overrides everything above ----
	if (reset) begin
		snd_cnt  <= 16'h0000;
		snd_bias <= 16'h0000;
		sv_st    <= SV_IDLE;
		sv_ch    <= 4'd0;
		sv_ptr   <= 4'd0;
		srv_rem  <= 3'd0;
		srv_hdr  <= 2'd0;
		sc_chv   <= 25'sd0;
		d_smp    <= 17'sd0;
		d_pred   <= 17'sd0;
		d_aix    <= 8'd0;
		d_hdr    <= 2'd0;
		d_pos    <= 24'd0;
		d_rem    <= 3'd0;
		d_uix    <= 2'd0;
		d_need   <= 1'b0;
		d_busy   <= 1'b0;
		d_lsnap  <= 1'b0;
		d_lpred  <= 17'sd0;
		d_laix   <= 8'd0;
		d_prod   <= 1'b0;
			d_sil    <= 1'b0;
			d_zf     <= 1'b0;
			fc_st    <= FC_IDLE;
		fc_ch    <= 4'd0;
		fc_ptr   <= 4'd0;
		fc_done  <= 1'b0;
		fc_dch   <= 4'd0;
		fc_dbuf  <= 16'd0;
		fc_dunit <= 3'd0;
		fc_kill  <= 1'b0;
		mem_req  <= 1'b0;
		mem_addr <= 25'd0;
		for (k = 0; k < 16; k = k + 1) begin
			c_cnt[k]  <= 32'h0000_0000;
			c_sad[k]  <= 27'd0;
			c_tmr[k]  <= 16'd0;
			c_pnt[k]  <= 16'd0;
			c_len[k]  <= 22'd0;
			c_busy[k] <= 1'b0;
			c_hang[k] <= 1'b0;
			c_tc[k]   <= 16'd0;
			c_pos[k]  <= 24'd0;
			c_hdr[k]  <= 2'd0;
			c_buf[k]  <= 16'd0;
			c_rem[k]  <= 3'd0;
			c_uix[k]  <= 2'd0;
			c_pred[k] <= 17'd0;
			c_aix[k]  <= 8'd0;
			c_lpred[k]<= 17'd0;
			c_laix[k] <= 8'd0;
			c_evt[k]  <= 1'b0;
			c_need[k] <= 1'b0;
			c_zf[k]   <= 1'b0;
			c_l[k]    <= 17'sd0;
			c_r[k]    <= 17'sd0;
		end
	end
end

//------------------------------------------------------------------
// Mixer: sixteen channels -> master volume -> OSD volume -> clamp
//------------------------------------------------------------------
// The sixteen channels are summed one per clock instead of in a single
// 16-input adder tree. The tree is worth about 90 ALUTs (the module maps to
// 4,098 this way and 4,188 with the tree, because the pass pays most of that
// back in the 16:1 mux below), and the 48 kHz tick spends sixteen of the
// ~1,396 clocks it has, so the cost is time it was not using and the win is
// taking the sixteen-way fanout off the master-volume multiply's input. The
// accumulation is the tree's, in the same order and at the same 22-bit width,
// which is why every sample is the same value it was before.
reg  [3:0] mx_idx  = 4'd0;
reg signed [21:0] mx_accl = 22'sd0, mx_accr = 22'sd0;
reg signed [21:0] mx_suml = 22'sd0, mx_sumr = 22'sd0;
reg signed [21:0] mx_vl = 22'sd0,   mx_vr = 22'sd0;

// the channel the pass is on, sign-extended to the accumulator's width
wire signed [21:0] mx_cl = $signed({{5{c_l[mx_idx][16]}}, c_l[mx_idx]});
wire signed [21:0] mx_cr = $signed({{5{c_r[mx_idx][16]}}, c_r[mx_idx]});

wire [7:0] mvol   = (snd_cnt[6:0] == 7'd127) ? 8'd128 : {1'b0, snd_cnt[6:0]};
wire [8:0] osd_g  = (volume > 4'd10) ? 9'd250 : volume * 9'd25;
wire       snd_on = snd_cnt[15];

// one stage wider than the value that comes out, for the same reason as the
// channel arithmetic above: the product must not be truncated to the width
// of the register it is shifted into
wire signed [28:0] mst_l = (mx_suml * $signed({1'b0, mvol})) >>> 7;
wire signed [28:0] mst_r = (mx_sumr * $signed({1'b0, mvol})) >>> 7;
wire signed [30:0] osd_l = (mx_vl * $signed({1'b0, osd_g})) >>> 8;
wire signed [30:0] osd_r = (mx_vr * $signed({1'b0, osd_g})) >>> 8;

function [15:0] sat16;
	input signed [30:0] v;
	begin
		if (v > 31'sd32767)       sat16 = 16'h7FFF;
		else if (v < -31'sd32768) sat16 = 16'h8000;
		else                      sat16 = v[15:0];
	end
endfunction

always @(posedge clk) begin
	if (reset) begin
		mx_st       <= MX_IDLE;
		audio_l     <= 16'h0000;
		audio_r     <= 16'h0000;
		sample_tick <= 1'b0;
		mx_took     <= 1'b0;
		mx_suml     <= 22'sd0;
		mx_sumr     <= 22'sd0;
		mx_vl       <= 22'sd0;
		mx_vr       <= 22'sd0;
		mx_idx      <= 4'd0;
		mx_accl     <= 22'sd0;
		mx_accr     <= 22'sd0;
	end else begin
		sample_tick <= 1'b0;
		mx_took     <= 1'b0;
		case (mx_st)
		MX_IDLE: begin
			if (atick) begin
				mx_accl <= 22'sd0;
				mx_accr <= 22'sd0;
				mx_idx  <= 4'd0;
				mx_st   <= MX_SCAN;
			end
		end
		MX_SCAN: begin
			mx_accl <= mx_accl + mx_cl;
			mx_accr <= mx_accr + mx_cr;
			mx_idx  <= mx_idx + 4'd1;
			if (mx_idx == 4'd15) mx_st <= MX_LATCH;
		end
		MX_LATCH: begin
			mx_suml <= mx_accl;          // all sixteen, in list order
			mx_sumr <= mx_accr;
			mx_took <= 1'b1;             // the sweep below runs on the next edge
			mx_st   <= MX_MUL1;
		end
		MX_MUL1: begin
			mx_vl <= mst_l[21:0];
			mx_vr <= mst_r[21:0];
			mx_st <= MX_MUL2;
		end
		MX_MUL2: begin
			audio_l <= snd_on ? sat16(osd_l) : 16'h0000;
			audio_r <= snd_on ? sat16(osd_r) : 16'h0000;
			sample_tick <= 1'b1;
			mx_st <= MX_IDLE;
		end
		default: mx_st <= MX_IDLE;
		endcase
	end
end

//------------------------------------------------------------------
// Register read mux (halfword beats; the bus concatenates a 32-bit read).
// GBATEK lists SAD/TMR/PNT/LEN as write-only; this core reads the stored
// value back, as melonDS does.
//------------------------------------------------------------------
always @(*) begin
	reg_rdata = 16'h0000;
	if (is_chan) begin
		case (reg_addr[3:1])
		3'd0: reg_rdata = rd_cnt[15:0];
		3'd1: reg_rdata = {rd_busy, rd_cnt[30:16]};
		3'd2: reg_rdata = rd_sad[15:0];
		3'd3: reg_rdata = {5'd0, rd_sad[26:16]};
		3'd4: reg_rdata = rd_tmr;
		3'd5: reg_rdata = rd_pnt;
		3'd6: reg_rdata = rd_len[15:0];
		3'd7: reg_rdata = {10'd0, rd_len[21:16]};
		default: ;
		endcase
	end else if (is_scnt) reg_rdata = snd_cnt;
	else if (is_sbia)     reg_rdata = snd_bias;
end

wire _unused = &{1'b0, mix_mode, srv_uix, snd_bias, 1'b0};

endmodule
