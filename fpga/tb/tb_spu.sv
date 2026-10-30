//============================================================================
// NDS MiSTer Test — SPU bench
//
//   iverilog -g2012 -o /tmp/tb_spu tb/tb_spu.sv rtl/audio/spu.sv
//   vvp /tmp/tb_spu
//
// Drives the ARM7 sound register window the way the CPU does (halfword
// beats, low halfword first for a 32-bit write) against a sample-RAM model
// that answers the fetch master with a real handshake, and watches the
// audio output on the 48 kHz sample tick.  Channels are keyed on with the
// TMR of a 16.4 kHz sample rate, so a sample lasts ~60 us and the output
// moves in whole samples rather than mixing two together.
//
//   1.  registers: reset state, SAD word alignment, the 32-bit round-trips,
//       SOUNDCNT/SOUNDBIAS, the capture window, the top channel, and a
//       low-halfword CNT write leaving the format field alone
//   2.  PCM8 and PCM16 playback in order with the documented sign handling
//   3.  volume multiplier, volume divider, panning, master volume, master
//       enable and the OSD volume, plus two and sixteen channels summing
//       and the output clamping instead of wrapping
//   4.  one-shot end (the final sample plays, then silence, busy clears),
//       hold, the short-length hang, and a key-off in mid-air
//   5.  PCM8 looping, and an ADPCM loop whose point (4*PNT) is in the data:
//       the state there is snapshotted as the position passes it and
//       restored on every loop, so the loop body repeats exactly
//   6.  ADPCM decode against the golden samples from
//       tools/gen_spu_vectors.py, and a header index clamped to 88 and 0
//   7.  timing: the sample rate against GBATEK's 16756991/(65536-TMR) Hz,
//       the rate doubling when the period halves, a fetch that lands late,
//       and the 48 kHz sample tick
//
// The expected outputs come from tools/gen_spu_vectors.py (the documented
// ADPCM nibble decode and this core's published scaling chain), not from
// the RTL. Consecutive equal samples collapse into one output entry, since
// the capture records a new entry when the output changes.
//============================================================================
`timescale 1ns/1ps

module tb_spu;

	reg clk = 0;
	always #7.4599 clk = ~clk; // 67.0274 MHz: the core's own clock (the PLL)

	reg reset = 1;

	// ---- register window ----
	reg        racc = 0;
	reg        rwe = 0;
	reg [15:0] raddr = 0;
	reg [15:0] rwdata = 0;
	wire [15:0] rdata;

	// ---- sample fetch master ----
	reg  [15:0] mem [0:4095];
	wire        mreq;
	wire [24:0] maddr;
	reg         mready = 0;
	reg  [15:0] mrdata = 0;
	reg  [15:0] mstall = 0;   // extra clocks before the model answers

	// ---- output ----
	wire        tick;
	wire [15:0] al, ar;
	reg  [3:0]  volume = 4'd10;   // OSD: 100%
	reg  [1:0]  mix_mode = 2'd0;

	spu dut (
		.clk(clk), .reset(reset),
		.reg_acc(racc), .reg_we(rwe),
		.reg_addr(raddr), .reg_wdata(rwdata), .reg_rdata(rdata),
		.mem_req(mreq), .mem_addr(maddr),
		.mem_ready(mready), .mem_rdata(mrdata),
		.volume(volume), .mix_mode(mix_mode),
		.sample_tick(tick), .audio_l(al), .audio_r(ar)
	);

	//------------------------------------------------------------------
	// Host main-RAM model: a held request is answered after four clocks
	// (plus mstall), addressed like main_bus maps RAM: a 25-bit *halfword*
	// address 0x200000 + byte/2, so the bench's SAD 0x02000000 starts at
	// mem[0] and mem[k] holds bytes 2k and 2k+1
	//------------------------------------------------------------------
	integer mi;
	initial for (mi = 0; mi < 4096; mi = mi + 1) mem[mi] = 16'h0000;

	reg [2:0]  mlat = 0;
	reg [15:0] mhold = 0;
	always @(posedge clk) begin
		mready <= 1'b0;
		if (reset) begin
			mlat <= 3'd0; mhold <= 16'd0;
		end else if (!mreq) begin
			mlat <= 3'd0; mhold <= 16'd0;
		end else if (mhold < mstall) begin
			mhold <= mhold + 16'd1;
		end else if (mlat == 3'd3) begin
			mrdata <= mem[maddr[11:0]];
			mready <= 1'b1;
			mlat   <= 3'd0;
		end else begin
			mlat <= mlat + 3'd1;
		end
	end

	// fetch requests seen (rising edges), for the rate measurements
	integer req_edges = 0;
	reg     mreq_d = 0;
	always @(posedge clk) begin
		mreq_d <= mreq;
		if (mreq & ~mreq_d) req_edges = req_edges + 1;
	end

	// sample ticks seen
	integer tick_n = 0;
	always @(posedge clk) if (tick) tick_n = tick_n + 1;

	//------------------------------------------------------------------
	// Output capture: one entry per change of either channel, taken on the
	// sample tick, so a run of samples can be compared in order
	//------------------------------------------------------------------
	reg [15:0] cap_l [0:63];
	reg [15:0] cap_r [0:63];
	integer    capn = 0;
	reg [15:0] last_l = 16'h0000;
	reg [15:0] last_r = 16'h0000;

	always @(posedge clk) begin
		if (tick && (al !== last_l || ar !== last_r)) begin
			if (capn < 64) begin
				cap_l[capn] = al;
				cap_r[capn] = ar;
			end
			capn  = capn + 1;
			last_l = al;
			last_r = ar;
		end
	end

	//------------------------------------------------------------------
	// tasks
	//------------------------------------------------------------------
	integer errors = 0;
	task check;
		input [8*56:1] name;
		input          cond;
		begin
			if (cond) $display("ok   %0s", name);
			else begin $display("FAIL %0s", name); errors = errors + 1; end
		end
	endtask

	// compare the newest captured entry against an expected stereo pair
	task check_lr;
		input [8*48:1] name;
		input [15:0]   want_l, want_r;
		begin
			if (cap_l[capn-1] === want_l && cap_r[capn-1] === want_r)
				$display("ok   %0s", name);
			else begin
				$display("FAIL %0s: got L %0d R %0d, want L %0d R %0d (capn=%0d cap0=%0d)", name,
				         $signed(cap_l[capn-1]), $signed(cap_r[capn-1]),
				         $signed(want_l), $signed(want_r), capn, cap_l[0]);
				errors = errors + 1;
			end
		end
	endtask

	// one register beat, the shape main_bus generates per halfword
	task beat;
		input [15:0] a;
		input [15:0] d;
		input        we;
		begin
			@(posedge clk); #1;
			raddr = a; rwdata = d; racc = 1'b1; rwe = we;
			@(posedge clk); #1;
			racc = 1'b0; rwe = 1'b0;
			@(posedge clk); #1;
		end
	endtask

	task wr;
		input [15:0] a;
		input [15:0] d;
		begin beat(a, d, 1'b1); end
	endtask

	task rd;
		input  [15:0] a;
		output [15:0] d;
		begin
			@(posedge clk); #1;
			raddr = a; racc = 1'b1; rwe = 1'b0;
			#1 d = rdata;
			@(posedge clk); #1;
			racc = 1'b0;
		end
	endtask

	task wr32;
		input [15:0] a;
		input [31:0] v;
		begin
			wr(a, v[15:0]);
			wr(a + 16'd2, v[31:16]);
		end
	endtask

	task rd32;
		input  [15:0] a;
		output [31:0] v;
		reg [15:0] lo, hi;
		begin
			rd(a, lo);
			rd(a + 16'd2, hi);
			v = {hi, lo};
		end
	endtask

	function [15:0] ca;      // channel register address
		input [3:0] ch;
		input [3:0] off;
		begin
			ca = 16'h0400 + {4'd0, ch, 4'h0} + {12'd0, off};
		end
	endfunction

	// SOUNDxCNT from its fields (GBATEK's layout)
	function [31:0] cnt_v;
		input [1:0] fmt;
		input [1:0] rep;
		input       hold;
		input [6:0] vol;
		input [1:0] div;
		input [6:0] pan;
		begin
			cnt_v = {1'b0, fmt, rep, 3'd0, 1'b0, pan, hold,
			         5'd0, div, 1'b0, vol};
		end
	endfunction

	task master;
		input [6:0] mv;
		input       en;
		begin wr(16'h0500, {en, 8'd0, mv}); end
	endtask

	// SAD, TMR, PNT, LEN then CNT with the start bit, the order the SDK uses
	task play;
		input [3:0]  ch;
		input [31:0] cnt;
		input [31:0] sad;     // bits 26:0 carry the address
		input [15:0] tmr;
		input [15:0] pnt;
		input [21:0] len;
		begin
			wr32(ca(ch, 4'h4), sad & 32'h07FF_FFFC);
			wr(ca(ch, 4'h8), tmr);
			wr(ca(ch, 4'hA), pnt);
			wr32(ca(ch, 4'hC), {10'd0, len});
			wr32(ca(ch, 4'h0), cnt | 32'h8000_0000);
		end
	endtask

	task stop;
		input [3:0] ch;
		begin wr(ca(ch, 4'h2), 16'h0000); end
	endtask

	task wait_clk;
		input integer n;
		integer k;
		begin for (k = 0; k < n; k = k + 1) @(posedge clk); end
	endtask

	task settle;
		begin wait_clk(4000); end
	endtask

	task cap_clr;
		begin
			capn   = 0;
			last_l = 16'h0000;
			last_r = 16'h0000;
		end
	endtask

	task wait_n;   // wait for n output changes, or the clock limit
		input integer n;
		input integer limit;
		integer k;
		begin
			k = 0;
			while (capn < n && k < limit) begin
				@(posedge clk); k = k + 1;
			end
		end
	endtask

	// golden comparison
	reg [15:0] expl [0:63];
	reg [15:0] expr [0:63];

	task exp4;   // four expected entries with the same value both sides
		input integer i;
		input [15:0] a, b, c, d;
		begin
			expl[i] = a; expr[i] = a;
			expl[i+1] = b; expr[i+1] = b;
			expl[i+2] = c; expr[i+2] = c;
			expl[i+3] = d; expr[i+3] = d;
		end
	endtask

	task cmp_seq;
		input [8*48:1] name;
		input integer  n;
		integer k;
		reg bad;
		begin
			bad = 0;
			for (k = 0; k < n; k = k + 1) begin
				if (cap_l[k] !== expl[k] || cap_r[k] !== expr[k]) begin
					bad = 1;
					$display("   %0s [%0d]: got L %0d R %0d, want L %0d R %0d",
					         name, k, $signed(cap_l[k]), $signed(cap_r[k]),
					         $signed(expl[k]), $signed(expr[k]));
				end
			end
			check(name, !bad);
		end
	endtask

	//------------------------------------------------------------------
	reg [15:0] v16;
	reg [31:0] v32, ch0_before;
	integer    k, lim;
	reg [63:0] t0, t1, dt;
	integer    rate1, rate2;

	initial begin
		// ---- sample RAM (tools/gen_spu_vectors.py) ----
		mem[0]  = 16'h4140; mem[1]  = 16'h80C0;   // PCM8 one-shot
		mem[2]  = 16'h817F; mem[3]  = 16'hFF01;
		mem[4]  = 16'hE020; mem[5]  = 16'hAB55;
		mem[6]  = 16'hF010; mem[7]  = 16'h3305;
		mem[8]  = 16'h0100; mem[9]  = 16'hFF00;   // PCM16 one-shot
		mem[10] = 16'h7FFF; mem[11] = 16'h8000;
		mem[12] = 16'h0001; mem[13] = 16'hFFFF;
		mem[14] = 16'h1234; mem[15] = 16'hEDCC;
		mem[16] = 16'h0100; mem[17] = 16'h0005;   // ADPCM A (header + 16 B)
		mem[18] = 16'h3412; mem[19] = 16'h6587;
		mem[20] = 16'hF00F; mem[21] = 16'h3A9C;
		mem[22] = 16'h1177; mem[23] = 16'h55EE;
		mem[24] = 16'h5AA5; mem[25] = 16'h24C3;
		mem[32] = 16'h0000; mem[33] = 16'h0000;   // ADPCM C loop (PNT=2 LEN=2)
		mem[34] = 16'h5713; mem[35] = 16'hDF9B;
		mem[36] = 16'h0200; mem[37] = 16'h0000;
		mem[38] = 16'h4218; mem[39] = 16'hE1A6;
		mem[40] = 16'h0000; mem[41] = 16'h0064;   // ADPCM B (index 100 -> 88)
		mem[42] = 16'h0000; mem[43] = 16'h0000;
		mem[44] = 16'h0000; mem[45] = 16'h0000;
		mem[46] = 16'h0000; mem[47] = 16'h0000;
		mem[48] = 16'h2010; mem[49] = 16'h4030;   // PCM8 loop (PNT=2 LEN=2)
		mem[50] = 16'h6050; mem[51] = 16'h7870;
		mem[52] = 16'h6070; mem[53] = 16'h4050;
		mem[54] = 16'h2030; mem[55] = 16'h0810;
		for (k = 56; k < 64; k = k + 1) mem[k] = 16'h4040;  // constant 0x40

		repeat (6) @(posedge clk);
		reset = 0;
		repeat (4) @(posedge clk);

		// ---------------- 1. registers ----------------
		rd32(ca(4'd0, 4'h0), v32);
		check("reset: SOUND0CNT reads zero", v32 === 32'h0000_0000);
		rd(ca(4'd0, 4'h8), v16);
		check("reset: SOUND0TMR reads zero", v16 === 16'd0);

		wr32(ca(4'd3, 4'h4), 32'h0200_0007);
		rd32(ca(4'd3, 4'h4), v32);
		check("SAD is stored word-aligned", v32 === 32'h0200_0004);

		ch0_before = cnt_v(2'd2, 2'd1, 1'b0, 7'd100, 2'd2, 7'd32);
		wr32(ca(4'd0, 4'h0), ch0_before);
		rd32(ca(4'd0, 4'h0), v32);
		check("SOUNDxCNT 32-bit round-trip", v32 === ch0_before);

		// a halfword beat only replaces its own half, so the format field
		// (bits 30:27) must survive a low-halfword write
		wr(ca(4'd0, 4'h0), 16'd127);
		rd32(ca(4'd0, 4'h0), v32);
		check("a low-halfword CNT write keeps the format field",
		      v32 === {ch0_before[31:16], 16'h007F});

		wr(ca(4'd5, 4'h8), 16'hFDF5);
		wr(ca(4'd5, 4'hA), 16'h0002);
		wr32(ca(4'd5, 4'hC), 32'h0004_5678);
		rd(ca(4'd5, 4'h8), v16);
		check("SOUNDxTMR round-trip", v16 === 16'hFDF5);
		rd(ca(4'd5, 4'hA), v16);
		check("SOUNDxPNT round-trip", v16 === 16'h0002);
		rd32(ca(4'd5, 4'hC), v32);
		check("SOUNDxLEN 32-bit round-trip", v32 === 32'h0004_5678);

		rd32(ca(4'd0, 4'h0), ch0_before);   // channel 0 as it stands now
		wr32(ca(4'd15, 4'h0), cnt_v(2'd1, 2'd2, 1'b0, 7'd7, 2'd3, 7'd126));
		rd32(ca(4'd15, 4'h0), v32);
		check("the top channel decodes",
		      v32 === cnt_v(2'd1, 2'd2, 1'b0, 7'd7, 2'd3, 7'd126));
		rd32(ca(4'd0, 4'h0), v32);
		check("channel 15 does not disturb channel 0", v32 === ch0_before);

		master(7'd127, 1'b1);
		rd(16'h0500, v16);
		check("SOUNDCNT round-trip", v16 === 16'h807F);
		wr(16'h0504, 16'h0200);
		rd(16'h0504, v16);
		check("SOUNDBIAS round-trip", v16 === 16'h0200);
		rd(16'h0508, v16);
		check("the capture window reads zero", v16 === 16'd0);

		// ---------------- 2. PCM8 playback ----------------
		cap_clr();
		check("no sound before a key-on", capn == 0);

		exp4(0,  16'd8000, 16'd8125, -16'd8000, -16'd16000);
		exp4(4,  16'd15875, -16'd15875, 16'd125, -16'd125);
		exp4(8,  16'd4000, -16'd4000, 16'd10625, -16'd10625);
		exp4(12, 16'd2000, -16'd2000, 16'd625, 16'd6375);
		play(4'd0, cnt_v(2'd0, 2'd2, 1'b0, 7'd127, 2'd0, 7'd64),
		     32'h0200_0000, 16'hFC00, 16'd0, 22'd4);
		wait_n(16, 400000);
		cmp_seq("PCM8 plays its samples in order", 16);
		wait_n(17, 200000);
		check("a one-shot ends silent", cap_l[16] == 16'd0 && cap_r[16] == 16'd0);
		rd32(ca(4'd0, 4'h0), v32);
		check("a one-shot clears its busy bit", v32[31] === 1'b0);
		settle();

		// ---------------- PCM16 ----------------
		cap_clr();
		exp4(0, 16'd125, -16'd125, 16'd15999, -16'd16000);
		exp4(4, 16'd0, -16'd1, 16'd2275, -16'd2276);
		play(4'd0, cnt_v(2'd1, 2'd2, 1'b0, 7'd127, 2'd0, 7'd64),
		     32'h0200_0010, 16'hFC00, 16'd0, 22'd4);
		wait_n(8, 300000);
		cmp_seq("PCM16 plays signed samples in order", 8);
		stop(4'd0); settle();

		// ---------------- 3. volume, panning, master ----------------
		// constant PCM8 0x40 (sample 16384) at unity: 8000
		cap_clr();
		play(4'd0, cnt_v(2'd0, 2'd2, 1'b0, 7'd127, 2'd0, 7'd64),
		     32'h0200_0070, 16'hFC00, 16'd0, 22'd4);
		wait_clk(12000);   // mid-playback: the constant buffer ends at ~32768
		check_lr("unity volume and centre pan", 16'd8000, 16'd8000);
		stop(4'd0); settle();

		cap_clr();
		play(4'd0, cnt_v(2'd0, 2'd2, 1'b0, 7'd64, 2'd0, 7'd64),
		     32'h0200_0070, 16'hFC00, 16'd0, 22'd4);
		wait_clk(12000);
		check_lr("volume multiplier 64 halves the channel", 16'd4000, 16'd4000);
		stop(4'd0); settle();

		cap_clr();
		play(4'd0, cnt_v(2'd0, 2'd2, 1'b0, 7'd127, 2'd1, 7'd64),
		     32'h0200_0070, 16'hFC00, 16'd0, 22'd4);
		wait_clk(12000);
		check_lr("volume divider 2 halves the channel", 16'd4000, 16'd4000);
		stop(4'd0); settle();

		cap_clr();
		play(4'd0, cnt_v(2'd0, 2'd2, 1'b0, 7'd127, 2'd3, 7'd64),
		     32'h0200_0070, 16'hFC00, 16'd0, 22'd4);
		wait_clk(12000);
		check_lr("volume divider 16 takes a sixteenth", 16'd500, 16'd500);
		stop(4'd0); settle();

		cap_clr();
		play(4'd0, cnt_v(2'd0, 2'd2, 1'b0, 7'd127, 2'd0, 7'd0),
		     32'h0200_0070, 16'hFC00, 16'd0, 22'd4);
		wait_clk(12000);
		check_lr("pan 0 is all left", 16'd16000, 16'd0);
		stop(4'd0); settle();

		cap_clr();
		play(4'd0, cnt_v(2'd0, 2'd2, 1'b0, 7'd127, 2'd0, 7'd127),
		     32'h0200_0070, 16'hFC00, 16'd0, 22'd4);
		wait_clk(12000);
		check_lr("pan 127 is all right", 16'd0, 16'd16000);
		stop(4'd0); settle();

		master(7'd64, 1'b1);
		cap_clr();
		play(4'd0, cnt_v(2'd0, 2'd2, 1'b0, 7'd127, 2'd0, 7'd64),
		     32'h0200_0070, 16'hFC00, 16'd0, 22'd4);
		wait_clk(12000);
		check_lr("master volume 64 halves the mix", 16'd4000, 16'd4000);
		stop(4'd0); settle();

		master(7'd127, 1'b0);
		cap_clr();
		play(4'd0, cnt_v(2'd0, 2'd2, 1'b0, 7'd127, 2'd0, 7'd64),
		     32'h0200_0070, 16'hFC00, 16'd0, 22'd4);
		wait_clk(60000);
		check("SOUNDCNT master enable off is silence", capn == 0);
		stop(4'd0); master(7'd127, 1'b1); settle();

		volume = 4'd0;
		cap_clr();
		play(4'd0, cnt_v(2'd0, 2'd2, 1'b0, 7'd127, 2'd0, 7'd64),
		     32'h0200_0070, 16'hFC00, 16'd0, 22'd4);
		wait_clk(60000);
		check("OSD volume 0 is silence", capn == 0);
		stop(4'd0); volume = 4'd10; settle();

		cap_clr();
		play(4'd0, cnt_v(2'd0, 2'd2, 1'b0, 7'd0, 2'd0, 7'd64),
		     32'h0200_0070, 16'hFC00, 16'd0, 22'd4);
		wait_clk(60000);
		check("volume multiplier 0 is silence", capn == 0);
		stop(4'd0); settle();

		// two channels sum
		cap_clr();
		play(4'd0, cnt_v(2'd0, 2'd2, 1'b0, 7'd127, 2'd0, 7'd64),
		     32'h0200_0070, 16'hFC00, 16'd0, 22'd4);
		play(4'd1, cnt_v(2'd0, 2'd2, 1'b0, 7'd127, 2'd0, 7'd64),
		     32'h0200_0070, 16'hFC00, 16'd0, 22'd4);
		wait_clk(12000);
		check_lr("two channels sum", 16'd16000, 16'd16000);
		stop(4'd0); stop(4'd1); settle();

		// four channels at full left clamp instead of wrapping
		cap_clr();
		for (k = 0; k < 4; k = k + 1)
			play(k[3:0], cnt_v(2'd0, 2'd2, 1'b0, 7'd127, 2'd0, 7'd0),
			     32'h0200_0070, 16'hFC00, 16'd0, 22'd4);
		wait_clk(12000);
		check_lr("a loud mix clamps, it does not wrap", 16'h7FFF, 16'd0);
		for (k = 0; k < 4; k = k + 1) stop(k[3:0]);
		settle();

		// all sixteen channels at once, each with its own volume multiplier:
		// every slot has to be summed exactly once, which is the way the
		// one-channel-per-clock pass can go wrong (an off-by-one index drops
		// a channel or sums one twice). Contribution per channel is
		// ((16384 * vol) >> 7) * 64 >> 7 = 64 * vol for vol 1..16, so the sum
		// is 64 * 136 = 8704 and the master 128 with the OSD 250/256 gives
		// 8704 * 250 >> 8 = 8500 exactly.
		cap_clr();
		for (k = 0; k < 16; k = k + 1)
			play(k[3:0], cnt_v(2'd0, 2'd2, 1'b0, k[6:0] + 7'd1, 2'd0, 7'd64),
			     32'h0200_0070, 16'hFC00, 16'd0, 22'd4);
		wait_clk(12000);
		check_lr("sixteen channels sum, each exactly once", 16'd8500, 16'd8500);
		for (k = 0; k < 16; k = k + 1) stop(k[3:0]);
		settle();

		// ---------------- 4. ends, hold, hang, key-off ----------------
		cap_clr();
		play(4'd0, cnt_v(2'd0, 2'd2, 1'b0, 7'd127, 2'd0, 7'd64),
		     32'h0200_0000, 16'hFC00, 16'd0, 22'd4);
		wait_n(16, 400000);
		wait_clk(60000);   // well past the end
		exp4(0,  16'd8000, 16'd8125, -16'd8000, -16'd16000);
		exp4(4,  16'd15875, -16'd15875, 16'd125, -16'd125);
		exp4(8,  16'd4000, -16'd4000, 16'd10625, -16'd10625);
		exp4(12, 16'd2000, -16'd2000, 16'd625, 16'd6375);
		exp4(16, 16'd0, 16'd0, 16'd0, 16'd0);
		cmp_seq("without hold plays all 16 then silence", 17);
		check("without hold ends with one silence entry", capn == 17);
		stop(4'd0); settle();

		cap_clr();
		play(4'd0, cnt_v(2'd0, 2'd2, 1'b1, 7'd127, 2'd0, 7'd64),
		     32'h0200_0000, 16'hFC00, 16'd0, 22'd4);
		wait_n(16, 400000);
		wait_clk(60000);
		check("with hold the last sample stays", capn == 16 &&
		                                        cap_l[15] == 16'd6375);
		rd32(ca(4'd0, 4'h0), v32);
		check("hold still clears the busy bit", v32[31] === 1'b0);
		stop(4'd0); settle();

		// PNT+LEN below four words hangs: busy set, no sound
		cap_clr();
		play(4'd0, cnt_v(2'd0, 2'd2, 1'b0, 7'd127, 2'd0, 7'd64),
		     32'h0200_0000, 16'hFC00, 16'd1, 22'd1);
		wait_clk(80000);
		rd32(ca(4'd0, 4'h0), v32);
		check("a short length hangs with busy set", v32[31] === 1'b1);
		check("a hung channel is silent", capn == 0);
		stop(4'd0); settle();

		// key-off in mid-air
		cap_clr();
		play(4'd0, cnt_v(2'd0, 2'd1, 1'b0, 7'd127, 2'd0, 7'd64),
		     32'h0200_0060, 16'hFC00, 16'd2, 22'd2);
		wait_n(5, 400000);
		stop(4'd0);
		settle();
		rd32(ca(4'd0, 4'h0), v32);
		check("a key-off stops the channel", v32[31] === 1'b0);
		check("a key-off silences the output", cap_l[capn-1] == 16'd0);
		settle();

		// ---------------- 5. looping ----------------
		cap_clr();
		play(4'd0, cnt_v(2'd0, 2'd1, 1'b0, 7'd127, 2'd0, 7'd64),
		     32'h0200_0060, 16'hFC00, 16'd2, 22'd2);
		wait_n(24, 600000);
		exp4(0,  16'd2000, 16'd4000, 16'd6000, 16'd8000);
		exp4(4,  16'd10000, 16'd12000, 16'd14000, 16'd15000);
		exp4(8,  16'd14000, 16'd12000, 16'd10000, 16'd8000);
		exp4(12, 16'd6000, 16'd4000, 16'd2000, 16'd1000);
		exp4(16, 16'd14000, 16'd12000, 16'd10000, 16'd8000);
		exp4(20, 16'd6000, 16'd4000, 16'd2000, 16'd1000);
		cmp_seq("PCM8 loop plays PNT once, then LEN forever", 24);
		stop(4'd0); settle();

		// ---------------- 6. ADPCM ----------------
		cap_clr();
		play(4'd0, cnt_v(2'd2, 2'd2, 1'b0, 7'd127, 2'd0, 7'd64),
		     32'h0200_0020, 16'hFC00, 16'd0, 22'd5);
		wait_n(32, 700000);
		exp4(0,  16'd127, 16'd129, 16'd134, 16'd139);
		exp4(4,  16'd149, 16'd148, 16'd162, 16'd185);
		exp4(8,  16'd136, 16'd143, 16'd149, 16'd61);
		exp4(12, -16'd54, -16'd100, -16'd169, -16'd81);
		exp4(16, 16'd92, 16'd466, 16'd626, 16'd772);
		exp4(20, 16'd198, -16'd820, 16'd706, 16'd2939);
		exp4(24, 16'd6208, 16'd4032, 16'd2053, 16'd6010);
		exp4(28, 16'd9697, 16'd5387, 16'd10602, 16'd14107);
		cmp_seq("ADPCM decodes the golden samples", 32);
		wait_n(33, 200000);
		check("ADPCM one-shot ends silent", cap_l[32] == 16'd0);
		stop(4'd0); settle();

		cap_clr();
		play(4'd0, cnt_v(2'd2, 2'd2, 1'b0, 7'd127, 2'd0, 7'd64),
		     32'h0200_0050, 16'hFC00, 16'd0, 22'd4);
		wait_n(8, 400000);
		exp4(0, 16'd1999, 16'd3817, 16'd5470, 16'd6972);
		exp4(4, 16'd8338, 16'd9581, 16'd10709, 16'd11736);
		cmp_seq("ADPCM header index clamps to 88", 8);
		stop(4'd0); settle();

		// the loop point (4*PNT) is inside the data, so the state there is
		// snapshotted as the position passes it and restored on each loop:
		// the first pass is 24 samples, and the 16-sample loop body repeats
		// exactly.  39 entries = the first pass (23) + the loop body (16).
		cap_clr();
		play(4'd0, cnt_v(2'd2, 2'd1, 1'b0, 7'd127, 2'd0, 7'd64),
		     32'h0200_0040, 16'hFC00, 16'd2, 22'd2);
		wait_n(39, 900000);
		exp4(0,  16'd1, 16'd7, 16'd18, 16'd9);
		exp4(4,  16'd5, -16'd11, -16'd39, -16'd35);
		exp4(8,  -16'd32, -16'd17, -16'd14, -16'd12);
		exp4(12, -16'd10, -16'd8, -16'd6, -16'd8);
		exp4(16, -16'd3, 16'd2, 16'd14, 16'd34);
		exp4(20, 16'd20, 16'd28, -16'd1, -16'd35);
		exp4(24, -16'd32, -16'd17, -16'd14, -16'd12);
		exp4(28, -16'd10, -16'd8, -16'd6, -16'd8);
		exp4(32, -16'd3, 16'd2, 16'd14, 16'd34);
		exp4(36, 16'd20, 16'd28, -16'd1, 16'd0);
		cmp_seq("ADPCM loop restores its snapshot at PNT", 39);
		stop(4'd0); settle();

		// ---------------- 7. timing ----------------
		// TMR=0xFE00 -> 512 half-rate ticks per sample
		play(4'd0, cnt_v(2'd1, 2'd1, 1'b0, 7'd127, 2'd0, 7'd64),
		     32'h0200_0010, 16'hFE00, 16'd0, 22'd4);
		req_edges = 0;
		lim = 0;
		while (req_edges < 1 && lim < 200000) begin @(posedge clk); lim = lim + 1; end
		req_edges = 0;
		t0 = $time;
		lim = 0;
		while (req_edges < 100 && lim < 2000000) begin @(posedge clk); lim = lim + 1; end
		t1 = $time;
		dt    = (t1 - t0) / 14.9198;            // clocks for 100 samples
		rate1 = (100 * 67_025_100) / dt;
		$display("   TMR 0xFE00: %0d Hz measured, %0d Hz expected (GBATEK)",
		         rate1, 32'd16756850 / 512);
		check("the sample rate follows TMR", (rate1 > 32400 && rate1 < 33050));
		stop(4'd0); settle();

		play(4'd0, cnt_v(2'd1, 2'd1, 1'b0, 7'd127, 2'd0, 7'd64),
		     32'h0200_0010, 16'hFF00, 16'd0, 22'd4);
		req_edges = 0;
		lim = 0;
		while (req_edges < 1 && lim < 200000) begin @(posedge clk); lim = lim + 1; end
		req_edges = 0;
		t0 = $time;
		lim = 0;
		while (req_edges < 100 && lim < 2000000) begin @(posedge clk); lim = lim + 1; end
		t1 = $time;
		dt    = (t1 - t0) / 14.9198;
		rate2 = (100 * 67_025_100) / dt;
		$display("   TMR 0xFF00: %0d Hz measured, %0d Hz expected (GBATEK)",
		         rate2, 32'd16756850 / 256);
		check("halving the period doubles the rate",
		      ((rate2 * 100) / rate1) > 197 && ((rate2 * 100) / rate1) < 203);
		stop(4'd0); settle();

		// a fetch that lands later than the sample is due holds the sample
		mstall = 16'd5000;
		cap_clr();
		play(4'd0, cnt_v(2'd0, 2'd2, 1'b0, 7'd127, 2'd0, 7'd64),
		     32'h0200_0000, 16'hFC00, 16'd0, 22'd4);
		wait_clk(4000);
		check("a fetch that has not landed holds the sample", capn == 0);
		wait_n(1, 300000);
		check("the sample that lands late is the right one",
		      cap_l[capn-1] == 16'd8000);
		mstall = 16'd0;
		stop(4'd0); settle();

		// the 48 kHz sample tick
		tick_n = 0;
		lim = 0;
		while (tick_n < 1 && lim < 20000) begin @(posedge clk); lim = lim + 1; end
		tick_n = 0;
		t0 = $time;
		lim = 0;
		while (tick_n < 100 && lim < 200000) begin @(posedge clk); lim = lim + 1; end
		t1 = $time;
		$display("   100 sample ticks: %0d clocks (48000 Hz)", (t1 - t0) / 14.9198);
		check("the sample tick is 48 kHz",
		      ((t1 - t0) / 14.9198) >= 139633 && ((t1 - t0) / 14.9198) <= 139648);

		if (errors == 0) $display("TB SPU PASS");
		else             $display("TB SPU FAIL (%0d errors)", errors);
		$finish;
	end

endmodule
