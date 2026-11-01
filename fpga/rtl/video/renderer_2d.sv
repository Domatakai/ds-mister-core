//============================================================================
// NDS MiSTer Test — shared 2D renderer (milestone M2)
//
// Real text-mode renderer used by both engines (engine_a/engine_b wrap it
// with their register sets). GBATEK behaviours implemented in M2:
//
//   - DISPCNT mode 0: four text BGs; mode 1: BG0/BG1 text (affine BG2
//     renders transparent until the geometry engine, M3); bitmap modes
//     render backdrop + OBJ only
//   - text BGs: 4bpp/8bpp tiles, 32x32 / 64x32 / 32x64 / 64x64 maps with
//     the GBATEK block layout, h/v flip, scroll (BGxHOFS/VOFS), palette
//     banks, priorities (lower BG number wins ties)
//   - OBJ: regular sprites, 4bpp/8bpp, all shape/size combinations,
//     1D tile mapping, h/v flip, priority; lower OAM index wins ties;
//     affine/bitmap OBJ render transparent until M3
//   - backdrop (BG palette colour 0) as the base layer
//   - the 3D layer (engine A only): once the BG and OBJ passes have
//     written the back bank, a merge pass reads the line's 256 frame
//     pixels out of the VRAM bank whose VRAMCNT MST is 2 as four
//     64-pixel bursts (one beat per clock, each beat composited the
//     cycle it arrives) and commits every opaque one (bit 15 set) through
//     the same priority resolver, using BG0CNT's priority for the layer
//     (GBATEK) and DISP3DCNT bit 0 as the layer enable (0x04000060, byte
//     offset 0x60 of engine A).
//
// Bandwidth, measured in tb_3d_path through the real chain (this module ->
// vram_arbiter -> mem_arbiter -> sdram_ctrl): 322 clocks per line
// uncontended against a 1280-clock line period, so the merge finishes well
// inside its line. That came from asking for bursts instead of a request
// per pixel: one per-pixel request paid a full round trip (ACT, RCD, READ,
// CL through three arbiters) per halfword and cost 3965 clocks a line,
// which the line buffers could only answer by repeating a completed line.
// A burst pays the row and the round trip once and then streams, so the
// remaining per-line cost is the beats themselves plus the four grants.
//
// Rendering model: the composer asks for pixel (x, y); the answer is a
// combinational read of the FRONT line-buffer bank (same contract as the
// M1 stub). Behind it a fetch FSM streams the NEXT scanline out of VRAM
// through vram_arbiter and composites it directly into the BACK bank
// with full DS priority rules. At each line start the display side
// swaps in whatever line the fetch side has completed (one-bit bank
// flip, only ever taken while the fetch FSM is idle, so no tearing);
// a line that misses its deadline shows the previous contents for one
// line and the pipeline recovers on the next swap. During blanking the
// fetcher keeps line 0 ready so the first active line is valid.
//
// Bandwidth: a 4bpp BG layer costs one map burst plus one tile-row burst
// per column (33 grants, 96 beats for a 256-pixel line), and a sprite row
// is one more burst. The per-line budget is 1280 clocks, so a BG line plus
// a couple of sprites now fits it with the OAM scan inside the same line:
// the scan is a pipeline over the second OAM port (ATTR0 issued the clock
// before ATTR1, one attribute per clock, 258 clocks for all 128 entries)
// and the entries that pass the y/height test are drawn afterwards in OAM
// order. ATTR2 and tile data are only read for those hits, matching the
// hardware scan order. Measured numbers live in fpga/README.md.
//
// Unrotated layouts (stacked / side / top / bottom) present scan-
// ordered lines to each engine, so they render exactly; the composer's
// per-pixel rotation remap needs the M3 scaler path instead of line
// buffers.
//============================================================================
module renderer_2d (
	input            clk,
	input            reset,
	input            pixel_ce,

	// composer request (fixed contract, same as the M1 stub)
	input      [7:0] px,
	input      [7:0] py,
	input            on,
	output    [15:0] rgb555,

	// engine register writes (byte offset within the engine's IO block)
	input            reg_we,
	input      [6:0] reg_addr,
	input     [15:0] reg_data,

	// palette read port (2-cycle latency; halfword index 0..511 BG,
	// 512..1023 OBJ)
	output reg [9:0] pal_addr,
	input     [15:0] pal_data,

	// OAM read port (2-cycle latency; halfword index)
	output reg [9:0] oam_addr,
	input     [15:0] oam_data,

	// VRAM fetch port: a burst of v_len halfwords (v_req held until v_ready),
	// streamed back one beat per cycle on v_bs_valid, in address order
	output reg       v_req,
	output reg [19:0] v_addr,
	output reg  [7:0] v_len,
	input            v_ready,
	input            v_bs_valid,
	input     [15:0] v_bs_data,

	// 3D frame read port (engine A only; byte offset inside the bank whose
	// VRAMCNT MST is 2, same address space the rasterizer writes). A request
	// is a burst of d3_len halfwords, streamed back one per cycle on
	// d3_bs_valid with d3_ready marking the end of the burst.
	output reg       d3_req,
	output reg [16:0] d3_addr,
	output reg  [7:0] d3_len,
	input            d3_ready,
	input            d3_bs_valid,
	input     [15:0] d3_bs_data,
	input            d3_present,   // 1 = this engine owns the 3D layer

	// OBJ tile base inside the engine's VRAM window
	input     [19:0] obj_base
);

localparam [1:0] KIND_BD  = 2'd0,  // backdrop (lowest)
                 KIND_BG  = 2'd1,
                 KIND_OBJ = 2'd2,
                 KIND_3D  = 2'd3;  // between BG and OBJ on priority ties

//------------------------------------------------------------------
// Registers (byte offsets follow the DS IO map)
//------------------------------------------------------------------
reg [15:0] dispcnt = 0;
reg [15:0] disp3dcnt = 0;   // 0x40 -> DISP3DCNT (bit 0 enables the layer)
reg [15:0] bgcnt [0:3];
reg [9:0]  bghofs [0:3];
reg [9:0]  bgvofs [0:3];

integer i;
initial begin
	for (i = 0; i < 4; i = i + 1) begin
		bgcnt[i]  = 16'd0;
		bghofs[i] = 10'd0;
		bgvofs[i] = 10'd0;
	end
end

always @(posedge clk) begin
	if (reg_we) begin
		case (reg_addr)
		7'h00: dispcnt   <= reg_data;
		7'h08: bgcnt[0]  <= reg_data;
		7'h0A: bgcnt[1]  <= reg_data;
		7'h0C: bgcnt[2]  <= reg_data;
		7'h0E: bgcnt[3]  <= reg_data;
		7'h48: bghofs[0] <= reg_data[9:0];
		7'h4A: bgvofs[0] <= reg_data[9:0];
		7'h4C: bghofs[1] <= reg_data[9:0];
		7'h4E: bgvofs[1] <= reg_data[9:0];
		7'h50: bghofs[2] <= reg_data[9:0];
		7'h52: bgvofs[2] <= reg_data[9:0];
		7'h54: bghofs[3] <= reg_data[9:0];
		7'h56: bgvofs[3] <= reg_data[9:0];
		7'h60: disp3dcnt <= reg_data;
		default: ;
		endcase
	end
	if (reset) begin
		dispcnt   <= 16'd0;
		disp3dcnt <= 16'd0;
	end
end

// only the low two bits select a text layout: modes 4-7 (bitmap, extended
// rotation, the two large-screen modes) are not implemented by this text
// renderer, and bit 2 is dropped deliberately so they fall back to the layout
// their low bits name rather than to undefined behaviour.
// Quartus reports this net as "assigned but never read": its only readers sit
// inside bg_enabled(), and Verific's function-body read analysis misses those
// (the same blind spot that makes the cores' SPSRs look unused).
wire [1:0] mode   = dispcnt[1:0];
wire       obj_en = dispcnt[12];

// 3D layer: present only in engine A, switched by DISP3DCNT bit 0, and
// taking its priority from BG0CNT (GBATEK: the 3D layer is "BG0").
wire       d3_on   = d3_present && disp3dcnt[0] && !dispcnt[7];
wire [1:0] d3_prio = bgcnt[0][1:0];

function automatic bg_enabled;
	input [1:0] k;
	begin
		case (k)
		2'd0: bg_enabled = dispcnt[8]  && (mode == 2'd0 || mode == 2'd1);
		2'd1: bg_enabled = dispcnt[9]  && (mode == 2'd0 || mode == 2'd1);
		2'd2: bg_enabled = dispcnt[10] && (mode == 2'd0);
		default: bg_enabled = dispcnt[11] && (mode == 2'd0);
		endcase
	end
endfunction

//------------------------------------------------------------------
// Line buffers. An entry holds four composite pixels of 21 bits
// {kind[1:0], prio[1:0], opaque, rgb[15:0]}, so one 84-bit word is a pixel
// quad and 64 words are one 256-pixel line. Quads rather than pairs are what
// let the backdrop fill write four pixels a clock (64 fill clocks instead of
// 128) with the same 10,752 bits of storage.
//
//   * `wbank` is the line being composited, held in registers: the composite
//     does a read-modify-write per pixel against the pixel already there, and
//     that read has to land in the same cycle as the write.
//   * `lbuf` holds *both display banks* in block RAM, addressed {bank, quad}.
//     Every write to `wbank` is mirrored into the back bank, so when the swap
//     makes it the front bank it is already a finished line — the display
//     reads bank `front_is_a` while the composite fills the other one
//     (AREA.md item 3, "the second shadow bank"). The display never reads a
//     bank that is still being built, which is what a single write-through
//     shadow got wrong.
//
// The display read is registered, so a pixel arrives one clock after its
// address. The composer already holds its own decision for one CE, and
// NDS.sv delays the video timing chain by the same cycle to match.
//------------------------------------------------------------------
reg [83:0] wbank [0:63];               // line being composited (registers)
reg [83:0] lbuf  [0:127];              // two display banks (block RAM)
reg        front_is_a = 1'b1;          // which display bank holds the finished line

reg [7:0]  back_line = 8'hFF;          // line currently valid in the back bank
reg        prev_on = 1'b0;             // display side: last on/py, for the swap
reg [7:0]  prev_py = 8'd0;

// The swap is registered, but the address has to follow it in the cycle the
// new line's first pixel is asked for — the flop version swapped instantly, so
// a registered-only select would show one pixel of the previous line at the
// start of every scanline.
wire       line_start = on && (py != prev_py || !prev_on);
wire       swp        = line_start && (back_line != 8'hFF);
wire       disp_bank  = front_is_a ^ swp;
// The write side must *not* follow `swp`: the swap pulse only lasts the one
// cycle in which the front flop has not moved yet, while a fetch and its
// composite run for hundreds of cycles. Following it here pointed the write
// at the bank the display was about to read (and split a fill across both
// banks). front_is_a is already the bank being displayed once the flip has
// happened, so the one the composite fills is simply its complement.
wire       back_bank  = ~front_is_a;   // the one the composite is filling

reg  [83:0] disp_q = 84'h0;

// One write port into the display copy, shared by the fill and the composite.
// Both the read and the single write live in the main clocked process (see
// the top and bottom of it): with the read and writes in different processes,
// or with two write sites in one process, Quartus reports "unsupported
// read-during-write behavior" and falls back to 10,752 registers (Info
// 276009). A register for enable/address/data per site and one array write
// statement is what makes it a simple dual-port RAM with read-old-data.
reg        lb_we;
reg  [6:0] lb_wa;
reg [83:0] lb_wd;

// which of the quad's four pixels the display is on
wire [20:0] fe = (px[1:0] == 2'd0) ? disp_q[20:0]
               : (px[1:0] == 2'd1) ? disp_q[41:21]
               : (px[1:0] == 2'd2) ? disp_q[62:42]
                                   : disp_q[83:63];

// `on` and px stay live: the read settles a clock after the address, well
// inside one pixel CE (clk/5), so the pixel is present when it is sampled.
assign rgb555 = !on ? 16'h0000 : (fe[16] ? fe[15:0] : 16'h0000);

// DS priority resolution: everything beats the backdrop; between a BG
// and an OBJ the lower priority value wins and OBJ wins ties; between
// BGs the lower number wins ties (layers walk 3->0, later write wins);
// between sprites the lower OAM index wins (walk 0->127, later write
// wins only on strictly lower priority).
// Equal priority across kinds resolves OBJ > 3D > BG (the 3D layer takes
// BG0's slot, so it beats the BGs it ties with but never a sprite).
function automatic [1:0] px_rank;
	input [1:0] k;
	begin
		case (k)
		KIND_BG: px_rank = 2'd0;
		KIND_3D: px_rank = 2'd1;
		default: px_rank = 2'd2;   // OBJ
		endcase
	end
endfunction

function automatic px_win;
	input [1:0] nk; input [1:0] ck;
	input [1:0] np; input [1:0] cp;
	begin
		if (ck == KIND_BD)      px_win = 1'b1;
		else if (nk != ck)      px_win = (np != cp) ? (np < cp)
		                                            : (px_rank(nk) > px_rank(ck));
		else if (nk == KIND_BG) px_win = (np <= cp);
		else                    px_win = (np <  cp);
	end
endfunction

//------------------------------------------------------------------
// Fetch FSM states
//------------------------------------------------------------------
localparam [4:0]
	S_IDLE      = 5'd0,
	S_BD_REQ    = 5'd1,   // read BG palette 0 (backdrop)
	S_BD_WAIT   = 5'd2,
	S_FILL      = 5'd3,   // fill back bank with the backdrop colour
	S_LAYER     = 5'd4,   // pick the next enabled BG layer
	S_MAP_REQ   = 5'd5,
	S_MAP_WAIT  = 5'd6,
	// 7 and 21 were the per-entry palette-bank states; both fills below are
	// rolling pipelines now, so those states are unreachable and gone.
	S_PB_WAIT   = 5'd8,
	S_TILE_REQ  = 5'd9,
	S_TILE_WAIT = 5'd10,
	S_PXC       = 5'd11,  // composite one BG pixel
	S_PAL_REQ   = 5'd12,  // 8bpp BG per-pixel palette read
	S_PAL_WAIT  = 5'd13,
	S_OAM_REQ   = 5'd14,  // ATTR2 of a sprite that passed the y test
	S_OAM_WAIT  = 5'd15,
	S_SHW_REQ   = 5'd16,  // sprite tile-row halfword fetch
	S_SHW_WAIT  = 5'd17,
	S_SPIXC     = 5'd18,  // composite one OBJ pixel
	S_SPAL_REQ  = 5'd19,  // 8bpp OBJ per-pixel palette read
	S_SPAL_WAIT = 5'd20,
	S_SPB_WAIT  = 5'd22,
	S_DONE      = 5'd23,
	S_D3_RUN    = 5'd24,  // 3D layer merge: burst fetch + composite
	S_COL       = 5'd25,  // latch this column's map entry
	S_PF_WAIT   = 5'd26,  // collect the prefetched tile row
	S_OAM_SCAN  = 5'd27,  // pipelined OAM walk: one attribute per clock
	S_HIT_NEXT  = 5'd28;  // advance to the next sprite that hit
	// S_COL_CHK and S_PXC_GO used to sit between a column's pixels: one clock
	// to check the 4bpp palette bank and one to start the next column's fetch,
	// both with exactly one job. Both now ride on the cycle that already
	// advances the column -- the fetch there is a clock earlier than its state
	// was, which is what lets the prefetch land behind the eight pixels -- and
	// the wait is skipped outright when the burst has landed. Two clocks a
	// column, so a 256-pixel BG layer measures 567 -> 504 clocks of walk and
	// 1196 -> 1133 for the line; the quad-wide backdrop fill takes another 64
	// (BG 440, line 1069 -- tb_renderer_2d +states).

reg [4:0]  fstate = S_IDLE;
reg [7:0]  tgt = 8'hFF;        // line being fetched into the back bank
// back_line, prev_on and prev_py are declared with the line buffers, because
// the display bank select is combinational on them

// line-request mailbox (display side -> fetch side)
reg        fetch_req = 0;
reg [7:0]  fetch_line = 0;
reg [11:0] blank_cnt = 0;      // saturates at 4096 (deep blanking)

// BG walk
reg        phase_bg = 1'b1;    // 1 = BG phase, 0 = OBJ phase
reg [1:0]  lk = 2'd3;          // current BG layer, walks 3->0
reg [5:0]  col = 6'd0;         // screen tile column 0..32
reg [1:0]  hw_i = 2'd0;        // halfword within the current tile row
reg [1:0]  pxi = 2'd0;         // pixel within the halfword
reg [4:0]  pbi = 5'd0;         // palette-bank fill index
reg [5:0]  fill_i = 6'd0;      // backdrop-fill quad index
reg [15:0] map_e = 16'd0;      // map entry of the column being composited
// Map row: one burst covers a 32-entry half-row, two cover a 64-wide map,
// so a layer's whole map line costs one or two grants instead of 32.
reg [15:0] map_row [0:63];
reg [6:0]  map_wr = 7'd0;      // write index while a map burst streams
reg        map_half = 1'b0;    // 0/1 = which 32-entry half is in flight
// latched copy of the current layer's BGxCNT and scroll registers
reg [15:0] l_bgcnt = 16'd0;
reg  [9:0] l_hofs = 10'd0, l_vofs = 10'd0;
// Tile rows: the composite reads one buffer while the next column's burst
// fills the other, so a column's fetch hides behind the previous one.
reg [15:0] tbuf [0:7];         // 2 buffers x 4 halfwords
reg        tcur = 1'b0;        // buffer the composite is reading
reg  [2:0] twr = 3'd0;         // write index into the other buffer
reg        pf_on = 1'b0;       // a tile prefetch is in flight
reg        pf_rdy = 1'b0;      // ... and its last beat has arrived
reg  [4:0] bg_ret = S_PXC;     // where a palette-bank load returns to
reg [15:0] pcache [0:15];      // shared 16-entry palette cache
reg [3:0]  pcache_bank = 4'd0;
reg        pcache_obj = 1'b0;  // cache holds OBJ palettes when set
reg        pcache_ok = 1'b0;
reg [15:0] pal_hold = 16'd0;   // last direct palette read (BG side)
reg        pal_ready = 1'b0;

// shared 2-cycle port-read countdown; pal_ret/pal_obj select the
// destination of S_PAL_WAIT
reg [1:0]  port_wc = 2'd0;
// five bits, like `fstate`: the FSM has 31 states and the 8bpp OBJ path
// returns to S_SPIXC (5'd18). At four bits that stored 2 = S_BD_WAIT, so an
// 8bpp sprite pixel took the backdrop wait instead of its composite step
reg [4:0]  pal_ret = S_IDLE;
reg        pal_obj = 1'b0;

// OBJ walk
//
// The per-line OAM scan used to be the bulk of the OBJ pass: two reads per
// entry with a handshake each, ~770 clocks for 128 entries. The second OAM
// port is a one-address-per-clock BRAM read, so the walk is a pipeline
// instead: ATTR0 of an entry is issued the clock before its ATTR1, the
// y/height test runs when ATTR1 comes back two clocks later, and no clock
// is left idle. That is 258 clocks for the whole of OAM.
//
// Hitting a sprite must not stall that pipeline (one attribute would be in
// flight and get lost), so the walk collects the entries that passed the
// test into a hit list and the sprite path draws them afterwards, in OAM
// order. 32 hits per line is the cap; beyond it extra sprites are dropped.
reg [6:0]  os_idx = 7'd0;      // entry whose sprite is being set up
reg [1:0]  ostep = 2'd0;       // draw path: 0 ATTR0, 1 ATTR1, 2 ATTR2
reg [8:0]  sc_n   = 9'd0;      // attributes the scan has issued (2/entry)
reg [15:0] sc_a0  = 16'd0;     // ATTR0 of the entry whose ATTR1 is arriving
reg [6:0]  hit_idx [0:31];     // entries that passed the y/height test
reg [5:0]  hit_n  = 6'd0;
reg [5:0]  hit_rd = 6'd0;
reg [15:0] o_a0 = 16'd0, o_a1 = 16'd0;
reg [8:0]  sx = 9'd0;          // sprite x (raw 9-bit)
reg [6:0]  s_w = 7'd0, s_h = 7'd0;
reg [9:0]  s_tile = 10'd0;
reg [1:0]  s_prio = 2'd0;
reg        s_hflip = 1'b0, s_vflip = 1'b0, s_bpp8 = 1'b0;
reg [5:0]  shw = 6'd0;         // halfword within the sprite row
reg [1:0]  spx = 2'd0;         // pixel within the sprite halfword
reg [15:0] sdata = 16'd0;      // current sprite halfword
// a sprite row is fetched as one burst (w/4 or w/2 halfwords, up to 16 for
// a 64-wide 4bpp sprite) instead of one round trip per halfword
reg [15:0] sbuf [0:31];        // a 64-wide 8bpp row is 32 halfwords
reg  [5:0] swr = 6'd0;         // write index while the row burst streams
reg [4:0]  spbi = 5'd0;        // OBJ palette-bank fill index
// 3D merge pass: the line is fetched as D3_CHUNK-halfword bursts and each
// beat is composited the cycle it arrives, so the pass is paced by the
// memory burst rate rather than by a round trip per pixel. Smaller chunks
// leave the VRAM arbiter to the other engines between bursts (a whole
// 256-halfword line held in one grant would block a fifth of the line).
localparam [8:0] D3_LINE  = 9'd256;              // pixels per line
localparam [7:0] D3_CHUNK = 8'd64;               // pixels per burst
// A pixel is one stored halfword, addressed by two byte offsets (this core
// keeps the DS's one-address-unit-per-byte VRAM window and the arbiter
// halves offsets into slots), so a chunk starts at column*2 and the burst
// itself walks one slot per beat: contiguous, no wasted beats.

reg [8:0]  d3_issue = 9'd0;    // pixels requested so far (256 = all)
reg [7:0]  d3_col = 8'd0;      // next column to composite
reg [15:0] spal_hold = 16'd0;
reg        spal_ready = 1'b0;
reg [13:0] sp_wh_r = 14'd0;    // latched {w,h}

//------------------------------------------------------------------
// Sprite shape/size table (GBATEK): {w[6:0], h[6:0]} in pixels.
// 7-bit fields because 64 needs 7 bits.
//------------------------------------------------------------------
function automatic [13:0] spr_wh;
	input [1:0] shape;
	input [1:0] sz;
	begin
		case (shape)
		2'd0: case (sz) // square
			2'd0: spr_wh = {7'd8,  7'd8};
			2'd1: spr_wh = {7'd16, 7'd16};
			2'd2: spr_wh = {7'd32, 7'd32};
			default: spr_wh = {7'd64, 7'd64};
		endcase
		2'd1: case (sz) // horizontal
			2'd0: spr_wh = {7'd16, 7'd8};
			2'd1: spr_wh = {7'd32, 7'd8};
			2'd2: spr_wh = {7'd32, 7'd16};
			default: spr_wh = {7'd64, 7'd32};
		endcase
		2'd2: case (sz) // vertical
			2'd0: spr_wh = {7'd8,  7'd16};
			2'd1: spr_wh = {7'd8,  7'd32};
			2'd2: spr_wh = {7'd16, 7'd32};
			default: spr_wh = {7'd32, 7'd64};
		endcase
		default: spr_wh = {7'd8, 7'd8}; // square, size 3
		endcase
	end
endfunction

//------------------------------------------------------------------
// BG geometry (combinational from walk state)
//------------------------------------------------------------------
// The layer's BGxCNT/scroll values are latched into l_* regs at layer start.
// They are stable for the whole line, and a plain reg keeps the address
// arithmetic in continuous assignments off the array-read sensitivity that
// some simulators resolve unreliably (same note as vram_arbiter's decode).
wire        bg_wide = (l_bgcnt[15:14] == 2'd1) || (l_bgcnt[15:14] == 2'd3);
wire        bg_tall = (l_bgcnt[15:14] == 2'd2) || (l_bgcnt[15:14] == 2'd3);
wire        bg_bpp8 = l_bgcnt[7];
wire [1:0]  bg_prio = l_bgcnt[1:0];
wire [2:0]  y_in    = tgt[2:0];
wire [6:0]  mcol_f  = {1'b0, l_hofs[8:3]} + {1'b0, col};
wire [6:0]  mcol_f_n= {1'b0, l_hofs[8:3]} + {1'b0, col} + 7'd1;
wire [6:0]  mrow_f  = {1'b0, l_vofs[8:3]} + {2'd0, tgt[7:3]};
wire [5:0]  mcol    = mcol_f[5:0] & (bg_wide ? 6'd63 : 6'd31);
wire [5:0]  mcol_n  = mcol_f_n[5:0] & (bg_wide ? 6'd63 : 6'd31);
wire [5:0]  mcol_n2 = (mcol_f_n[5:0] + 6'd1) & (bg_wide ? 6'd63 : 6'd31);
wire [5:0]  mrow    = mrow_f[5:0] & (bg_tall ? 6'd63 : 6'd31);
// GBATEK block layout: 64x32 -> right at +2K; 32x64 -> bottom at +2K;
// 64x64 -> TR +2K, BL +4K, BR +6K. A map row is 32 consecutive entries per
// block half, which is exactly one burst, so the whole row is 1 or 2
// grants instead of one read per tile column.
// screen base block is BGxCNT[12:8] (2 KB each); the size bits above it are
// not part of the address, or a 64-wide map would fetch from the wrong block
wire [19:0] map_burst = {4'd0, l_bgcnt[12:8], 11'd0}
                      + ((bg_wide && bg_tall) ? {7'd0, mrow_f[6], map_half, 11'd0}
                       : bg_wide             ? {8'd0, map_half, 11'd0}
                       : bg_tall             ? {8'd0, mrow_f[6], 11'd0}
                                             : 20'd0)
                      + {9'd0, mrow[4:0], 6'd0};

// one tile row: 4bpp is 4 bytes (2 halfwords), 8bpp 8 bytes (4 halfwords)
wire  [7:0] bg_nhw = bg_bpp8 ? 8'd4 : 8'd2;

function [19:0] trow_addr;   // character address of a tile row
	input [15:0] me;           // its map entry
	input [2:0]  vr;           // row inside the tile (vflip applied)
	begin
		// every term is declared at the 20-bit address width so nothing is
		// silently truncated away on the way into the sum
		trow_addr = {l_bgcnt[3:2], 14'd0}                          // char base
		          + (bg_bpp8 ? {4'd0, me[9:0], 6'd0}     // *64
		                     : {5'd0, me[9:0], 5'd0})    // *32
		          + (bg_bpp8 ? {14'd0, vr, 3'd0}         // *8
		                     : {15'd0, vr, 2'd0});       // *4
	end
endfunction

wire [2:0]  vrow    = map_e[11] ? (3'd7 - y_in) : y_in;      // vflip
wire [19:0] tile_addr = trow_addr(map_e, vrow);
// the next column is prefetched during this column's composite, so its
// address is built from its map entry directly out of the row buffer
wire [15:0] map_e_n = map_row[mcol_n];
wire [2:0]  vrow_n  = map_e_n[11] ? (3'd7 - y_in) : y_in;
wire [19:0] tile_addr_n = trow_addr(map_e_n, vrow_n);
// the fetch is raised on the cycle that advances the column, so the row it
// asks for is the one two columns along
wire [15:0] map_e_n2 = map_row[mcol_n2];
wire [2:0]  vrow_n2  = map_e_n2[11] ? (3'd7 - y_in) : y_in;
wire [19:0] tile_addr_n2 = trow_addr(map_e_n2, vrow_n2);

wire [2:0]  bg_pph  = bg_bpp8 ? 3'd2 : 3'd4;   // pixels per halfword
wire [3:0]  bg_tlp  = (bg_pph == 3'd4 ? {hw_i, 2'd0} : {1'b0, hw_i, 1'b0})
                    + {2'd0, pxi};             // hw_i*pph + pxi
wire [2:0]  bg_xoff = map_e[10] ? (3'd7 - bg_tlp[2:0]) : bg_tlp[2:0];
wire signed [10:0] bg_xs = $signed({2'd0, col, 3'd0})
                         - $signed({8'd0, bghofs[lk][2:0]})
                         + $signed({7'd0, bg_xoff});
wire        bg_xs_ok = (bg_xs >= 0) && (bg_xs < 256);
wire [15:0] bg_hw  = tbuf[{tcur, hw_i}];   // current tile-row halfword
wire [7:0]  bg_idx = bg_bpp8 ? (pxi[0] ? bg_hw[15:8] : bg_hw[7:0])
                             : (pxi == 2'd0) ? bg_hw[3:0]
                             : (pxi == 2'd1) ? bg_hw[7:4]
                             : (pxi == 2'd2) ? bg_hw[11:8]
                                             : bg_hw[15:12];

// last column is only needed when the horizontal scroll has a
// sub-tile offset (otherwise column 31 already ends at x=255)
wire        col_last = (col == 6'd32) ||
                       ((col == 6'd31) && (bghofs[lk][2:0] == 3'd0));

// 4bpp resolves through the 16-entry palette bank cache, so the bank an entry
// selects has to be resident before its column composites; 8bpp reads the port
// per pixel instead. Called from the two cycles that begin a column.
function automatic need_pal;
	input [15:0] me;
	begin
		need_pal = !bg_bpp8 && !(pcache_ok && !pcache_obj
		                         && pcache_bank == me[15:12]);
	end
endfunction

//------------------------------------------------------------------
// Sprite geometry
//------------------------------------------------------------------
wire [7:0]  sp_dy   = tgt - o_a0[7:0];          // wraps mod 256
// size lookup (function results need an intermediate for bit-selects)
wire [13:0] sp_wh2  = spr_wh(o_a0[9:8], o_a1[15:14]);     // ATTR2 time

//------------------------------------------------------------------
// OAM scan pipeline (combinational view of the walk)
//------------------------------------------------------------------
// sc_n counts attributes, not entries: 0/1 = ATTR0/ATTR1 of entry 0, and
// so on. The port answers two clocks after its address is set, so the
// attribute arriving this cycle is sc_n-2 and the address for sc_n goes out
// at the same time: one attribute in, one out, every clock.
wire [9:0]  ev_idx   = {1'b0, sc_n} - 10'd2;    // attribute arriving now
wire [6:0]  ev_ent   = ev_idx[7:1];             // entry it belongs to
wire        ev_attr  = ev_idx[0];               // 0 = ATTR0, 1 = ATTR1
wire [6:0]  sc_ent   = sc_n[7:1];               // entry being addressed
wire        sc_attr  = sc_n[0];
wire [9:0]  sc_addr  = {1'b0, sc_ent, 2'd0} + {9'd0, sc_attr};
wire [7:0]  sc_dy    = tgt - sc_a0[7:0];        // sprite y vs line, mod 256
wire [13:0] sc_wh    = spr_wh(sc_a0[9:8], oam_data[15:14]);
// same test the per-entry path used: normal (not affine/disabled) sprites
// whose height from ATTR1 covers this line
wire        sc_hit   = (sc_a0[15:14] == 2'd0)
                    && ({3'd0, sc_dy} < {4'd0, sc_wh[6:0]});

wire [2:0]  s_pph   = s_bpp8 ? 3'd2 : 3'd4;
wire [5:0]  s_nhw   = s_bpp8 ? s_w[6:1] : s_w[6:2];      // w/2 or w/4
wire [7:0]  s_row   = s_vflip ? (sp_wh_r[6:0] - 8'd1 - sp_dy)
                              : sp_dy;
wire [2:0]  s_trow  = s_row[5:3];
wire [2:0]  s_vrow  = s_row[2:0];
wire [7:0]  s_bpr   = s_bpp8 ? {1'b0, s_w[6:3], 3'd0}    // (w/8)*8
                             : {2'd0, s_w[6:3], 2'd0};   // (w/8)*4
wire [19:0] shw_row  = s_trow * s_bpr;                    // row start, ≤ 7*2040
wire [19:0] shw_addr = obj_base + {5'd0, s_tile, 5'd0}     // *32
                     + shw_row
                     + (s_bpp8 ? {14'd0, s_vrow, 3'd0}
                               : {15'd0, s_vrow, 2'd0})
                     + {13'd0, shw, 1'd0};
// screen x of the current sprite pixel (x >= 256 wraps offscreen)
wire signed [10:0] s_x0 = sx[8] ? ($signed({2'd0, sx}) - 11'sd512)
                                 : $signed({2'd0, sx});
wire [7:0]  s_tlp8  = (s_pph == 3'd4 ? {shw, 2'd0} : {1'b0, shw, 1'b0})
                    + {5'd0, spx};             // shw*pph + spx
wire [6:0]  s_tlp   = s_tlp8[6:0];             // a row is at most 64 pixels
wire [6:0]  s_poff  = s_hflip ? (sp_wh_r[6:0] - 7'd1 - s_tlp)
                              : s_tlp;
wire signed [10:0] s_xs = s_x0 + $signed({4'd0, s_poff});
wire        s_xs_ok = (s_xs >= 0) && (s_xs < 256);
wire [7:0]  s_idx = s_bpp8 ? (spx[0] ? sdata[15:8] : sdata[7:0])
                            : (spx == 2'd0) ? sdata[3:0]
                            : (spx == 2'd1) ? sdata[7:4]
                            : (spx == 2'd2) ? sdata[11:8]
                                            : sdata[15:12];

// OAM entries are four halfwords each, so the draw path walks 4n + ostep:
// ATTR0, ATTR1 (x / flips / size) and ATTR2 (tile / priority / bank)
wire [9:0]  oam_rd_addr = {1'b0, os_idx, 2'd0} + {8'd0, ostep};

//------------------------------------------------------------------
// Composite write: read-modify-write one pixel of the back bank
//------------------------------------------------------------------
task automatic write_px;
	input signed [10:0] xs;
	input [1:0]  nk;
	input [1:0]  np;
	input [15:0] colr;
	reg [83:0] e;
	reg [20:0] cur;
	begin
		// assigned before the guard: a local written only inside it is what
		// Verific reports as warning 10776 ("may have unintended latch
		// behavior"), which is noise here -- the guard is what keeps the
		// array index in range, so the defaults are never observable
		e   = 84'd0;
		cur = 21'd0;
		if (xs >= 0 && xs < 256) begin
			e = wbank[xs[8:2]];
			case (xs[1:0])
			2'd0:    cur = e[20:0];
			2'd1:    cur = e[41:21];
			2'd2:    cur = e[62:42];
			default: cur = e[83:63];
			endcase
			if (px_win(nk, cur[20:19], np, cur[18:17])) begin
				case (xs[1:0])
				2'd0:    e[20:0]  = {nk, np, 1'b1, colr};
				2'd1:    e[41:21] = {nk, np, 1'b1, colr};
				2'd2:    e[62:42] = {nk, np, 1'b1, colr};
				default: e[83:63] = {nk, np, 1'b1, colr};
				endcase
				wbank[xs[8:2]] <= e;
				// the mirror address is {bank, quad} -- 6 bits of quad, or the
				// bank bit would shift the index past the end of the array
				lb_we <= 1'b1;                        // the display's copy
				lb_wa <= {back_bank, xs[7:2]};
				lb_wd <= e;
			end
		end
	end
endtask

//------------------------------------------------------------------
// Next column. Called from the pixel state when the prefetch has already
// landed (the common case: the burst streams during the eight pixels) and
// from the wait state when it has not. The other buffer becomes current,
// the column advances, and its palette bank is settled when 4bpp -- the
// new entry comes in as an argument so both callers are one line.
//------------------------------------------------------------------
task automatic bg_adv_col;
	input [15:0] me;
	begin
		twr    <= 3'd0;
		pf_rdy <= 1'b0;
		tcur   <= ~tcur;              // the buffer just filled is current now
		col    <= col + 6'd1;
		map_e  <= me;
		hw_i   <= 2'd0;
		pxi    <= 2'd0;
		// the row two columns along, asked for here rather than on the next
		// column's first pixel: the burst needs the eight pixels plus the
		// clock this advance used to spend as a state of its own. `col` is
		// still the column being left, so skip when the one just entered is
		// the last of the layer.
		if (!((col == 6'd31) || ((col == 6'd30) && (bghofs[lk][2:0] == 3'd0)))) begin
			v_req  <= 1'b1;
			v_addr <= tile_addr_n2;
			v_len  <= bg_nhw;
			pf_on  <= 1'b1;
			pf_rdy <= 1'b0;
			twr    <= 3'd0;
		end
		if (need_pal(me)) begin
			pcache_bank <= me[15:12];
			pcache_obj  <= 1'b0;
			pcache_ok   <= 1'b0;
			pbi         <= 5'd1;
			pal_addr    <= {2'd0, me[15:12], 4'd0};
			port_wc     <= 2'd2;
			bg_ret      <= S_PXC;
			fstate      <= S_PB_WAIT;
		end else begin
			fstate <= S_PXC;
		end
	end
endtask

//------------------------------------------------------------------
// Display side state (prev_on/prev_py sit with the line buffers)
//------------------------------------------------------------------

//------------------------------------------------------------------
// Main process. Order matters: the fetch FSM runs first and consumes
// fetch_req; the display side assigns afterwards, so a request raised
// in the same cycle a consume happens is never lost.
//------------------------------------------------------------------
always @(posedge clk) begin
	// display read: first statement, so a write to the same word in this
	// cycle returns the old data (the banks never overlap in practice --
	// the display reads the front bank while the composite writes the
	// back one -- but this is the order the RAM inferencer needs to see)
	disp_q <= lbuf[{disp_bank, px[7:2]}];

	// the display copy's write port: idle unless a site below drives it
	lb_we <= 1'b0;

	//------------------------
	// fetch FSM
	//------------------------
	case (fstate)
	S_IDLE: begin
		if (fetch_req) begin
			if (fetch_line == back_line || fetch_line >= 8'd192) begin
				fetch_req <= 1'b0;              // redundant: drop
			end else begin
				fetch_req   <= 1'b0;
				tgt         <= fetch_line;
				phase_bg    <= 1'b1;
				lk          <= 2'd3;
				pcache_ok   <= 1'b0;
				pcache_obj  <= 1'b0;
				pal_ready   <= 1'b0;
				spal_ready  <= 1'b0;
				fstate      <= S_BD_REQ;
			end
		end
	end

	S_BD_REQ: begin
		pal_addr <= 10'd0;                       // BG colour 0
		port_wc  <= 2'd2;
		pal_ret  <= S_FILL;
		pal_obj  <= 1'b0;
		fstate   <= S_BD_WAIT;
	end

	S_BD_WAIT: begin
		if (port_wc != 2'd1) port_wc <= port_wc - 2'd1;
		else begin
			pal_hold <= pal_data;                // backdrop colour
			col      <= 6'd0;
			fstate   <= S_FILL;
		end
	end

	S_FILL: begin
		// fill the back bank with the backdrop, one quad entry per cycle
		// (ALL FOUR pixels of it); pal_hold holds colour 0. Sixty-four
		// clocks for the 256-pixel line, against 128 when an entry was a
		// pair and the fill could only write two pixels a clock.
		wbank[fill_i] <= {4{{KIND_BD, 2'd3, 1'b1, pal_hold}}};
		lb_we <= 1'b1;                          // the display's copy
		lb_wa <= {back_bank, fill_i};
		lb_wd <= {4{{KIND_BD, 2'd3, 1'b1, pal_hold}}};

		if (fill_i == 6'd63) begin
			fill_i    <= 6'd0;
			lk        <= 2'd3;
			phase_bg  <= 1'b1;
			fstate    <= S_LAYER;
		end else begin
			fill_i <= fill_i + 6'd1;
		end
	end

	S_LAYER: begin
		// pick the next enabled BG layer walking 3->0; when none
		// remains continue with the OBJ phase
		if (phase_bg) begin
			if (bg_enabled(lk)) begin
				l_bgcnt  <= bgcnt[lk];
				l_hofs   <= bghofs[lk];
				l_vofs   <= bgvofs[lk];
				col      <= 6'd0;
				hw_i     <= 2'd0;
				pxi      <= 2'd0;
				map_half <= 1'b0;
				map_wr   <= 7'd0;
				tcur     <= 1'b0;
				pf_on    <= 1'b0;
				fstate   <= S_MAP_REQ;
			end else if (lk == 2'd0) begin
				phase_bg <= 1'b0;
				if (obj_en) begin
					sc_n    <= 9'd0;       // walk OAM from entry 0
					sc_a0   <= 16'd0;
					hit_n   <= 6'd0;
					fstate  <= S_OAM_SCAN;
				end else begin
					fstate <= S_DONE;
				end
			end else begin
				lk <= lk - 2'd1;
			end
		end else begin
			fstate <= S_DONE;                    // OBJ phase ended
		end
	end

	S_MAP_REQ: begin
		// a map row half: 32 entries, one burst
		v_req  <= 1'b1;
		v_addr <= map_burst;
		v_len  <= 8'd32;
		fstate <= S_MAP_WAIT;
	end

	S_MAP_WAIT: begin
		if (v_bs_valid) begin
			map_row[map_wr] <= v_bs_data;
			map_wr          <= map_wr + 7'd1;
		end
		if (v_ready) begin
			v_req <= 1'b0;
			// 64-wide maps keep columns 32..63 in the next block half
			if (bg_wide && !map_half) begin
				map_half <= 1'b1;
				map_wr   <= 7'd32;
				fstate   <= S_MAP_REQ;
			end else begin
				map_half <= 1'b0;
				fstate   <= S_COL;
			end
		end
	end

	S_COL: begin
		// the map entry for this column is already in the row buffer
		map_e  <= map_row[mcol];
		hw_i   <= 2'd0;
		pxi    <= 2'd0;
		fstate <= S_TILE_REQ;
	end

	S_PB_WAIT: begin
		// one address per clock: pal_data is the entry whose address
		// was visible two clocks back, so the 16-entry bank costs 17
		// clocks here instead of 32 when each entry paid its own
		// handshake. The first cycle fills the pipe, the last two drain.
		if (pbi >= 5'd2) pcache[pbi - 5'd2] <= pal_data;
		if (pbi == 5'd17) begin
			pbi       <= 5'd0;
			port_wc   <= 2'd0;
			pcache_ok <= 1'b1;
			hw_i      <= 2'd0;
			pxi       <= 2'd0;
			fstate    <= bg_ret;
		end else begin
			if (pbi <= 5'd15) pal_addr <= {2'd0, pcache_bank, pbi[3:0]};
			pbi <= pbi + 5'd1;
		end
	end

	S_TILE_REQ: begin
		// the whole tile row in one burst (2 halfwords at 4bpp, 4 at 8bpp)
		v_req  <= 1'b1;
		v_addr <= tile_addr;
		v_len  <= bg_nhw;
		twr    <= 3'd0;
		fstate <= S_TILE_WAIT;
	end

	S_TILE_WAIT: begin
		if (v_bs_valid) begin
			tbuf[{tcur, twr[1:0]}] <= v_bs_data;
			twr <= twr + 3'd1;
		end
		if (v_ready) begin
			v_req    <= 1'b0;
			twr      <= 3'd0;
			pxi      <= 2'd0;
			pal_ready<= 1'b0;
			// the column's data is here: settle its palette bank (4bpp) and
			// composite. This is where S_COL_CHK's own clock used to be.
			if (need_pal(map_e)) begin
				pcache_bank <= map_e[15:12];
				pcache_obj  <= 1'b0;
				pcache_ok   <= 1'b0;
				pbi         <= 5'd1;
				pal_addr    <= {2'd0, map_e[15:12], 4'd0};
				port_wc     <= 2'd2;
				bg_ret      <= S_PXC;
				fstate      <= S_PB_WAIT;
			end else begin
				fstate <= S_PXC;
			end
		end
	end

	S_PF_WAIT: begin
		// only reached when the burst did not finish behind the pixels; the
		// completion and the advance happen on the cycle it does
		if (pf_rdy) bg_adv_col(map_e_n);
	end

	S_PXC: begin
		// composite one BG pixel; 4bpp resolves through the cache,
		// 8bpp goes through the palette port first (pal_ready set).
		// Transparent pixels (index 0) advance without a write.
		if (bg_bpp8 && !pal_ready && bg_idx != 8'd0) begin
			pal_addr <= {2'd0, bg_idx};          // BG palette space
			port_wc  <= 2'd2;
			pal_ret  <= S_PXC;
			pal_obj  <= 1'b0;
			fstate   <= S_PAL_WAIT;
		end else begin
			// column 0 is entered from S_COL, so no advance has raised its
			// neighbour's fetch yet; every other column arrives with one in
			// flight (pf_on) or already landed (pf_rdy). The last column has
			// no neighbour, and the advance skips it there.
			if (!col_last && !pf_on && !pf_rdy && hw_i == 2'd0 && pxi == 2'd0) begin
				v_req  <= 1'b1;
				v_addr <= tile_addr_n;
				v_len  <= bg_nhw;
				pf_on  <= 1'b1;
				pf_rdy <= 1'b0;
				twr    <= 3'd0;
			end
			if (bg_xs_ok && (bg_bpp8 ? (bg_idx != 8'd0) : (bg_idx != 4'd0))) begin
				write_px(bg_xs, KIND_BG, bg_prio,
				         bg_bpp8 ? pal_hold : pcache[bg_idx[3:0]]);
			end
			pal_ready <= 1'b0;
			// advance one pixel
			if (pxi == bg_pph - 3'd1) begin
				pxi <= 2'd0;
				if (hw_i == (bg_bpp8 ? 2'd3 : 2'd1)) begin
					hw_i <= 2'd0;
					if (col_last) begin
						if (lk == 2'd0) begin
							phase_bg <= 1'b0;
							if (obj_en) begin
								sc_n    <= 9'd0;  // walk OAM from entry 0
								sc_a0   <= 16'd0;
								hit_n   <= 6'd0;
								fstate  <= S_OAM_SCAN;
							end else fstate <= S_DONE;
						end else begin
							lk <= lk - 2'd1;
							fstate <= S_LAYER;
						end
					end else if (pf_rdy) begin
						// the next column's row is already in the buffer: advance
						// on the last pixel instead of spending a clock waiting
						bg_adv_col(map_e_n);
					end else begin
						fstate <= S_PF_WAIT;
					end
				end else begin
					hw_i <= hw_i + 2'd1;    // next halfword is already buffered
				end
			end else begin
				pxi <= pxi + 2'd1;
			end
		end
	end

	S_PAL_WAIT: begin
		if (port_wc != 2'd1) port_wc <= port_wc - 2'd1;
		else begin
			if (pal_obj) begin
				spal_hold  <= pal_data;
				spal_ready <= 1'b1;
				fstate     <= pal_ret;
			end else begin
				pal_hold   <= pal_data;
				pal_ready  <= 1'b1;
				fstate     <= pal_ret;
			end
		end
	end

	S_OAM_SCAN: begin
		// one attribute in, one out, every clock
		if (ev_idx < 10'd256) begin
			if (ev_attr) begin
				// ATTR1 is here: test it against the ATTR0 latched
				// two clocks ago and record the entry if it shows
				if (sc_hit && hit_n < 6'd32) begin
					hit_idx[hit_n] <= ev_ent;
					hit_n <= hit_n + 6'd1;
				end
			end else sc_a0 <= oam_data;      // ATTR0 of ev_ent
		end
		// keep the pipeline fed, then let it drain (the last issued
		// attribute still costs two clocks to come back)
		if (sc_n < 9'd256) oam_addr <= sc_addr;
		if (sc_n < 9'd258) sc_n <= sc_n + 9'd1;
		if (sc_n == 9'd258) begin
			// all 128 entries walked and the last ATTR1 tested: draw what
			// hit, in OAM order
			if (hit_n == 6'd0) fstate <= S_DONE;
			else begin
				hit_rd <= 6'd0;
				os_idx <= hit_idx[0];
				ostep  <= 2'd0;
				fstate <= S_OAM_REQ;
			end
		end
	end

	S_OAM_REQ: begin
		oam_addr <= oam_rd_addr;
		port_wc  <= 2'd2;
		fstate   <= S_OAM_WAIT;
	end

	S_OAM_WAIT: begin
		if (port_wc != 2'd1) port_wc <= port_wc - 2'd1;
		else case (ostep)
		2'd0: begin
			o_a0   <= oam_data;              // ATTR0
			ostep  <= 2'd1;
			fstate <= S_OAM_REQ;
		end
		2'd1: begin
			o_a1   <= oam_data;              // ATTR1
			ostep  <= 2'd2;
			fstate <= S_OAM_REQ;
		end
		default: begin
			// ATTR2 latched: set up the sprite and start the
			// row fetch (loading the OBJ palette bank first
			// for 4bpp)
			ostep   <= 2'd0;
			sx      <= o_a1[8:0];
			s_hflip <= o_a1[12];
			s_vflip <= o_a1[13];
			s_bpp8  <= o_a0[13];
			s_tile  <= oam_data[9:0];
			s_prio  <= oam_data[10:9];
			// ATTR2's palette bank needs no register of its own: the palette
			// cache below is loaded from pcache_bank, taken straight from
			// ATTR2 while it is still on oam_data
			sp_wh_r <= sp_wh2;
			s_w     <= sp_wh2[13:7];
			shw     <= 6'd0;
			spx     <= 2'd0;
			if (o_a0[13]) begin               // 8bpp: per-pixel reads
				fstate <= S_SHW_REQ;
			end else if (pcache_ok && pcache_obj
			             && pcache_bank == oam_data[15:12]) begin
				fstate <= S_SHW_REQ;
			end else begin
				pcache_bank <= oam_data[15:12];
				pcache_obj  <= 1'b1;
				pcache_ok   <= 1'b0;
				spbi        <= 5'd1;
				pal_addr    <= 10'd512 + {2'd0, oam_data[15:12], 4'd0};
				port_wc     <= 2'd2;
				fstate      <= S_SPB_WAIT;
			end
		end
		endcase
	end

	S_HIT_NEXT: begin
		// the scan decided which entries show on this line; walk the list
		if (hit_rd + 6'd1 == hit_n) fstate <= S_DONE;
		else begin
			hit_rd <= hit_rd + 6'd1;
			os_idx <= hit_idx[hit_rd + 6'd1];
			ostep  <= 2'd0;
			fstate <= S_OAM_REQ;
		end
	end

	S_SHW_REQ: begin
		v_req  <= 1'b1;
		v_addr <= shw_addr;
		v_len  <= {2'd0, s_nhw};
		swr    <= 6'd0;
		fstate <= S_SHW_WAIT;
	end

	S_SHW_WAIT: begin
		if (v_bs_valid) begin
			sbuf[swr[4:0]] <= v_bs_data;
			swr <= swr + 6'd1;
		end
		if (v_ready) begin
			v_req      <= 1'b0;
			swr        <= 6'd0;
			sdata      <= sbuf[0];
			spx        <= 2'd0;
			spal_ready <= 1'b0;
			fstate     <= S_SPIXC;
		end
	end

	S_SPIXC: begin
		// composite one OBJ pixel; 8bpp resolves through the port
		if (s_bpp8 && !spal_ready) begin
			if (s_idx != 8'd0) begin
				pal_addr <= 10'd512 + {2'd0, s_idx};
				port_wc  <= 2'd2;
				pal_ret  <= S_SPIXC;
				pal_obj  <= 1'b1;
				fstate   <= S_PAL_WAIT;
			end else begin
				// transparent: advance
				if (spx == s_pph - 3'd1) begin
					spx <= 2'd0;
					if (shw == s_nhw - 6'd1) begin
						// row done: move on to the next entry that hit
						fstate <= S_HIT_NEXT;
					end else begin
						// next halfword is already in the row buffer
						shw    <= shw + 6'd1;
						sdata  <= sbuf[shw[4:0] + 5'd1];
						fstate <= S_SPIXC;
					end
				end else begin
					spx <= spx + 2'd1;
				end
			end
		end else begin
			if (s_xs_ok && (s_bpp8 ? (s_idx != 8'd0) : (s_idx != 4'd0))) begin
				write_px(s_xs, KIND_OBJ, s_prio,
				         s_bpp8 ? spal_hold : pcache[s_idx[3:0]]);
			end
			spal_ready <= 1'b0;
			if (spx == s_pph - 2'd1) begin
				spx <= 2'd0;
				if (shw == s_nhw - 6'd1) begin
					// row done: move on to the next entry that hit
					fstate <= S_HIT_NEXT;
				end else begin
					// next halfword is already in the row buffer
					shw    <= shw + 6'd1;
					sdata  <= sbuf[shw[4:0] + 5'd1];
					fstate <= S_SPIXC;
				end
			end else begin
				spx <= spx + 2'd1;
			end
		end
	end

	S_SPB_WAIT: begin
		// the same rolling fill as the BG bank, into the shared cache
		if (spbi >= 5'd2) pcache[spbi - 5'd2] <= pal_data;
		if (spbi == 5'd17) begin
			spbi      <= 5'd0;
			port_wc   <= 2'd0;
			pcache_ok <= 1'b1;
			shw       <= 6'd0;
			spx       <= 2'd0;
			fstate    <= S_SHW_REQ;
		end else begin
			if (spbi <= 5'd15) pal_addr <= 10'd512 + {2'd0, pcache_bank, spbi[3:0]};
			spbi <= spbi + 5'd1;
		end
	end

	S_DONE: begin
		// BG + OBJ are in the back bank; merge the 3D layer over them
		if (d3_on) begin
			d3_issue <= 9'd0;             // pixels requested so far
			d3_col   <= 8'd0;
			d3_req   <= 1'b1;
			d3_len   <= D3_CHUNK;
			d3_addr  <= {tgt, 9'd0};      // line*512 + column*stride
			fstate   <= S_D3_RUN;
		end else begin
			back_line <= tgt;
			fstate    <= S_IDLE;
		end
	end

	S_D3_RUN: begin
		// one beat per cycle while a burst streams; each beat is composited
		// into its own column, so adjacent columns never collide inside a
		// line-buffer word
		if (d3_bs_valid) begin
			// bit 15 clear = no polygon covered this pixel
			if (d3_bs_data[15])
				write_px({3'd0, d3_col}, KIND_3D, d3_prio,
				         {1'b0, d3_bs_data[14:0]});   // strip the coverage bit
			d3_col <= d3_col + 8'd1;
		end
		if (d3_ready) begin
			// burst complete: ask for the next chunk unless the line is done
			d3_issue <= d3_issue + {1'b0, D3_CHUNK};
			d3_req   <= 1'b0;
			if (d3_issue + {1'b0, D3_CHUNK} >= D3_LINE) begin
				back_line <= tgt;
				fstate    <= S_IDLE;
			end
		end else if (!d3_req) begin
			// re-arm for the next chunk from its own column
			d3_req  <= 1'b1;				d3_addr <= {tgt, 9'd0} + {5'd0, d3_issue, 1'b0};
		end
	end

	default: fstate <= S_IDLE;
	endcase

	//------------------------
	// prefetch collector: while a tile row for the next column is streaming,
	// its beats land in the buffer the composite is NOT reading. This runs
	// outside the case because the composite takes a variable number of
	// cycles (the 8bpp palette port adds a wait per pixel) and the burst may
	// finish before the column does.
	//------------------------
	if (pf_on) begin
		if (v_bs_valid) begin
			tbuf[{~tcur, twr[1:0]}] <= v_bs_data;
			twr <= twr + 3'd1;
		end
		if (v_ready) begin
			v_req  <= 1'b0;
			pf_on  <= 1'b0;
			pf_rdy <= 1'b1;
		end
	end

	//------------------------
	// display side: line tracking, swap, next-line request
	//------------------------
	prev_on <= on;
	prev_py <= py;
	if (on) blank_cnt <= 12'd0;
	else if (blank_cnt < 12'd4095) blank_cnt <= blank_cnt + 12'd1;

	// line start: py changes while this engine's pixels are shown, or
	// the first on pulse (covers py already equal to the reset value).
	// (on alone edges once per pixel because it is CE-gated; repeated
	// triggers are idempotent — the consume guard drops duplicates.)
	if (on && (py != prev_py || !prev_on)) begin
		if (back_line != 8'hFF) begin
			// swap in the most recently completed line; safe
			// because a valid back_line implies fetch-idle
			front_is_a <= ~front_is_a;
			back_line  <= 8'hFF;
		end
		if (py < 8'd191) begin
			fetch_req  <= 1'b1;
			fetch_line <= py + 8'd1;
		end
	end else if (!on && blank_cnt >= 12'd4095 && back_line == 8'hFF
	             && fstate == S_IDLE && !fetch_req) begin
		// deep blanking: pre-render line 0 for the next frame
		fetch_req  <= 1'b1;
		fetch_line <= 8'd0;
	end

	// the one write statement into the display copy, below every site that
	// drives it: last in the process, so a same-cycle read above sees the old
	// word (block RAM with read-old-data, instead of 10,752 registers)
	if (lb_we) lbuf[lb_wa] <= lb_wd;

	if (reset) begin
		fstate     <= S_IDLE;
		lb_we      <= 1'b0;
		tgt        <= 8'hFF;
		back_line  <= 8'hFF;
		fetch_req  <= 1'b0;
		fetch_line <= 8'd0;
		blank_cnt  <= 12'd0;
		front_is_a <= 1'b1;
		v_req      <= 1'b0;
		prev_on    <= 1'b0;
		prev_py    <= 8'd0;
		phase_bg   <= 1'b1;
		lk         <= 2'd3;
		col        <= 6'd0;
		hw_i       <= 2'd0;
		pxi        <= 2'd0;
		v_len      <= 8'd1;
		map_wr     <= 7'd0;
		map_half   <= 1'b0;
		twr        <= 3'd0;
		tcur       <= 1'b0;
		pf_on      <= 1'b0;
		bg_ret     <= S_PXC;
		swr        <= 6'd0;
		pbi        <= 5'd0;
		fill_i     <= 6'd0;
		spbi       <= 5'd0;
		os_idx     <= 7'd0;
		ostep      <= 2'd0;
		sc_n       <= 9'd0;
		sc_a0      <= 16'd0;
		hit_n      <= 6'd0;
		hit_rd     <= 6'd0;
		shw        <= 6'd0;
		spx        <= 2'd0;
		pcache_ok  <= 1'b0;
		pcache_obj <= 1'b0;
		pal_ready  <= 1'b0;
		spal_ready <= 1'b0;
		pal_ret    <= S_IDLE;
		pal_obj    <= 1'b0;
		d3_req     <= 1'b0;
		d3_addr    <= 17'd0;
		d3_len     <= 8'd0;
		d3_issue   <= 9'd0;
		d3_col     <= 8'd0;
	end
end

wire _unused = &{1'b0, pixel_ce, s_h, mcol, mrow, sp_wh2[13:7]};
	// Read the sink so the analyser does not call it "assigned but never read"
	// (warning 10036). The branch cannot be taken and synthesises to nothing:
	// measured on a throwaway module, the warning goes from 1 to 0 with this
	// line and the netlist is unchanged.
	always @(*) if (_unused) begin end


endmodule
