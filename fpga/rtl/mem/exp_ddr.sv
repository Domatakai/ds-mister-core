//============================================================================
// NDS MiSTer -- slot-2 32 MB expansion pak, backed by DDR3
//
// The 8 and 16 MB paks fit in the 32 MB SDRAM module, on main_bus's is_exp
// path. The 32 MB pak does not: it is 16M halfwords by itself, more than
// the whole SDRAM module, and its window runs from 0x09000000 to
// 0x0AFFFFFF. So it lives in DDR3 beside the cart ROM, past the four cart
// slots, and NDS.sv routes its transactions here instead of to
// mem_arbiter. main_bus keeps presenting its usual held halfword request,
// so the bus state machine never learns which memory answered.
//
// One 64-bit line serves one halfword access. A halfword offset is always
// even, so an access never straddles two lines and its byte enables always
// fall inside one lane pair -- no read-modify-write is needed, the DDR
// controller masks the line write.
//============================================================================
module exp_ddr (
	input             clk,
	input             reset,

	// ---- from main_bus: a held halfword request ----
	input             req,
	input             wr,
	input      [23:0] hw,        // halfword offset inside the pak
	input      [15:0] wdata,
	input       [1:0] be,        // be[0] is the low byte, be[1] the high
	output reg        done,      // level, held until req drops
	output reg [15:0] rdata,

	// ---- DDR3 (ddr_arb's second requester) ----
	output reg        d_req,
	output reg        d_wr,
	output reg [28:0] d_addr,
	output reg [63:0] d_din,
	output reg  [7:0] d_be,
	input             d_ack,
	input      [63:0] d_dout,
	input             d_busy
);

// Line 0x200_0000 is 256 MB into the DDR3: a cart slot addresses 256 MB at
// most, so nothing staged as a ROM can reach the pak's lines.
localparam [28:0] EXP_LINE_BASE = 29'h200_0000;

localparam [1:0] E_IDLE = 2'd0, E_WAIT = 2'd1, E_DONE = 2'd2, E_HOLD = 2'd3;
reg [1:0] st = E_IDLE;
reg [23:0] last_hw = 24'd0;

wire [24:0] byte_off = {hw, 1'b0};
wire [21:0] line_idx = byte_off[24:3];
wire  [2:0] lane     = byte_off[2:0];

// the two bytes of the halfword, placed at their lane inside the line
wire [7:0] lane_be = (be[0] ? (8'h01 << lane)          : 8'h00) |
                     (be[1] ? (8'h01 << (lane + 3'd1)) : 8'h00);

wire [63:0] dout_sh = d_dout >> {lane, 3'b000};

always @(posedge clk) begin
	if (reset) begin
		st      <= E_IDLE;
		last_hw <= 24'd0;
		done   <= 1'b0;
		rdata  <= 16'h0000;
		d_req  <= 1'b0;
		d_wr   <= 1'b0;
		d_addr <= 29'd0;
		d_din  <= 64'd0;
		d_be   <= 8'h00;
	end else begin
		case (st)
		E_IDLE: if (req) begin
			last_hw <= hw;
			d_req  <= 1'b1;
			d_wr   <= wr;
			d_addr <= EXP_LINE_BASE + {7'd0, line_idx};
			d_din  <= {4{wdata}};
			d_be   <= wr ? lane_be : 8'hFF;
			st     <= E_WAIT;
		end
		E_WAIT: if (d_ack) begin
			d_req <= 1'b0;
			rdata <= dout_sh[15:0];
			st    <= E_DONE;
		end
		E_DONE: begin
			done <= 1'b1;
			st   <= E_HOLD;
		end
		// The bus holds req across both halfwords of a 32-bit access, so a
		// new beat is also a new address: either end of that ends the hold.
		E_HOLD: begin
			done <= 1'b0;
			if (!req || hw != last_hw) st <= E_IDLE;
		end
		default: st <= E_IDLE;
		endcase
	end
end

endmodule
