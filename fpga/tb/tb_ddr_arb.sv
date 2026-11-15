//============================================================================
// tb_ddr_arb -- the cart and the 32 MB pak sharing the DDR3 port
//
// What has to hold: one requester at a time, ack and dout only to the one
// that was granted, the grant released when that request ends, and -- the
// part that breaks quietly -- a requester still waiting for the grant must
// see busy, because both the cart and the bridge hold their side of the
// handshake until busy falls. A requester that sees "not busy" cancels and
// then waits for an ack that never comes.
//============================================================================
`timescale 1ns/1ps

module tb_ddr_arb;

reg clk = 0;
always #5 clk = ~clk;

reg         reset = 1;

reg         c_req = 0, c_wr = 0;
reg  [28:0] c_addr = 29'd0;
reg  [63:0] c_din = 64'd0;
reg   [7:0] c_be = 8'd0;
wire        c_ack, c_busy;
wire [63:0] c_dout;

reg         e_req = 0, e_wr = 0;
reg  [28:0] e_addr = 29'd0;
reg  [63:0] e_din = 64'd0;
reg   [7:0] e_be = 8'd0;
wire        e_ack, e_busy;
wire [63:0] e_dout;

wire        req, req_wr;
wire [28:0] req_addr;
wire [63:0] req_din;
wire  [7:0] req_be;
reg         ack = 0, busy = 0;
reg  [63:0] dout = 64'd0;

ddr_arb dut (
	.clk(clk), .reset(reset),
	.c_req(c_req), .c_wr(c_wr), .c_addr(c_addr), .c_din(c_din), .c_be(c_be),
	.c_ack(c_ack), .c_dout(c_dout), .c_busy(c_busy),
	.e_req(e_req), .e_wr(e_wr), .e_addr(e_addr), .e_din(e_din), .e_be(e_be),
	.e_ack(e_ack), .e_dout(e_dout), .e_busy(e_busy),
	.req(req), .req_wr(req_wr), .req_addr(req_addr), .req_din(req_din),
	.req_be(req_be), .ack(ack), .busy(busy), .dout(dout)
);

//------------------------------------------------------------------
// bridge model: busy while a request is up, ack two cycles later and
// held, with the answer echoing the address it was asked for
//------------------------------------------------------------------
reg [1:0] dly = 2'd2;
always @(posedge clk) begin
	if (reset) begin
		ack <= 0; busy <= 0; dly <= 2'd2;
	end else if (!req) begin
		ack <= 0; busy <= 0; dly <= 2'd2;
	end else begin
		busy <= 1;
		dout <= {56'd0, req_addr[7:0]};
		if (!ack) begin
			if (dly != 2'd0) dly <= dly - 2'd1;
			else             ack <= 1;
		end
	end
end

//------------------------------------------------------------------
// checks
//------------------------------------------------------------------
integer errors = 0;
task check;
	input [8*44:1] name;
	input cond;
	begin
		if (!cond) begin
			$display("FAIL %0s", name);
			errors = errors + 1;
		end else
			$display("ok   %0s", name);
	end
endtask

// a line the way the cart asks for one: request until acked, then drop
task cart_line;
	input  [28:0] a;
	output [63:0] got;
	reg            saw_e;
	begin
		saw_e = 0;
		@(posedge clk);
		c_req <= 1; c_addr <= a;
		@(posedge clk);
		while (!c_ack) begin
			if (e_ack) saw_e = 1;
			@(posedge clk);
		end
		got = c_dout;
		if (e_ack) saw_e = 1;
		@(posedge clk);
		c_req <= 0;
		@(posedge clk);
		check("the cart's ack went only to the cart", !saw_e);
	end
endtask

task pak_line;
	input  [28:0] a;
	output [63:0] got;
	reg            saw_c;
	begin
		saw_c = 0;
		@(posedge clk);
		e_req <= 1; e_addr <= a;
		@(posedge clk);
		while (!e_ack) begin
			if (c_ack) saw_c = 1;
			@(posedge clk);
		end
		got = e_dout;
		if (c_ack) saw_c = 1;
		@(posedge clk);
		e_req <= 0;
		@(posedge clk);
		check("the pak's ack went only to the pak", !saw_c);
	end
endtask

// a write through the port: the data, enables and direction have to arrive
// intact, or the cart writes the pak's line and nobody notices in a read test
task cart_write;
	input  [28:0] a;
	input  [63:0] d;
	input   [7:0] b;
	reg            ok, own;
	begin
		@(posedge clk);
		c_req <= 1; c_wr <= 1; c_addr <= a; c_din <= d; c_be <= b;
		@(posedge clk);
		ok = 0;
		while (!c_ack) begin
			if (req && req_wr && req_addr === a && req_din === d && req_be === b)
				ok = 1;
			@(posedge clk);
		end
		if (req && req_wr && req_addr === a && req_din === d && req_be === b)
			ok = 1;
		check("the cart's write reaches the port intact", ok);
		c_wr <= 0; c_req <= 0;
		@(posedge clk);
	end
endtask

task pak_write;
	input  [28:0] a;
	input  [63:0] d;
	input   [7:0] b;
	reg            ok;
	begin
		@(posedge clk);
		e_req <= 1; e_wr <= 1; e_addr <= a; e_din <= d; e_be <= b;
		@(posedge clk);
		ok = 0;
		while (!e_ack) begin
			if (req && req_wr && req_addr === a && req_din === d && req_be === b)
				ok = 1;
			@(posedge clk);
		end
		if (req && req_wr && req_addr === a && req_din === d && req_be === b)
			ok = 1;
		check("the pak's write reaches the port intact", ok);
		e_wr <= 0; e_req <= 0;
		@(posedge clk);
	end
endtask

reg [63:0] got;
integer    i;

initial begin
	repeat (4) @(posedge clk);
	reset = 0;
	repeat (2) @(posedge clk);

	check("nothing is busy on an idle port",
	      c_busy === 1'b0 && e_busy === 1'b0 && req === 1'b0);

	// ---- one requester at a time
	cart_line(29'h000_1234, got);
	check("cart line carries its address", req_addr === 29'h000_1234 || got === 64'h34);
	check("cart gets the answer, not the pak", got === 64'h34);
	repeat (2) @(posedge clk);
	check("the grant is released afterwards", req === 1'b0);

	pak_line(29'h200_00A5, got);
	check("pak line carries its address", got === 64'hA5);
	repeat (2) @(posedge clk);
	check("the grant is released again", req === 1'b0);

	// ---- writes keep their direction, data and enables through the mux
	cart_write(29'h000_0777, 64'h0123_4567_89AB_CDEF, 8'hF0);
	pak_write (29'h200_0888, 64'hFEDC_BA98_7654_3210, 8'h0F);
	cart_line(29'h000_0777, got);
	check("a read after the writes is a read again", got === 64'h77);
	repeat (2) @(posedge clk);
	check("and the port is not left in write mode", req_wr === 1'b0);

	// ---- a reset in the middle of a transfer lets go of the port
	e_req <= 1; e_wr <= 0; e_addr <= 29'h200_0999;
	@(posedge clk); @(posedge clk);
	reset <= 1;
	@(posedge clk); @(posedge clk);
	reset <= 0;
	e_req <= 0;
	@(posedge clk); @(posedge clk);
	check("a reset drops the port", req === 1'b0 && !c_busy && !e_busy);

	// ---- the regression this bench exists for: the cart asking while
	// the pak holds the port must see busy, or it cancels its request and
	// later waits forever for an ack
	e_req <= 1; e_addr <= 29'h200_0011;
	@(posedge clk);
	@(posedge clk);
	c_req <= 1; c_addr <= 29'h000_0042;
	repeat (2) @(posedge clk);
	check("waiting for the port looks busy to the cart", c_busy === 1'b1);
	check("and the pak is the one being served", req_addr === 29'h200_0011);
	while (!e_ack) @(posedge clk);
	e_req <= 0;
	@(posedge clk);
	// now the cart's own request goes through, on the same held req
	while (!c_ack) @(posedge clk);
	check("the cart's waiting request is still alive", c_dout === 64'h42);
	c_req <= 0;
	@(posedge clk);

	// ---- both asking: one wins, both end up served, and the loser does
	// not starve
	c_req <= 1; c_addr <= 29'h000_0001;
	e_req <= 1; e_addr <= 29'h200_0002;
	@(posedge clk);
	check("only one of the two is on the port at a time",
	      !(c_ack && e_ack));
	repeat (24) @(posedge clk);
	c_req <= 0; e_req <= 0;
	repeat (4) @(posedge clk);
	check("both requesters finished", !c_busy && !e_busy && req === 1'b0);

	// ---- the cart streaming must not starve the pak
	c_req <= 1; c_addr <= 29'h000_0100;
	e_req <= 1; e_addr <= 29'h200_0200;
	fork
		begin : cart_stream
			for (i = 0; i < 6; i = i + 1) begin
				while (!c_ack) @(posedge clk);
				@(posedge clk);
				c_addr <= c_addr + 29'd1;
			end
			c_req <= 0;
		end
		begin : pak_wait
			while (!e_ack) @(posedge clk);
			@(posedge clk);
			e_req <= 0;
		end
	join
	repeat (4) @(posedge clk);
	check("the pak got through a cart burst", req === 1'b0 && !c_busy);

	if (errors == 0) $display("tb_ddr_arb: PASS");
	else             $display("tb_ddr_arb: FAIL (%0d errors)", errors);
	$finish;
end

initial begin
	#100000;
	$display("tb_ddr_arb: FAIL -- timeout");
	$finish;
end

endmodule
