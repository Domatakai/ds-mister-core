//============================================================================
// tb_pak_worst -- what a pak access costs when the cart never stops asking
//
// tb_exp_ddr measures the shim on its own and tb_ddr_arb measures the
// handshake, but neither says what a game actually sees: the pak shares
// DDR3 with the cart ROM, so its worst case is a line spent behind a cart
// line. This bench runs the real exp_ddr and the real ddr_arb against a
// bridge model and a cart that re-requests every free cycle, and measures
// the pak's request-to-done latency both ways.
//============================================================================
`timescale 1ns/1ps

module tb_pak_worst;

reg clk = 0;
always #5 clk = ~clk;

reg reset = 1;

// ---- the pak, as main_bus drives it
reg         req = 0, wr = 0;
reg  [23:0] hw = 24'd0;
reg  [15:0] wdata = 16'd0;
reg   [1:0] be = 2'b11;
wire        done;
wire [15:0] rdata;

wire        d_req, d_wr;
wire [28:0] d_addr;
wire [63:0] d_din;
wire  [7:0] d_be;
wire        d_ack;
wire [63:0] d_dout;          // the arbiter's pak-side answer

exp_ddr pak (
	.clk(clk), .reset(reset),
	.req(req), .wr(wr), .hw(hw), .wdata(wdata), .be(be),
	.done(done), .rdata(rdata),
	.d_req(d_req), .d_wr(d_wr), .d_addr(d_addr), .d_din(d_din), .d_be(d_be),
	.d_ack(d_ack), .d_dout(d_dout), .d_busy(1'b0)
);

// ---- the cart, which only ever reads lines from its ROM window
reg         c_req = 0, c_wr = 0;
reg  [28:0] c_addr = 29'd0;
reg  [63:0] c_din = 64'd0;
reg   [7:0] c_be = 8'hFF;
wire        c_ack, c_busy;
wire [63:0] c_dout;

wire        b_req, b_req_wr;
wire [28:0] b_addr;
wire [63:0] b_din;
wire  [7:0] b_be;
reg         b_ack = 0, b_busy = 0;
reg  [63:0] b_dout = 64'd0;

ddr_arb arb (
	.clk(clk), .reset(reset),
	.c_req(c_req), .c_wr(c_wr), .c_addr(c_addr), .c_din(c_din), .c_be(c_be),
	.c_ack(c_ack), .c_dout(c_dout), .c_busy(c_busy),
	.e_req(d_req), .e_wr(d_wr), .e_addr(d_addr), .e_din(d_din), .e_be(d_be),
	.e_ack(d_ack), .e_dout(d_dout), .e_busy(),
	.req(b_req), .req_wr(b_req_wr), .req_addr(b_addr), .req_din(b_din),
	.req_be(b_be), .ack(b_ack), .busy(b_busy), .dout(b_dout)
);

//------------------------------------------------------------------
// bridge model: busy while a request is up, ack after bm_lat cycles
//------------------------------------------------------------------
reg [4:0] bm_lat = 5'd7;      // one DDR3 line, as tb_ddr_bridge models it
reg [4:0] bm_dly = 5'd7;

always @(posedge clk) begin
	if (reset) begin
		b_ack <= 0; b_busy <= 0; bm_dly <= bm_lat;
	end else if (!b_req) begin
		b_ack <= 0; b_busy <= 0; bm_dly <= bm_lat;
	end else begin
		b_busy <= 1;
		b_dout <= {56'd0, b_addr[7:0]};
		if (!b_ack) begin
			if (bm_dly != 5'd0) bm_dly <= bm_dly - 5'd1;
			else                b_ack <= 1;
		end
	end
end

//------------------------------------------------------------------
// the cart, streaming: request, take the line, drop for one cycle, again
//------------------------------------------------------------------
reg        stream = 0;
integer    cart_lines = 0;

always @(posedge clk) begin
	if (reset) begin
		c_req <= 0;
		c_addr <= 29'd0;
	end else if (c_ack) begin
		cart_lines <= cart_lines + 1;
		c_req <= 0;
	end else if (stream && !c_req) begin
		c_req  <= 1;
		c_addr <= c_addr + 29'd1;
	end
end

//------------------------------------------------------------------
integer accs = 0;      // accesses the shim actually answered

task pak_acc;
	input  [23:0] off;
	output integer c;
	begin
		req <= 0;
		@(posedge clk);
		hw <= off; wr <= 1'b0; be <= 2'b11; req <= 1;
		c = 0;
		@(posedge clk);
		while (!done) begin @(posedge clk); c = c + 1; end
		accs = accs + 1;
		req <= 0;
		@(posedge clk);
	end
endtask

integer errors = 0;
task check;
	input [8*44:1] name;
	input cond;
	begin
		if (cond !== 1'b1) begin
			$display("FAIL %0s", name);
			errors = errors + 1;
		end else
			$display("ok   %0s", name);
	end
endtask

integer i, cyc, c_idle, c_worst, c_sum, lines0;

initial begin
	repeat (4) @(posedge clk);
	reset = 0;
	repeat (4) @(posedge clk);

	// ---- an empty port: the shim plus one line
	pak_acc(24'd0, c_idle);
	check("a lone access costs the shim plus a line", c_idle <= bm_lat + 8);

	// ---- the same, with the cart re-requesting every free cycle
	stream = 1;
	repeat (6) @(posedge clk);
	lines0 = cart_lines;
	c_worst = 0;
	c_sum   = 0;
	for (i = 0; i < 8; i = i + 1) begin
		pak_acc(i[23:0] * 24'd4, cyc);
		c_sum = c_sum + cyc;
		if (cyc > c_worst) c_worst = cyc;
	end
	stream = 0;

	$display({"info: pak access idle %0d, worst %0d, mean %0d clk_sys ",
	          "(bridge line %0d)"}, c_idle, c_worst, c_sum / 8, bm_lat);
	$display("info: the cart completed %0d lines across those 8 accesses",
	         cart_lines - lines0);

	check("every pak access was answered", accs == 9);
	check("worst case is bounded by about two lines", c_worst <= 2 * bm_lat + 20);
	check("contention costs something", c_worst > c_idle);
	check("the cart still made progress", cart_lines - lines0 >= 8);

	if (errors == 0) $display("tb_pak_worst: PASS");
	else             $display("tb_pak_worst: FAIL (%0d errors)", errors);
	$finish;
end

initial begin
	#500000;
	$display("tb_pak_worst: FAIL -- timeout");
	$finish;
end

endmodule
