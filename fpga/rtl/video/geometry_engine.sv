//============================================================================
// NDS MiSTer Test — 3D geometry engine
//
// Milestone M3 (first slice). Consumes the GXFIFO command stream the ARM9
// writes at 0x04000400 and turns it into screen-space vertices for the
// rasterizer, at up to 6144 vertices per frame.
//
// What is real here:
//   * GXFIFO command decode with the full GBATEK parameter-count table, so
//     an opcode the engine does not execute yet is consumed by exactly its
//     own length and never desynchronises the commands behind it.
//   * 4x4 4.12 matrix state split into projection and modelview matrices,
//     MTX_MODE / MTX_PUSH / MTX_POP / MTX_IDENTITY / MTX_LOAD_4x4 /
//     MTX_SCALE / MTX_TRANS, and a composite (modelview x projection)
//     matrix evaluated per vertex.
//   * Vertex submission (VTX_16, VTX_XY), COLOR, VIEWPORT, BEGIN_VTXS /
//     END_VTXS, and GXSTAT (busy, matrix stack level, FIFO level/empty/full).
//
// What is not here yet (later M3 slices):
//   * MTX_STORE / MTX_RESTORE, MTX_LOAD_4x3, MTX_MULT_4x4 / _4x3 / _3x3,
//     NORMAL / TEXCOORD, VTX_10 / VTX_XZ / VTX_YZ / VTX_DIFF, lighting,
//     texture parameters, POLYGON_ATTR and the box/pos/vec tests. They are
//     decoded and skipped — never mis-parsed — until their execution lands.
//   * Perspective divide and near/far clipping: vertices are mapped through
//     the viewport orthographically (w is carried, not divided). That is
//     exact for 2D-style submissions and the first 3D bring-up tests; the
//     divide and clip arrive with the rasterizer.
//   * The matrix stack holds 8 of the hardware's 31 levels. The composite
//     matrix and the vertex transform share one time-multiplexed 64x32
//     multiplier (AREA.md item 1), so a vertex takes ten clocks and a
//     composite rebuild sixty-four, instead of one multiply per clock.
//
// Register map (byte offsets inside the GX block, i.e. io_addr[9:0]):
//   0x000  GXFIFO     W   command / parameter words
//   0x200  GXSTAT     R   {…, full, empty, fifo count, …, stack level, busy}
//   0x204  RAM_COUNT  R   0 — no polygon RAM allocated yet
//============================================================================
module geometry_engine (
	input            clk,
	input            reset,

	// matrix / command register access from main_bus
	input            reg_we,
	input      [9:0] reg_addr,
	input     [31:0] reg_data,
	output reg [31:0] reg_rdata,

	// vertex output towards the rasterizer — 32-bit 4.12 covers the full
	// ±2048 px range a DS viewport can address (16 bits would stop at 8 px)
	output reg        vtx_valid,
	output reg signed [31:0] vtx_x,   // 4.12 fixed
	output reg signed [31:0] vtx_y,
	output reg  [7:0] vtx_color,
	output reg  [1:0] vtx_poly   // polygon mode
);

//------------------------------------------------------------------
// Register map and GXFIFO opcodes (GBATEK)
//------------------------------------------------------------------
localparam [9:0] A_FIFO     = 10'h000,
                 A_GXSTAT   = 10'h200,
                 A_RAMCOUNT = 10'h204;

localparam [7:0] C_NOP        = 8'h00,
                 C_MTX_MODE   = 8'h10,
                 C_MTX_PUSH   = 8'h11,
                 C_MTX_POP    = 8'h12,
                 C_MTX_STORE  = 8'h13,
                 C_MTX_REST   = 8'h14,
                 C_MTX_IDENT  = 8'h15,
                 C_MTX_LOAD44 = 8'h16,
                 C_MTX_LOAD43 = 8'h17,
                 C_MTX_MULT44 = 8'h18,
                 C_MTX_MULT43 = 8'h19,
                 C_MTX_MULT33 = 8'h1A,
                 C_MTX_SCALE  = 8'h1B,
                 C_MTX_TRANS  = 8'h1C,
                 C_COLOR      = 8'h20,
                 C_NORMAL     = 8'h21,
                 C_TEXCOORD   = 8'h22,
                 C_VTX_16     = 8'h23,
                 C_VTX_10     = 8'h24,
                 C_VTX_XY     = 8'h25,
                 C_VTX_XZ     = 8'h26,
                 C_VTX_YZ     = 8'h27,
                 C_VTX_DIFF   = 8'h28,
                 C_POLY_ATTR  = 8'h29,
                 C_TEXIMG     = 8'h2A,
                 C_PLTT_BASE  = 8'h2B,
                 C_DIF_AMB    = 8'h30,
                 C_SPE_EMI    = 8'h31,
                 C_LIGHT_VEC  = 8'h32,
                 C_LIGHT_COL  = 8'h33,
                 C_SHININESS  = 8'h34,
                 C_BEGIN_VTXS = 8'h40,
                 C_END_VTXS   = 8'h41,
                 C_SWAPBUF    = 8'h50,
                 C_VIEWPORT   = 8'h60,
                 C_BOX_TEST   = 8'h70,
                 C_POS_TEST   = 8'h71,
                 C_VEC_TEST   = 8'h72;

localparam [1:0] F_IDLE = 2'd0, F_PARAM = 2'd1, F_EXEC = 2'd2, F_WAIT = 2'd3;

//------------------------------------------------------------------
// Command FSM state (declared before the FIFO, which reads `fsm`)
//------------------------------------------------------------------
reg  [1:0]  fsm = F_IDLE;
reg  [7:0]  cmd = C_NOP;
reg  [4:0]  need = 5'd0;
reg  [4:0]  got = 5'd0;
reg         started = 1'b0;   // F_WAIT has seen the matrix pipeline run
reg [31:0]  params [0:15];

//------------------------------------------------------------------
// GBATEK parameter counts — a command the engine does not execute yet
// is still consumed at its exact length.
//------------------------------------------------------------------
function automatic [4:0] cmd_params(input [7:0] c);
	case (c)
	C_MTX_MODE, C_MTX_POP, C_MTX_STORE, C_MTX_REST, C_COLOR, C_NORMAL,
	C_TEXCOORD, C_VTX_10, C_VTX_XY, C_VTX_XZ, C_VTX_YZ, C_VTX_DIFF,
	C_POLY_ATTR, C_TEXIMG, C_PLTT_BASE, C_DIF_AMB, C_SPE_EMI,
	C_LIGHT_VEC, C_LIGHT_COL, C_SHININESS, C_BEGIN_VTXS, C_SWAPBUF,
	C_VIEWPORT, C_VEC_TEST: return 5'd1;
	C_MTX_LOAD43, C_MTX_MULT43: return 5'd12;
	C_MTX_LOAD44, C_MTX_MULT44: return 5'd16;
	C_MTX_MULT33: return 5'd9;
	C_MTX_SCALE, C_MTX_TRANS, C_BOX_TEST: return 5'd3;
	C_POS_TEST: return 5'd2;
	C_VTX_16: return 5'd2;
	default: return 5'd0;   // NOP, MTX_PUSH, MTX_IDENTITY, END_VTXS, unknown
	endcase
endfunction

//------------------------------------------------------------------
// GXFIFO — 16 words deep, written by the CPU, drained by the FSM
//------------------------------------------------------------------
reg [31:0] fifo [0:15];
reg  [3:0] fifo_wr = 0;
reg  [3:0] fifo_rd = 0;
reg  [4:0] fifo_cnt = 0;

wire       fifo_empty = (fifo_cnt == 5'd0);
wire       fifo_full  = (fifo_cnt == 5'd16);
wire       fifo_push  = reg_we && (reg_addr == A_FIFO) && !fifo_full;
wire       fifo_pop   = !fifo_empty && ((fsm == F_IDLE) || (fsm == F_PARAM));

//------------------------------------------------------------------
// Matrix state — 4x4, 4.12 fixed point, row-vector convention:
// v' = v x M, translation in row 3 (words 12..14), as on the DS.
//------------------------------------------------------------------
reg signed [31:0] m_mv   [0:15];   // modelview
reg signed [31:0] m_proj [0:15];   // projection
reg signed [31:0] m_stack[0:127];  // 8 levels x 16 words
reg  [3:0] sp = 0;                 // matrix stack level
reg  [1:0] mtx_mode = 2'b00;       // 0 = projection, others = modelview

reg [15:0] cur_color = 16'h7FFF;
reg  [1:0] prim = 2'b00;
reg  [7:0] vp_x1 = 8'd0, vp_y1 = 8'd0, vp_x2 = 8'd255, vp_y2 = 8'd191;

//------------------------------------------------------------------
// Vertex under submission — driven by the current command's parameters,
// so no separate vertex register can hide the value being transformed.
//------------------------------------------------------------------
wire signed [31:0] pvx = (cmd == C_VTX_16 || cmd == C_VTX_XY) ? $signed(params[0][15:0])  : 32'sd0;
wire signed [31:0] pvy = (cmd == C_VTX_16 || cmd == C_VTX_XY) ? $signed(params[0][31:16]) : 32'sd0;
wire signed [31:0] pvz = (cmd == C_VTX_16) ? $signed(params[1][15:0])  : 32'sd0;
wire signed [31:0] pvw = (cmd == C_VTX_16) ? $signed(params[1][31:16]) : 32'sd4096;

//------------------------------------------------------------------
// Composite modelview x projection matrix (4.12)
//
//   comp[ci*4+cj] = ( sum over k of m_mv[ci*4+k] * m_proj[k*4+cj] ) >>> 12
//
// Evaluating that combinationally is 64 multiplies of 32x32 in one clock,
// which is more DSP blocks than the A6 has — Quartus spilled the surplus
// into LUT multipliers, and that spill is where 15,577 of this module's
// ALUTs went (AREA.md item 1). It now runs through one 32x32->64 multiplier,
// four products per entry; the vertex transform and the viewport mapping
// below share the same multiplier, one product per clock. Same operand
// widths, same 4.12 truncation: the results are bit-identical, because only
// the summation order changes and addition is exact modulo 2^64.
//------------------------------------------------------------------
reg signed [63:0] comp [0:15];

// viewport width/height — 8-bit endpoints, so nine bits carry the difference
wire signed [63:0] vp_w = $signed({56'd0, vp_x2}) - $signed({56'd0, vp_x1});
wire signed [63:0] vp_h = $signed({56'd0, vp_y2}) - $signed({56'd0, vp_y1});
wire signed [31:0] vp_w9 = {{23{vp_w[8]}}, vp_w[8:0]};
wire signed [31:0] vp_h9 = {{23{vp_h[8]}}, vp_h[8:0]};

//------------------------------------------------------------------
// The one multiplier, its operands muxed by whichever stage owns it.
//
// 64x32 rather than 32x32: the composite is a 64-bit 4.12 value and the
// vertex transform multiplies it by a 32-bit coordinate, while the viewport
// step multiplies the 64-bit projected coordinate by the 9-bit viewport
// width. Both operands keep every bit the original expression used, so each
// product is the same 64-bit value it was before the serialisation.
//------------------------------------------------------------------
reg  signed [63:0] mul_a = 64'sd0;
reg  signed [31:0] mul_b = 32'sd0;
wire signed [63:0] product = mul_a * mul_b;

// comp[4k + col] — the k-th term of the cx (col 0) or cy (col 1) dot product
function automatic [3:0] comp_term(input [2:0] n);
	comp_term = {n[1:0], 1'b0, n[2]};
endfunction

reg signed [31:0] mres [0:11];   // MTX_SCALE / MTX_TRANS results
reg signed [63:0] acc = 64'sd0;   // dot-product accumulator
reg signed [63:0] cxr = 64'sd0;   // projected vertex, 4.12
reg signed [63:0] cyr = 64'sd0;
reg signed [63:0] sxr = 64'sd0;   // mapped x, 4.12

// normalised coordinate + 1.0
wire signed [63:0] px412 = cxr + 64'sd4096;
wire signed [63:0] py412 = cyr + 64'sd4096;

// viewport pixel in 4.12 — orthographic until the rasterizer takes w
wire signed [63:0] sx_next = ($signed({56'd0, vp_x1}) <<< 12) + (product >>> 1);
wire signed [63:0] sy_next = ($signed({56'd0, vp_y1}) <<< 12) + (product >>> 1);

//------------------------------------------------------------------
// Matrix pipeline: rebuild comp, transform the pending vertex, map it
//------------------------------------------------------------------
localparam [2:0] C_IDLE  = 3'd0,  // ready for the next job
                 C_MAC   = 3'd1,  // one composite product per clock
                 C_VTX   = 3'd2,  // one vertex-transform product per clock
                 C_SX    = 3'd3,  // viewport x multiply
                 C_SY    = 3'd4,  // viewport y multiply
                 C_SCALE = 3'd5,  // MTX_SCALE: twelve products, row by row
                 C_TRANS = 3'd6;  // MTX_TRANS: three rows of three products

// the active matrix, for the stages that read it
function automatic [31:0] mtx_get(input [4:0] i);
	mtx_get = (mtx_mode == 2'b00) ? m_proj[i] : m_mv[i];
endfunction

reg  [2:0] cst       = C_IDLE;
reg  [5:0] cn        = 6'd0;      // 0..63 over the composite's products
reg  [2:0] vn        = 3'd0;      // 0..7: the cx terms, then the cy terms
reg  [3:0] sn        = 4'd0;      // 0..11 (scale) or 0..8 (translate)
reg        need_comp = 1'b1;      // comp[] no longer matches the matrices

// only rows 0..2 of the matrix are scaled or translated, so only params[0..2]
// are ever read here — a named select keeps the array index a constant
function automatic [31:0] param3(input [1:0] i);
	case (i)
	2'd0:    param3 = params[0];
	2'd1:    param3 = params[1];
	default: param3 = params[2];
	endcase
endfunction

// the accumulate stage's sum, and the 4.12 results MTX_SCALE / MTX_TRANS
// store — the low 32 bits of the shifted sum, which is what the matrix words
// have always held (the operands are 4.12, so the high half was never used)
wire signed [63:0] mac_sum   = acc + product;
wire signed [31:0] scale_val = product[43:12];
wire signed [31:0] trans_val = mtx_get({2'd3, sn[3:2]}) + mac_sum[43:12];

// A vertex or matrix command starts the pipeline in the cycle it executes.
// The command engine never reaches F_EXEC with the pipeline busy — F_WAIT
// holds it there until cst returns to C_IDLE — so these are the only places
// a job can start.
wire vtx_start   = (fsm == F_EXEC) && (cmd == C_VTX_16 || cmd == C_VTX_XY);
wire scale_start = (fsm == F_EXEC) && (cmd == C_MTX_SCALE);
wire trans_start = (fsm == F_EXEC) && (cmd == C_MTX_TRANS);

// any command that rewrites the active matrix invalidates comp[]
wire mtx_change = (fsm == F_EXEC) &&
                  (cmd == C_MTX_POP   || cmd == C_MTX_IDENT ||
                   cmd == C_MTX_LOAD44 || cmd == C_MTX_SCALE ||
                   cmd == C_MTX_TRANS);

always @(*) begin
	mul_a = 64'sd0;
	mul_b = 32'sd0;
	case (cst)
	C_MAC: begin
		// cn[5:4] = row, cn[3:2] = column, cn[1:0] = term of the dot product
		mul_a = m_mv[{cn[5:4], cn[1:0]}];
		mul_b = m_proj[{cn[1:0], cn[3:2]}];
	end
	C_VTX: begin
		// comp[k] (64-bit) times the submitted coordinate (32-bit)
		mul_a = comp[comp_term(vn)];
		case (vn[1:0])
		2'd0:    mul_b = pvx;
		2'd1:    mul_b = pvy;
		2'd2:    mul_b = pvz;
		default: mul_b = pvw;
		endcase
	end
	C_SX: begin
		mul_a = px412;
		mul_b = vp_w9;
	end
	C_SCALE: begin
		// sn[3:2] = row (0..2), sn[1:0] = column: row *= s_row
		mul_a = mtx_get(sn);
		mul_b = param3(sn[3:2]);
	end
	C_TRANS: begin
		// sn[3:2] = column (0..2), sn[1:0] = term: column x the translation
		mul_a = mtx_get({sn[1:0], sn[3:2]});
		mul_b = param3(sn[1:0]);
	end
	default: begin   // C_SY; the idle operands are don't-cares
		mul_a = py412;
		mul_b = vp_h9;
	end
	endcase
end

always @(posedge clk) begin
	if (reset) begin
		cst       <= C_IDLE;
		cn        <= 6'd0;
		vn        <= 3'd0;
		need_comp <= 1'b1;
		acc       <= 64'sd0;
		cxr       <= 64'sd0;
		cyr       <= 64'sd0;
		sxr       <= 64'sd0;
		vtx_valid <= 1'b0;
		vtx_x     <= 32'd0;
		vtx_y     <= 32'd0;
		vtx_color <= 8'd0;
		vtx_poly  <= 2'b00;
	end else begin
		vtx_valid <= 1'b0;
		if (mtx_change) need_comp <= 1'b1;

		case (cst)
		C_IDLE: begin
			if (vtx_start) begin
				acc <= 64'sd0;
				cn  <= 6'd0;
				vn  <= 3'd0;
				cst <= need_comp ? C_MAC : C_VTX;
			end else if (scale_start || trans_start) begin
				acc <= 64'sd0;
				sn  <= 4'd0;
				cst <= scale_start ? C_SCALE : C_TRANS;
			end
		end

		C_MAC: begin
			if (cn[1:0] == 2'd3) begin
				// last product of this entry: scale to 4.12 and store it
				comp[{cn[5:4], cn[3:2]}] <= (acc + product) >>> 12;
				acc <= 64'sd0;
			end else begin
				acc <= acc + product;
			end
			if (cn == 6'd63) begin
				cn        <= 6'd0;
				need_comp <= 1'b0;
				cst       <= C_VTX;
			end else begin
				cn <= cn + 6'd1;
			end
		end

		C_VTX: begin
			if (vn[1:0] == 2'd3) begin
				if (vn[2]) cyr <= (acc + product) >>> 12;
				else       cxr <= (acc + product) >>> 12;
				acc <= 64'sd0;
			end else begin
				acc <= acc + product;
			end
			if (vn == 3'd7) begin
				vn  <= 3'd0;
				cst <= C_SX;
			end else begin
				vn <= vn + 3'd1;
			end
		end

		C_SX: begin
			sxr <= sx_next;
			cst <= C_SY;
		end

		C_SY: begin
			vtx_valid <= 1'b1;
			vtx_x     <= sxr[31:0];
			vtx_y     <= sy_next[31:0];
			vtx_color <= cur_color[7:0];
			vtx_poly  <= prim;
			cst       <= C_IDLE;
		end

		C_SCALE: begin
			// one product per clock; the command engine copies mres[] into the
			// matrix once the whole entry is here (F_WAIT)
			mres[sn] <= scale_val;
			if (sn == 4'd11) begin
				sn  <= 4'd0;
				cst <= C_IDLE;
			end else begin
				sn <= sn + 4'd1;
			end
		end

		C_TRANS: begin
			// three terms per column, then add the existing translation
			if (sn[1:0] == 2'd2) begin
				mres[sn[3:2]] <= trans_val;
				acc <= 64'sd0;
			end else begin
				acc <= acc + product;
			end
			if (sn == 4'd8) begin
				sn  <= 4'd0;
				cst <= C_IDLE;
			end else begin
				sn <= sn + 4'd1;
			end
		end
		endcase
	end
end

//------------------------------------------------------------------
// Status word
//------------------------------------------------------------------
wire gx_busy = (fsm != F_IDLE) || !fifo_empty || (cst != C_IDLE);

always @(*) begin
	case (reg_addr)
	// 31..26 reserved · 25 FIFO full · 24 FIFO empty · 23..21 reserved
	// 20..16 FIFO count · 15..12 reserved · 11..8 stack level · 0 busy
	A_GXSTAT:   reg_rdata = {6'd0, fifo_full, fifo_empty, 3'd0,
	                         fifo_cnt, 4'd0, sp, 7'd0, gx_busy};
	A_RAMCOUNT: reg_rdata = 32'd0;
	default:    reg_rdata = 32'd0;
	endcase
end

//------------------------------------------------------------------
// FIFO + command engine
//------------------------------------------------------------------
integer mi;

always @(posedge clk) begin
	if (reset) begin
		fsm       <= F_IDLE;
		cmd       <= C_NOP;
		need      <= 5'd0;
		got       <= 5'd0;
		started   <= 1'b0;
		fifo_wr   <= 4'd0;
		fifo_rd   <= 4'd0;
		fifo_cnt  <= 5'd0;
		sp        <= 4'd0;
		mtx_mode  <= 2'b00;
		cur_color <= 16'h7FFF;
		prim      <= 2'b00;
		vp_x1     <= 8'd0;
		vp_y1     <= 8'd0;
		vp_x2     <= 8'd255;
		vp_y2     <= 8'd191;
		for (mi = 0; mi < 16; mi = mi + 1) begin
			m_mv[mi]    <= (mi % 5 == 0) ? 32'sd4096 : 32'sd0;
			m_proj[mi]  <= (mi % 5 == 0) ? 32'sd4096 : 32'sd0;
			m_stack[mi] <= (mi % 5 == 0) ? 32'sd4096 : 32'sd0;
		end
	end else begin
		if (fifo_push) begin
			fifo[fifo_wr] <= reg_data;
			fifo_wr       <= fifo_wr + 4'd1;
		end

		case (fsm)
		F_IDLE: begin
			if (!fifo_empty) begin
				cmd     <= fifo[fifo_rd][7:0];   // the opcode is the low byte
				fifo_rd <= fifo_rd + 4'd1;
				need    <= cmd_params(fifo[fifo_rd]);
				got     <= 5'd0;
				fsm     <= (cmd_params(fifo[fifo_rd]) == 5'd0) ? F_EXEC : F_PARAM;
			end
		end

		F_PARAM: begin
			if (!fifo_empty) begin
				params[got] <= fifo[fifo_rd];
				fifo_rd    <= fifo_rd + 4'd1;
				got        <= got + 5'd1;
				if (got + 5'd1 == need) fsm <= F_EXEC;
			end
		end

		F_EXEC: begin
			fsm <= F_IDLE;
			case (cmd)
			C_MTX_MODE: mtx_mode <= params[0][1:0];

			C_MTX_PUSH: begin
				if (sp < 4'd8) begin
					for (mi = 0; mi < 16; mi = mi + 1)
						m_stack[sp*16 + mi] <=
							(mtx_mode == 2'b00) ? m_proj[mi] : m_mv[mi];
					sp <= sp + 4'd1;
				end
			end

			C_MTX_POP: begin
				if (params[0][3:0] >= sp) sp <= 4'd0;
				else                      sp <= sp - params[0][3:0];
				if (params[0][3:0] < sp) begin
					for (mi = 0; mi < 16; mi = mi + 1) begin
						if (mtx_mode == 2'b00)
							m_proj[mi] <= m_stack[(sp - params[0][3:0])*16 + mi];
						else
							m_mv[mi]   <= m_stack[(sp - params[0][3:0])*16 + mi];
					end
				end
			end

			C_MTX_IDENT: begin
				for (mi = 0; mi < 16; mi = mi + 1) begin
					if (mtx_mode == 2'b00) m_proj[mi] <= (mi % 5 == 0) ? 32'sd4096 : 32'sd0;
					else                   m_mv[mi]   <= (mi % 5 == 0) ? 32'sd4096 : 32'sd0;
				end
			end

			C_MTX_LOAD44: begin
				for (mi = 0; mi < 16; mi = mi + 1) begin
					if (mtx_mode == 2'b00) m_proj[mi] <= $signed(params[mi]);
					else                   m_mv[mi]   <= $signed(params[mi]);
				end
			end

			C_MTX_SCALE: begin
				// row r *= s_r — scales the local axes only. The twelve products
				// go through the shared multiplier (one per clock); F_WAIT copies
				// the result into the matrix, so this block stays its only writer.
				fsm <= F_WAIT;
			end

			C_MTX_TRANS: begin
				// multiply by a translation matrix: row 3 gains t x upper 3x3,
				// again one product per clock in the pipeline
				fsm <= F_WAIT;
			end

			C_COLOR: cur_color <= params[0][15:0];

			C_VIEWPORT: begin
				vp_x1 <= params[0][7:0];
				vp_y1 <= params[0][15:8];
				vp_x2 <= params[0][23:16];
				vp_y2 <= params[0][31:24];
			end

			C_BEGIN_VTXS: prim <= params[0][1:0];

			C_VTX_16, C_VTX_XY: begin
				// the matrix pipeline transforms it and raises vtx_valid
				// when the last product lands (C_SY above)
				fsm <= F_WAIT;
			end

			default: ;   // decoded, length-correct, not executed yet
			endcase
		end

		F_WAIT: begin
			// hold the command engine — and `params` with it — until the
			// pipeline is done, so its operands cannot change under it.
			// `started` covers the first cycle, where the pipeline may not
			// have left C_IDLE yet.
			if (cst != C_IDLE) begin
				started <= 1'b1;
			end else if (started) begin
				// a serialised matrix command lands here: its products are in
				// mres[] and this is the one place the matrix registers are
				// written, so the result cannot race the pipeline
				if (cmd == C_MTX_SCALE) begin
					for (mi = 0; mi < 4; mi = mi + 1) begin
						if (mtx_mode == 2'b00) begin
							m_proj[mi]     <= mres[mi];
							m_proj[4 + mi] <= mres[4 + mi];
							m_proj[8 + mi] <= mres[8 + mi];
						end else begin
							m_mv[mi]       <= mres[mi];
							m_mv[4 + mi]   <= mres[4 + mi];
							m_mv[8 + mi]   <= mres[8 + mi];
						end
					end
				end else if (cmd == C_MTX_TRANS) begin
					for (mi = 0; mi < 3; mi = mi + 1) begin
						if (mtx_mode == 2'b00) m_proj[12 + mi] <= mres[mi];
						else                   m_mv[12 + mi]   <= mres[mi];
					end
				end
				started <= 1'b0;
				fsm     <= F_IDLE;
			end
		end

		default: fsm <= F_IDLE;
		endcase

		// FIFO occupancy: one push and one pop may land in the same cycle
		fifo_cnt <= fifo_cnt + (fifo_push ? 5'd1 : 5'd0) - (fifo_pop ? 5'd1 : 5'd0);
	end
end

wire _unused = &{1'b0, C_NOP, C_MTX_LOAD43, C_MTX_MULT44, C_MTX_MULT43,
                 C_MTX_MULT33, C_NORMAL, C_TEXCOORD, C_VTX_10, C_VTX_XZ,
                 C_VTX_YZ, C_END_VTXS, C_VTX_DIFF, C_POLY_ATTR, C_TEXIMG,
                 C_PLTT_BASE, C_DIF_AMB, C_SPE_EMI, C_LIGHT_VEC, C_LIGHT_COL,
                 C_SHININESS, C_SWAPBUF, C_BOX_TEST, C_POS_TEST, C_VEC_TEST,
                 C_MTX_STORE, C_MTX_REST, need};

endmodule
