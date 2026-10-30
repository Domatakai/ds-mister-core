//============================================================================
// NDS MiSTer Test — ARM9 maths coprocessor (DIV and SQRT)
//
// GBATEK, *DS Maths*:
//
//   4000280h  DIVCNT        0-1 mode (0 = 32/32, 1 = 64/32, 2 = 64/64)
//                          14  div-by-zero flag (full 64-bit denominator)
//                          15  busy
//   4000290h  DIV_NUMER     64-bit signed numerator  (16-bit slices)
//   4000298h  DIV_DENOM     64-bit signed denominator
//   40002A0h  DIV_RESULT    64-bit quotient (read only)
//   40002A8h  DIVREM_RESULT 64-bit remainder (read only)
//   40002B0h  SQRTCNT       0 mode (0 = 32-bit, 1 = 64-bit), 15 busy
//   40002B4h  SQRT_RESULT   32-bit result (read only)
//   40002B8h  SQRT_PARAM    64-bit unsigned parameter
//
// Writing to DIVCNT/NUMER/DENOM starts a division, writing SQRTCNT/SQRT_PARAM
// starts a square root, and the busy bit covers the run. The arithmetic itself
// is exact and signed: the quotient/remainder pair is what an integer division
// produces (remainder takes the numerator's sign), and the documented overflow
// cases are modelled — dividing by zero returns a remainder of the numerator
// and a result of +/-1 with the sign opposite the numerator, with DIVCNT.14
// set. The -MAX/-1 case returns the two's-complement wrap; GBATEK's extra
// "upper half inverted" quirk for 32-bit mode is not modelled.
//
// One restoring divider serves every mode: 32 steps in 32-bit mode, 64 in the
// 64-bit ones, one quotient bit per clock, with the remainder left in the same
// datapath. That is a single 65-bit subtractor instead of four combinational
// dividers, and the quotient/remainder pair is still exact. The busy window is
// 33/65 cycles against the hardware's 18/34 (the square root counts 16/32 steps
// against 13); a game polls BUSY and cannot tell the difference.
//============================================================================
module math_unit (
	input              clk,
	input              reset,

	input      [7:0]   addr,        // offset within 0x280..0x2BF
	input              we,
	input      [15:0]  wdata,
	output reg [15:0]  rdata,

	output             busy
);

	//------------------------------------------------------------------
	// registers
	//------------------------------------------------------------------
	reg [1:0]  div_mode = 2'd0;
	reg        div0     = 1'b0;      // DIVCNT.14
	reg        div_busy = 1'b0;      // DIVCNT.15
	reg [63:0] numer    = 64'd0;
	reg [63:0] denom    = 64'd0;
	reg [63:0] quot     = 64'd0;
	reg [63:0] remd     = 64'd0;

	reg        sqrt_mode = 1'b0;
	reg        sqrt_busy = 1'b0;
	reg [63:0] sqrt_param = 64'd0;
	reg [31:0] sqrt_res = 32'd0;

	wire div_start  = we && (addr == 8'h80 || addr == 8'h81 ||
	                         (addr >= 8'h90 && addr <= 8'h9F));
	wire sqrt_start = we && (addr == 8'hB0 || addr == 8'hB1 ||
	                         (addr >= 8'hB8 && addr <= 8'hBF));

	assign busy = div_busy | sqrt_busy;

	//------------------------------------------------------------------
	// division: one restoring divider, magnitudes then signs
	//------------------------------------------------------------------
	// 32-bit mode divides the low halves, the 64-bit modes divide the full
	// numerator; mode 1 is 64-bit numerator over a 32-bit denominator, and
	// GBATEK says that denominator's upper half is unused, so it is
	// sign-extended first.
	wire        wide    = (div_mode != 2'd0);
	wire signed [63:0] sn_full = numer;
	wire signed [63:0] sd_full = (div_mode == 2'd1)
	                             ? {{32{denom[31]}}, denom[31:0]} : denom;
	wire signed [31:0] sn_nar  = numer[31:0];
	wire signed [31:0] sd_nar  = denom[31:0];

	// magnitudes, so one unsigned datapath serves every mode
	wire [63:0] n_mag = wide ? (sn_full[63] ? (~sn_full + 64'd1) : sn_full)
	                         : {32'd0, (sn_nar[31] ? (~sn_nar + 32'd1) : sn_nar)};
	wire [63:0] d_mag = wide ? (sd_full[63] ? (~sd_full + 64'd1) : sd_full)
	                         : {32'd0, (sd_nar[31] ? (~sd_nar + 32'd1) : sd_nar)};

	reg  [63:0] dv_num  = 64'd0;   // dividend, shifted out one bit per step
	reg  [63:0] dv_den  = 64'd0;   // divisor magnitude
	reg  [63:0] dv_q    = 64'd0;   // quotient, built one bit per step
	reg  [64:0] dv_r    = 65'd0;   // remainder
	reg  [6:0]  dv_step = 7'd0;    // steps still to run
	reg         dv_wide = 1'b0;
	reg         dv_qneg = 1'b0, dv_rneg = 1'b0;
	reg         dv_zdiv = 1'b0;    // the effective divisor is zero

	wire [64:0] dv_sh  = {dv_r[63:0], dv_num[63]};
	wire        dv_ge  = (dv_sh >= {1'b0, dv_den});
	wire [63:0] dv_q_n = {dv_q[62:0], dv_ge};
	wire [64:0] dv_r_n = dv_ge ? (dv_sh - {1'b0, dv_den}) : dv_sh;
	wire [63:0] q_sgn  = dv_qneg ? (~dv_q_n + 64'd1) : dv_q_n;
	wire [63:0] r_sgn  = dv_rneg ? (~dv_r_n[63:0] + 64'd1) : dv_r_n[63:0];
	// 32-bit mode sign-extends both results; 64-bit modes pass through
	wire [63:0] q_fin  = dv_wide ? q_sgn : {{32{q_sgn[31]}}, q_sgn[31:0]};
	wire [63:0] r_fin  = dv_wide ? r_sgn : {{32{r_sgn[31]}}, r_sgn[31:0]};

	// dividing by zero: remainder = numerator, result = +/-1 with the sign
	// opposite the numerator (GBATEK)
	wire [63:0] q_zero = ((div_mode == 2'd0) ? numer[31] : numer[63])
	                     ? 64'd1 : 64'hFFFF_FFFF_FFFF_FFFF;

	//------------------------------------------------------------------
	// square root: restoring, two bits per step, exact for both modes
	//------------------------------------------------------------------
	reg  [31:0] sq_root = 32'd0;
	reg  [64:0] sq_rem  = 65'd0;      // 65 bits: the shifted trial never wraps
	reg  [5:0]  sq_bit  = 6'd0;
	reg        sq_run   = 1'b0;

	// restoring square root, two bits of the radicand per step: the trial is
	// 4*root+1 placed at the current bit pair
	wire [64:0] sq_try = ({33'd0, sq_root} << 2) | 65'd1;
	wire [64:0] sq_sh  = sq_try << {sq_bit, 1'b0};
	wire        sq_ok  = (sq_rem >= sq_sh);

	//------------------------------------------------------------------
	// timing
	//------------------------------------------------------------------
	reg       div_req  = 1'b0;
	reg       sq_req   = 1'b0;

	always @(posedge clk) begin
		// ---- register writes ----
		if (we) begin
			case (addr)
			8'h80, 8'h81: div_mode <= wdata[1:0];
			8'h90, 8'h91: numer[15:0]  <= wdata;
			8'h92, 8'h93: numer[31:16] <= wdata;
			8'h94, 8'h95: numer[47:32] <= wdata;
			8'h96, 8'h97: numer[63:48] <= wdata;
			8'h98, 8'h99: denom[15:0]  <= wdata;
			8'h9A, 8'h9B: denom[31:16] <= wdata;
			8'h9C, 8'h9D: denom[47:32] <= wdata;
			8'h9E, 8'h9F: denom[63:48] <= wdata;
			8'hB0, 8'hB1: sqrt_mode <= wdata[0];
			8'hB8, 8'hB9: sqrt_param[15:0]  <= wdata;
			8'hBA, 8'hBB: sqrt_param[31:16] <= wdata;
			8'hBC, 8'hBD: sqrt_param[47:32] <= wdata;
			8'hBE, 8'hBF: sqrt_param[63:48] <= wdata;
			default: ;
			endcase
		end

		// the request lands one cycle after the write, so the register file
		// already holds the value being written
		div_req <= div_start;
		sq_req  <= sqrt_start;

		// ---- division: load the divider on a request, one step per clock;
		// a new request always wins over a running one (each NUMER/DENOM
		// write restarts the operation, as on hardware)
		if (div_req) begin
			div_busy <= 1'b1;
			div0     <= (denom == 64'd0);
			// a 32-bit dividend starts left-aligned so its 32 steps shift
			// out exactly its own bits
			dv_num   <= wide ? n_mag : {n_mag[31:0], 32'd0};
			dv_den   <= d_mag;
			dv_q     <= 64'd0;
			dv_r     <= 65'd0;
			dv_step  <= wide ? 7'd64 : 7'd32;
			dv_wide  <= wide;
			dv_qneg  <= wide ? (sn_full[63] ^ sd_full[63])
			                 : (sn_nar[31] ^ sd_nar[31]);
			dv_rneg  <= wide ? sn_full[63] : sn_nar[31];
			dv_zdiv  <= (d_mag == 64'd0);
		end else if (div_busy) begin
			dv_r   <= dv_r_n;
			dv_q   <= dv_q_n;
			dv_num <= {dv_num[62:0], 1'b0};
			if (dv_step == 7'd1) begin
				div_busy <= 1'b0;
				quot <= (denom == 64'd0) ? q_zero
				                         : (dv_zdiv ? 64'd0 : q_fin);
				remd <= (denom == 64'd0) ? numer
				                         : (dv_zdiv ? 64'd0 : r_fin);
			end else begin
				dv_step <= dv_step - 7'd1;
			end
		end

		// ---- square root ----
		if (sq_req) begin
			sqrt_busy <= 1'b1;
			sq_root   <= 32'd0;
			sq_rem    <= sqrt_mode ? {1'b0, sqrt_param}
			                       : {33'd0, sqrt_param[31:0]};
			sq_bit    <= sqrt_mode ? 6'd31 : 6'd15;
			sq_run    <= 1'b1;
		end else if (sq_run) begin
			if (sq_bit == 6'd0) begin
				sq_run    <= 1'b0;
				sqrt_busy <= 1'b0;
				sqrt_res  <= sq_ok ? ((sq_root << 1) | 32'd1) : (sq_root << 1);
			end else begin
				if (sq_ok) begin
					sq_rem  <= sq_rem - sq_sh;
					sq_root <= (sq_root << 1) | 32'd1;
				end else begin
					sq_root <= sq_root << 1;
				end
				sq_bit <= sq_bit - 6'd1;
			end
		end

		if (reset) begin
			div_mode  <= 2'd0;
			div_busy  <= 1'b0;
			div0      <= 1'b0;
			div_req   <= 1'b0;
			dv_num    <= 64'd0;
			dv_den    <= 64'd0;
			dv_q      <= 64'd0;
			dv_r      <= 65'd0;
			dv_step   <= 7'd0;
			dv_wide   <= 1'b0;
			dv_qneg   <= 1'b0;
			dv_rneg   <= 1'b0;
			dv_zdiv   <= 1'b0;
			numer     <= 64'd0;
			denom     <= 64'd0;
			quot      <= 64'd0;
			remd      <= 64'd0;
			sqrt_mode <= 1'b0;
			sqrt_busy <= 1'b0;
			sqrt_param <= 64'd0;
			sqrt_res  <= 32'd0;
			sq_run    <= 1'b0;
			sq_req    <= 1'b0;
			sq_root   <= 32'd0;
			sq_rem    <= 64'd0;
			sq_bit    <= 6'd0;
		end
	end

	//------------------------------------------------------------------
	// reads: 16-bit slices
	//------------------------------------------------------------------
	always @(*) begin
		case (addr)
		8'h80, 8'h81: rdata = {div_busy, div0, 12'd0, div_mode};
		8'h90, 8'h91: rdata = numer[15:0];
		8'h92, 8'h93: rdata = numer[31:16];
		8'h94, 8'h95: rdata = numer[47:32];
		8'h96, 8'h97: rdata = numer[63:48];
		8'h98, 8'h99: rdata = denom[15:0];
		8'h9A, 8'h9B: rdata = denom[31:16];
		8'h9C, 8'h9D: rdata = denom[47:32];
		8'h9E, 8'h9F: rdata = denom[63:48];
		8'hA0, 8'hA1: rdata = quot[15:0];
		8'hA2, 8'hA3: rdata = quot[31:16];
		8'hA4, 8'hA5: rdata = quot[47:32];
		8'hA6, 8'hA7: rdata = quot[63:48];
		8'hA8, 8'hA9: rdata = remd[15:0];
		8'hAA, 8'hAB: rdata = remd[31:16];
		8'hAC, 8'hAD: rdata = remd[47:32];
		8'hAE, 8'hAF: rdata = remd[63:48];
		8'hB0, 8'hB1: rdata = {sqrt_busy, 13'd0, 1'b0, sqrt_mode};
		8'hB4, 8'hB5: rdata = sqrt_res[15:0];
		8'hB6, 8'hB7: rdata = sqrt_res[31:16];
		8'hB8, 8'hB9: rdata = sqrt_param[15:0];
		8'hBA, 8'hBB: rdata = sqrt_param[31:16];
		8'hBC, 8'hBD: rdata = sqrt_param[47:32];
		8'hBE, 8'hBF: rdata = sqrt_param[63:48];
		default: rdata = 16'h0000;
		endcase
	end

endmodule
