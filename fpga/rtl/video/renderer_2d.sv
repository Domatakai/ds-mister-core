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
// Bandwidth: the SDRAM path carries ~100 reads per 4bpp layer per line
// (map + tile halves + palette banks), so one or two layers fit a line
// period; four simultaneously scrolling 8bpp layers exceed it on the
// single 16-bit SDRAM port, which shows as one stale line in the
// heaviest scenes until the M3 memory pass adds burst fetch. The OAM
// scan reads ATTR0/ATTR1 for all 128 sprites per line (ATTR2 and tile
// data only on y-hit), matching the hardware scan order.
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

	// VRAM fetch port (hold req until ready; byte address)
	output reg       v_req,
	output reg [19:0] v_addr,
	input            v_ready,
	input     [15:0] v_rdata,

	// OBJ tile base inside the engine's VRAM window
	input     [19:0] obj_base
);

localparam [1:0] KIND_BD  = 2'd0,  // backdrop (lowest)
                 KIND_BG  = 2'd1,
                 KIND_OBJ = 2'd2;

//------------------------------------------------------------------
// Registers (byte offsets follow the DS IO map)
//------------------------------------------------------------------
reg [15:0] dispcnt = 0;
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
		default: ;
		endcase
	end
	if (reset) dispcnt <= 16'd0;
end

wire [1:0] mode   = dispcnt[2:0];
wire       obj_en = dispcnt[12];

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
// Line buffers: two banks of 128 pair entries. Each entry holds two
// composite pixels of 21 bits {kind[1:0], prio[1:0], opaque, rgb[15:0]}.
// The front bank answers the composer combinationally; the fetch FSM
// writes the back bank; the swap is a one-bit flip, taken only while
// the fetch FSM is idle (back_line valid implies idle).
//------------------------------------------------------------------
reg [41:0] buf_a [0:127];
reg [41:0] buf_b [0:127];
reg        front_is_a = 1'b1;

wire [41:0] fe_pair = front_is_a ? buf_a[px[7:1]] : buf_b[px[7:1]];
wire [20:0] fe      = px[0] ? fe_pair[41:21] : fe_pair[20:0];

assign rgb555 = !on ? 16'h0000 : (fe[16] ? fe[15:0] : 16'h0000);

// DS priority resolution: everything beats the backdrop; between a BG
// and an OBJ the lower priority value wins and OBJ wins ties; between
// BGs the lower number wins ties (layers walk 3->0, later write wins);
// between sprites the lower OAM index wins (walk 0->127, later write
// wins only on strictly lower priority).
function automatic px_win;
	input [1:0] nk; input [1:0] ck;
	input [1:0] np; input [1:0] cp;
	begin
		if (ck == KIND_BD)      px_win = 1'b1;
		else if (nk != ck)      px_win = (np <= cp);
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
	S_PB_REQ    = 5'd7,   // 4bpp palette-bank load (pbi 0..15)
	S_PB_WAIT   = 5'd8,
	S_TILE_REQ  = 5'd9,
	S_TILE_WAIT = 5'd10,
	S_PXC       = 5'd11,  // composite one BG pixel
	S_PAL_REQ   = 5'd12,  // 8bpp BG per-pixel palette read
	S_PAL_WAIT  = 5'd13,
	S_OAM_REQ   = 5'd14,  // sprite attribute read (ostep 0..2)
	S_OAM_WAIT  = 5'd15,
	S_SHW_REQ   = 5'd16,  // sprite tile-row halfword fetch
	S_SHW_WAIT  = 5'd17,
	S_SPIXC     = 5'd18,  // composite one OBJ pixel
	S_SPAL_REQ  = 5'd19,  // 8bpp OBJ per-pixel palette read
	S_SPAL_WAIT = 5'd20,
	S_SPB_REQ   = 5'd21,  // OBJ palette-bank load (spbi 0..15)
	S_SPB_WAIT  = 5'd22,
	S_DONE      = 5'd23;

reg [4:0]  fstate = S_IDLE;
reg [7:0]  tgt = 8'hFF;        // line being fetched into the back bank
reg [7:0]  back_line = 8'hFF;  // line currently valid in the back bank

// line-request mailbox (display side -> fetch side)
reg        fetch_req = 0;
reg [7:0]  fetch_line = 0;
reg [11:0] blank_cnt = 0;      // saturates at 4096 (deep blanking)

// BG walk
reg        phase_bg = 1'b1;    // 1 = BG phase, 0 = OBJ phase
reg [1:0]  lk = 2'd3;          // current BG layer, walks 3->0
reg [5:0]  col = 6'd0;         // screen tile column 0..32
reg [1:0]  hw_i = 2'd0;        // halfword within the tile row
reg [1:0]  pxi = 2'd0;         // pixel within the halfword
reg [3:0]  pbi = 4'd0;         // palette-bank fill index
reg [6:0]  fill_i = 7'd0;      // backdrop-fill pair index
reg [15:0] map_e = 16'd0;      // latched map entry
reg [15:0] hw_data = 16'd0;    // latched tile-row halfword
reg [15:0] pcache [0:15];      // shared 16-entry palette cache
reg [3:0]  pcache_bank = 4'd0;
reg        pcache_obj = 1'b0;  // cache holds OBJ palettes when set
reg        pcache_ok = 1'b0;
reg [15:0] pal_hold = 16'd0;   // last direct palette read (BG side)
reg        pal_ready = 1'b0;

// shared 2-cycle port-read countdown; pal_ret/pal_obj select the
// destination of S_PAL_WAIT
reg [1:0]  port_wc = 2'd0;
reg [3:0]  pal_ret = S_IDLE;
reg        pal_obj = 1'b0;

// OBJ walk
reg [6:0]  os_idx = 7'd0;
reg [1:0]  ostep = 2'd0;       // 0 ATTR0, 1 ATTR1, 2 ATTR2
reg [15:0] o_a0 = 16'd0, o_a1 = 16'd0;
reg [8:0]  sx = 9'd0;          // sprite x (raw 9-bit)
reg [6:0]  s_w = 7'd0, s_h = 7'd0;
reg [9:0]  s_tile = 10'd0;
reg [3:0]  s_bank = 4'd0;
reg [1:0]  s_prio = 2'd0;
reg        s_hflip = 1'b0, s_vflip = 1'b0, s_bpp8 = 1'b0;
reg [5:0]  shw = 6'd0;         // halfword within the sprite row
reg [1:0]  spx = 2'd0;         // pixel within the sprite halfword
reg [15:0] sdata = 16'd0;      // latched sprite halfword
reg [3:0]  spbi = 4'd0;        // OBJ palette-bank fill index
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
wire        bg_wide = (bgcnt[lk][15:14] == 2'd1) || (bgcnt[lk][15:14] == 2'd3);
wire        bg_tall = (bgcnt[lk][15:14] == 2'd2) || (bgcnt[lk][15:14] == 2'd3);
wire [6:0]  mcol_f  = {1'b0, bghofs[lk][8:3]} + {1'b0, col};
wire [6:0]  mrow_f  = {1'b0, bgvofs[lk][8:3]} + {2'd0, tgt[7:3]};
wire [5:0]  mcol    = mcol_f[5:0] & (bg_wide ? 6'd63 : 6'd31);
wire [5:0]  mrow    = mrow_f[5:0] & (bg_tall ? 6'd63 : 6'd31);
// GBATEK block layout: 64x32 -> right at +2K; 32x64 -> bottom at +2K;
// 64x64 -> TR +2K, BL +4K, BR +6K
wire [19:0] map_blk = (bg_wide && bg_tall) ? {10'd0, mrow_f[6], mcol_f[6], 11'd0}
                   : bg_wide               ? {11'd0, mcol_f[6], 11'd0}
                   : bg_tall               ? {11'd0, mrow_f[6], 11'd0}
                                            : 20'd0;
wire [19:0] map_addr = {bgcnt[lk][15:8], 11'd0} + map_blk
                     + {13'd0, mrow[4:0], 6'd0} + {16'd0, mcol[4:0], 1'd0};

wire        bg_bpp8 = bgcnt[lk][7];
wire [1:0]  bg_prio = bgcnt[lk][1:0];
wire [2:0]  y_in    = tgt[2:0];
wire [2:0]  vrow    = map_e[11] ? (3'd7 - y_in) : y_in;      // vflip
wire [19:0] tile_addr = {bgcnt[lk][3:2], 14'd0}              // char base
                      + (bg_bpp8 ? {9'd0, map_e[9:0], 6'd0}  // *64
                                 : {10'd0, map_e[9:0], 5'd0})// *32
                      + (bg_bpp8 ? {17'd0, vrow, 3'd0}       // *8
                                 : {18'd0, vrow, 2'd0})      // *4
                      + {18'd0, hw_i, 1'd0};

wire [2:0]  bg_pph  = bg_bpp8 ? 3'd2 : 3'd4;   // pixels per halfword
wire [3:0]  bg_tlp  = (bg_pph == 3'd4 ? {hw_i, 2'd0} : {1'b0, hw_i, 1'b0})
                    + {2'd0, pxi};             // hw_i*pph + pxi
wire [2:0]  bg_xoff = map_e[10] ? (3'd7 - bg_tlp[2:0]) : bg_tlp[2:0];
wire signed [10:0] bg_xs = $signed({2'd0, col, 3'd0})
                         - $signed({8'd0, bghofs[lk][2:0]})
                         + $signed({7'd0, bg_xoff});
wire        bg_xs_ok = (bg_xs >= 0) && (bg_xs < 256);
wire [7:0]  bg_idx = bg_bpp8 ? (pxi[0] ? hw_data[15:8] : hw_data[7:0])
                             : (pxi == 2'd0) ? hw_data[3:0]
                             : (pxi == 2'd1) ? hw_data[7:4]
                             : (pxi == 2'd2) ? hw_data[11:8]
                                             : hw_data[15:12];

// last column is only needed when the horizontal scroll has a
// sub-tile offset (otherwise column 31 already ends at x=255)
wire        col_last = (col == 6'd32) ||
                       ((col == 6'd31) && (bghofs[lk][2:0] == 3'd0));

//------------------------------------------------------------------
// Sprite geometry
//------------------------------------------------------------------
wire [7:0]  sp_dy   = tgt - o_a0[7:0];          // wraps mod 256
// size lookups (function results need an intermediate for bit-selects)
wire [13:0] sp_wh1  = spr_wh(o_a0[9:8], oam_data[15:14]); // ATTR1 time
wire [13:0] sp_wh2  = spr_wh(o_a0[9:8], o_a1[15:14]);     // ATTR2 time
// hit test at ATTR1 latch time: height comes from ATTR1 size bits
wire        sp_hit1 = (o_a0[15:14] == 2'd0)
                    && ({3'd0, sp_dy} < {4'd0, sp_wh1[6:0]});

wire [2:0]  s_pph   = s_bpp8 ? 3'd2 : 3'd4;
wire [5:0]  s_nhw   = s_bpp8 ? s_w[6:1] : s_w[6:2];      // w/2 or w/4
wire [7:0]  s_row   = s_vflip ? ({1'b0, sp_wh_r[6:0]} - 8'd1 - {2'd0, sp_dy})
                              : {2'd0, sp_dy};
wire [2:0]  s_trow  = s_row[5:3];
wire [2:0]  s_vrow  = s_row[2:0];
wire [7:0]  s_bpr   = s_bpp8 ? {1'b0, s_w[6:3], 3'd0}    // (w/8)*8
                             : {2'd0, s_w[6:3], 2'd0};   // (w/8)*4
wire [19:0] shw_addr = obj_base + {10'd0, s_tile, 5'd0}    // *32
                     + {12'd0, s_trow} * {12'd0, s_bpr}
                     + (s_bpp8 ? {17'd0, s_vrow, 3'd0}
                               : {18'd0, s_vrow, 2'd0})
                     + {15'd0, shw, 1'd0};
// screen x of the current sprite pixel (x >= 256 wraps offscreen)
wire signed [10:0] s_x0 = sx[8] ? ($signed({2'd0, sx}) - 11'sd512)
                                 : $signed({2'd0, sx});
wire [6:0]  s_tlp   = (s_pph == 3'd4 ? {shw, 2'd0} : {1'b0, shw, 1'b0})
                    + {5'd0, spx};             // shw*pph + spx
wire [6:0]  s_poff  = s_hflip ? ({1'b0, sp_wh_r[6:0]} - 7'd1 - s_tlp)
                              : s_tlp;
wire signed [10:0] s_xs = s_x0 + $signed({4'd0, s_poff});
wire        s_xs_ok = (s_xs >= 0) && (s_xs < 256);
wire [7:0]  s_idx = s_bpp8 ? (spx[0] ? sdata[15:8] : sdata[7:0])
                            : (spx == 2'd0) ? sdata[3:0]
                            : (spx == 2'd1) ? sdata[7:4]
                            : (spx == 2'd2) ? sdata[11:8]
                                            : sdata[15:12];

wire [9:0]  oam_rd_addr = {3'd0, os_idx, 1'b0} + {6'd0, os_idx} + {8'd0, ostep};

//------------------------------------------------------------------
// Composite write: read-modify-write one pixel of the back bank
//------------------------------------------------------------------
task automatic write_px;
	input signed [10:0] xs;
	input [1:0]  nk;
	input [1:0]  np;
	input [15:0] colr;
	reg [41:0] e;
	reg [20:0] cur;
	begin
		if (xs >= 0 && xs < 256) begin
			e = front_is_a ? buf_b[xs[8:1]] : buf_a[xs[8:1]];
			cur = xs[0] ? e[41:21] : e[20:0];
			if (px_win(nk, cur[20:19], np, cur[18:17])) begin
				if (xs[0]) e[41:21] = {nk, np, 1'b1, colr};
				else       e[20:0]  = {nk, np, 1'b1, colr};
				if (front_is_a) buf_b[xs[8:1]] <= e;
				else            buf_a[xs[8:1]] <= e;
			end
		end
	end
endtask

//------------------------------------------------------------------
// Display side state
//------------------------------------------------------------------
reg       prev_on = 1'b0;
reg [7:0] prev_py = 8'd0;

//------------------------------------------------------------------
// Main process. Order matters: the fetch FSM runs first and consumes
// fetch_req; the display side assigns afterwards, so a request raised
// in the same cycle a consume happens is never lost.
//------------------------------------------------------------------
always @(posedge clk) begin
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
		// fill the back bank with the backdrop, one pair entry per
		// cycle (BOTH pixels of the pair); pal_hold holds colour 0
		if (front_is_a) begin
			buf_b[fill_i][20:0]  <= {KIND_BD, 2'd3, 1'b1, pal_hold};
			buf_b[fill_i][41:21] <= {KIND_BD, 2'd3, 1'b1, pal_hold};
		end else begin
			buf_a[fill_i][20:0]  <= {KIND_BD, 2'd3, 1'b1, pal_hold};
			buf_a[fill_i][41:21] <= {KIND_BD, 2'd3, 1'b1, pal_hold};
		end
		if (fill_i == 7'd127) begin
			fill_i    <= 7'd0;
			lk        <= 2'd3;
			phase_bg  <= 1'b1;
			fstate    <= S_LAYER;
		end else begin
			fill_i <= fill_i + 7'd1;
		end
	end

	S_LAYER: begin
		// pick the next enabled BG layer walking 3->0; when none
		// remains continue with the OBJ phase
		if (phase_bg) begin
			if (bg_enabled(lk)) begin
				col     <= 6'd0;
				hw_i    <= 2'd0;
				pxi     <= 2'd0;
				fstate  <= S_MAP_REQ;
			end else if (lk == 2'd0) begin
				phase_bg <= 1'b0;
				if (obj_en) begin
					os_idx <= 7'd0;
					ostep  <= 2'd0;
					fstate <= S_OAM_REQ;
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
		v_req  <= 1'b1;
		v_addr <= map_addr;
		fstate <= S_MAP_WAIT;
	end

	S_MAP_WAIT: begin
		if (v_ready) begin
			v_req  <= 1'b0;
			map_e  <= v_rdata;
			hw_i   <= 2'd0;
			pxi    <= 2'd0;
			// 4bpp: make sure the palette bank this entry selects
			// is resident in the cache
			if (!bg_bpp8 && !(pcache_ok && !pcache_obj
			                 && pcache_bank == v_rdata[15:12])) begin
				pcache_bank <= v_rdata[15:12];
				pcache_obj  <= 1'b0;
				pcache_ok   <= 1'b0;
				pbi         <= 4'd0;
				pal_addr    <= {6'd0, v_rdata[15:12], 4'd0};
				port_wc     <= 2'd2;
				fstate      <= S_PB_WAIT;
			end else begin
				fstate <= S_TILE_REQ;
			end
		end
	end

	S_PB_REQ: begin
		pal_addr <= {6'd0, pcache_bank, pbi};
		port_wc  <= 2'd2;
		fstate   <= S_PB_WAIT;
	end

	S_PB_WAIT: begin
		if (port_wc != 2'd1) port_wc <= port_wc - 2'd1;
		else begin
			pcache[pbi] <= pal_data;
			if (pbi == 4'd15) begin
				pcache_ok <= 1'b1;
				hw_i      <= 2'd0;
				pxi       <= 2'd0;
				fstate    <= S_TILE_REQ;
			end else begin
				pbi      <= pbi + 4'd1;
				pal_addr <= {6'd0, pcache_bank, pbi + 4'd1};
				port_wc  <= 2'd2;
			end
		end
	end

	S_TILE_REQ: begin
		v_req  <= 1'b1;
		v_addr <= tile_addr;
		fstate <= S_TILE_WAIT;
	end

	S_TILE_WAIT: begin
		if (v_ready) begin
			v_req    <= 1'b0;
			hw_data  <= v_rdata;
			pxi      <= 2'd0;
			pal_ready<= 1'b0;
			fstate   <= S_PXC;
		end
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
								os_idx <= 7'd0;
								ostep  <= 2'd0;
								fstate <= S_OAM_REQ;
							end else fstate <= S_DONE;
						end else begin
							lk <= lk - 2'd1;
							fstate <= S_LAYER;
						end
					end else begin
						col    <= col + 6'd1;
						fstate <= S_MAP_REQ;
					end
				end else begin
					hw_i   <= hw_i + 2'd1;
					fstate <= S_TILE_REQ;
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

	S_OAM_REQ: begin
		oam_addr <= oam_rd_addr;
		port_wc  <= 2'd2;
		fstate   <= S_OAM_WAIT;
	end

	S_OAM_WAIT: begin
		if (port_wc != 2'd1) port_wc <= port_wc - 2'd1;
		else begin
			case (ostep)
			2'd0: begin
				o_a0   <= oam_data;
				ostep  <= 2'd1;
				fstate <= S_OAM_REQ;             // fetch ATTR1
			end
			2'd1: begin
				// y-hit test needs the size bits from ATTR1
				o_a1 <= oam_data;
				if (sp_hit1) begin
					ostep  <= 2'd2;
					fstate <= S_OAM_REQ;         // fetch ATTR2
				end else begin
					ostep <= 2'd0;
					if (os_idx == 7'd127) fstate <= S_DONE;
					else begin
						os_idx <= os_idx + 7'd1;
						fstate <= S_OAM_REQ;
					end
				end
			end
			default: begin
				// ATTR2 latched: set up the sprite and start the
				// row fetch (loading the OBJ palette bank first
				// for 4bpp)
				sx      <= o_a1[8:0];
				s_hflip <= o_a1[12];
				s_vflip <= o_a1[13];
				s_bpp8  <= o_a0[13];
				s_tile  <= oam_data[9:0];
				s_prio  <= oam_data[10:9];
				s_bank  <= oam_data[15:12];
				sp_wh_r <= sp_wh2;
				s_w     <= sp_wh2[13:7];
				shw     <= 6'd0;
				spx     <= 2'd0;
				ostep   <= 2'd0;
				if (o_a0[13]) begin               // 8bpp: per-pixel reads
					fstate <= S_SHW_REQ;
				end else if (pcache_ok && pcache_obj
				             && pcache_bank == oam_data[15:12]) begin
					fstate <= S_SHW_REQ;
				end else begin
					pcache_bank <= oam_data[15:12];
					pcache_obj  <= 1'b1;
					pcache_ok   <= 1'b0;
					spbi        <= 4'd0;
					pal_addr    <= 10'd512 + {6'd0, oam_data[15:12], 4'd0};
					port_wc     <= 2'd2;
					fstate      <= S_SPB_WAIT;
				end
			end
			endcase
		end
	end

	S_SHW_REQ: begin
		v_req  <= 1'b1;
		v_addr <= shw_addr;
		fstate <= S_SHW_WAIT;
	end

	S_SHW_WAIT: begin
		if (v_ready) begin
			v_req      <= 1'b0;
			sdata      <= v_rdata;
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
						if (os_idx == 7'd127) fstate <= S_DONE;
						else begin
							os_idx <= os_idx + 7'd1;
							ostep  <= 2'd0;
							fstate <= S_OAM_REQ;
						end
					end else begin
						shw    <= shw + 6'd1;
						fstate <= S_SHW_REQ;
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
					if (os_idx == 7'd127) fstate <= S_DONE;
					else begin
						os_idx <= os_idx + 7'd1;
						ostep  <= 2'd0;
						fstate <= S_OAM_REQ;
					end
				end else begin
					shw    <= shw + 6'd1;
					fstate <= S_SHW_REQ;
				end
			end else begin
				spx <= spx + 2'd1;
			end
		end
	end

	S_SPB_REQ: begin
		pal_addr <= 10'd512 + {6'd0, pcache_bank, pbi};
		port_wc  <= 2'd2;
		fstate   <= S_SPB_WAIT;
	end

	S_SPB_WAIT: begin
		if (port_wc != 2'd1) port_wc <= port_wc - 2'd1;
		else begin
			pcache[spbi] <= pal_data;
			if (spbi == 4'd15) begin
				pcache_ok <= 1'b1;
				shw       <= 6'd0;
				spx       <= 2'd0;
				fstate    <= S_SHW_REQ;
			end else begin
				spbi     <= spbi + 4'd1;
				pal_addr <= 10'd512 + {6'd0, pcache_bank, spbi + 4'd1};
				port_wc  <= 2'd2;
			end
		end
	end

	S_DONE: begin
		back_line <= tgt;
		fstate    <= S_IDLE;
	end

	default: fstate <= S_IDLE;
	endcase

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

	if (reset) begin
		fstate     <= S_IDLE;
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
		pbi        <= 4'd0;
		fill_i     <= 7'd0;
		spbi       <= 4'd0;
		os_idx     <= 7'd0;
		ostep      <= 2'd0;
		shw        <= 6'd0;
		spx        <= 2'd0;
		pcache_ok  <= 1'b0;
		pcache_obj <= 1'b0;
		pal_ready  <= 1'b0;
		spal_ready <= 1'b0;
		pal_ret    <= S_IDLE;
		pal_obj    <= 1'b0;
	end
end

wire _unused = &{1'b0, pixel_ce, s_h, mcol, mrow, sp_wh1[13:7]};

endmodule
