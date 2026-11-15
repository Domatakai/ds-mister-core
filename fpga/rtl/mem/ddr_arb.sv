//============================================================================
// NDS MiSTer -- DDR3 request arbiter (cart ROM and the 32 MB expansion pak)
//
// The framework DDR3 port carries one transaction at a time, and
// ddr_bus_bridge enforces that with a level handshake: a requester holds
// req until ack, and the bridge holds ack until req drops. Two requesters
// share it here -- the cart slot streaming ROM lines, and a 32 MB slot-2
// expansion pak answering the CPU -- so the grant is held for the whole
// handshake and the two sides alternate, which keeps either one from
// starving the other.
//============================================================================
module ddr_arb (
	input             clk,
	input             reset,

	// requester 0: the cart slot
	input             c_req,
	input             c_wr,
	input      [28:0] c_addr,
	input      [63:0] c_din,
	input       [7:0] c_be,
	output            c_ack,
	output     [63:0] c_dout,
	output            c_busy,

	// requester 1: the slot-2 expansion pak
	input             e_req,
	input             e_wr,
	input      [28:0] e_addr,
	input      [63:0] e_din,
	input       [7:0] e_be,
	output            e_ack,
	output     [63:0] e_dout,
	output            e_busy,

	// ---- to ddr_bus_bridge ----
	output reg        req,
	output reg        req_wr,
	output reg [28:0] req_addr,
	output reg [63:0] req_din,
	output reg  [7:0] req_be,
	input             ack,
	input             busy,
	input      [63:0] dout
);

localparam [1:0] G_NONE = 2'd0, G_CART = 2'd1, G_EXP = 2'd2;

reg [1:0] granted = G_NONE;
reg       next_e  = 1'b1;   // who goes first when both are asking

wire gnt_c = (granted == G_CART);
wire gnt_e = (granted == G_EXP);

always @(posedge clk) begin
	if (reset) begin
		granted <= G_NONE;
		next_e  <= 1'b1;
	end else if (granted == G_NONE) begin
		if (e_req && (next_e || !c_req)) begin
			granted <= G_EXP;
			next_e  <= 1'b0;
		end else if (c_req) begin
			granted <= G_CART;
			next_e  <= 1'b1;
		end
	end else if (gnt_c && !c_req) begin
		granted <= G_NONE;
	end else if (gnt_e && !e_req) begin
		granted <= G_NONE;
	end
end

always @(*) begin
	req      = gnt_c ? c_req  : gnt_e ? e_req  : 1'b0;
	req_wr   = gnt_c ? c_wr   : e_wr;
	req_addr = gnt_c ? c_addr : e_addr;
	req_din  = gnt_c ? c_din  : e_din;
	req_be   = gnt_c ? c_be   : e_be;
end

assign c_ack  = gnt_c && ack;
assign e_ack  = gnt_e && ack;
assign c_dout = dout;
assign e_dout = dout;
assign c_busy = gnt_c && busy;
assign e_busy = gnt_e && busy;

endmodule
