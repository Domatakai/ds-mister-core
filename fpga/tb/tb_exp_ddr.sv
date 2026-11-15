//============================================================================
// tb_exp_ddr -- the 32 MB pak's DDR3 shim
//
// main_bus's bench models the pak's answer; this bench drives the real
// shim against a small line memory standing in for ddr_bus_bridge, so the
// parts that bench cannot see are checked here: the line a halfword
// lands in, which bytes a partial write touches, which halfword of the
// line comes back, and the handshake that lets the bus hold a request
// across both halves of a 32-bit access.
//============================================================================
`timescale 1ns/1ps

module tb_exp_ddr;

reg clk = 0;
always #5 clk = ~clk;

reg         reset = 1;
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
reg         d_ack = 0;
reg  [63:0] d_dout = 64'd0;

exp_ddr dut (
	.clk(clk), .reset(reset),
	.req(req), .wr(wr), .hw(hw), .wdata(wdata), .be(be),
	.done(done), .rdata(rdata),
	.d_req(d_req), .d_wr(d_wr), .d_addr(d_addr),
	.d_din(d_din), .d_be(d_be),
	.d_ack(d_ack), .d_dout(d_dout), .d_busy(1'b0)
);

//------------------------------------------------------------------
// line memory standing in for the DDR3: two cycles, then ack
//------------------------------------------------------------------
reg [63:0] line [0:15];
reg  [3:0] bm_lat = 4'd2;
reg  [3:0] dly = 4'd2;
integer    ndone = 0;      // transactions the shim has started
integer    k;
initial for (k = 0; k < 16; k = k + 1) line[k] = 64'd0;

always @(posedge clk) begin
	if (reset) begin
		d_ack <= 0;
		dly   <= bm_lat;
	end else if (!d_req) begin
		d_ack <= 0;
		dly   <= bm_lat;
	end else if (!d_ack) begin
		if (dly != 4'd0) begin
			dly <= dly - 4'd1;
		end else begin
			if (d_wr) begin
				for (k = 0; k < 8; k = k + 1)
					if (d_be[k]) line[d_addr[3:0]][k*8 +: 8] <= d_din[k*8 +: 8];
			end else begin
				d_dout <= line[d_addr[3:0]];
			end
			d_ack <= 1;
			ndone <= ndone + 1;
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

// one access, the way main_bus presents it: req held until done
task acc;
	input  [23:0] off;
	input         w;
	input  [15:0] wd;
	input   [1:0] b;
	output [15:0] rd;
	begin
		@(posedge clk);
		hw <= off; wr <= w; wdata <= wd; be <= b; req <= 1;
		@(posedge clk);
		while (!done) @(posedge clk);
		rd = rdata;
		req <= 0;
		@(posedge clk);
	end
endtask

reg [15:0] rd;
integer    cyc, c_fast, c_slow, c_write;

// one access, counting the cycles it takes with the bridge at `lat`
task measure;
	input  [3:0] lat;
	input         w;
	output integer c;
	begin
		bm_lat = lat;
		req <= 0;
		@(posedge clk);
		hw <= 24'd20; wr <= w; wdata <= 16'h5A5A; be <= 2'b11; req <= 1;
		c = 0;
		@(posedge clk);
		while (!done) begin @(posedge clk); c = c + 1; end
		req <= 0;
		@(posedge clk);
	end
endtask

reg [28:0] first_addr;
reg  [7:0] first_be;
integer    t0;

initial begin
	repeat (4) @(posedge clk);
	reset = 0;
	repeat (2) @(posedge clk);

	// ---- the line a halfword lands in, and the lane inside it
	line[0] = 64'h1122_3344_5566_7788;
	acc(24'd0, 1'b0, 16'd0, 2'b11, rd);
	check("hw 0 is the low halfword of line 0", rd === 16'h7788);
	acc(24'd1, 1'b0, 16'd0, 2'b11, rd);
	check("hw 1 is the next one up", rd === 16'h5566);
	acc(24'd3, 1'b0, 16'd0, 2'b11, rd);
	check("hw 3 is the top halfword", rd === 16'h1122);
	acc(24'd4, 1'b0, 16'd0, 2'b11, rd);
	check("hw 4 moves to the next line", rd === 16'h0000);

	// and the line it asked the bridge for
	acc(24'd0, 1'b0, 16'd0, 2'b11, rd);
	check("line 0 is 256 MB into the DDR3", first_addr === 29'h200_0000);
	acc(24'd4, 1'b0, 16'd0, 2'b11, rd);
	check("hw 4 asks for the line after it", first_addr === 29'h200_0001);

	// ---- a halfword write touches its own two bytes
	acc(24'd2, 1'b1, 16'hAABB, 2'b11, rd);
	acc(24'd2, 1'b0, 16'd0, 2'b11, rd);
	check("halfword write round-trips", rd === 16'hAABB);
	acc(24'd3, 1'b0, 16'd0, 2'b11, rd);
	check("its neighbour is untouched", rd === 16'h1122);

	// ---- a single byte leaves the other one alone
	acc(24'd0, 1'b1, 16'h00CC, 2'b01, rd);
	acc(24'd0, 1'b0, 16'd0, 2'b11, rd);
	check("byte write keeps the high byte", rd === 16'h77CC);
	// the byte arrives in its own lane, as main_bus presents it
	acc(24'd0, 1'b1, 16'hDD00, 2'b10, rd);
	acc(24'd0, 1'b0, 16'd0, 2'b11, rd);
	check("byte write keeps the low byte", rd === 16'hDDCC);

	// the enables the bridge sees for those writes
	acc(24'd1, 1'b1, 16'h1234, 2'b01, rd);
	check("low byte only -> bridge be 0x04", first_be == 8'h04);
	acc(24'd1, 1'b1, 16'h1234, 2'b10, rd);
	check("high byte only -> bridge be 0x08", first_be == 8'h08);
	acc(24'd1, 1'b1, 16'h1234, 2'b11, rd);
	check("both bytes -> bridge be 0x0C", first_be == 8'h0C);

	// ---- the bus holding req across both halves of a 32-bit access
	line[2] = 64'h7777_6666_5555_4444;
	t0 = ndone;
	@(posedge clk);
	hw <= 24'd8; wr <= 1'b0; be <= 2'b11; req <= 1;
	@(posedge clk);
	while (!done) @(posedge clk);
	check("first beat answered", rdata === 16'h4444);
	// keep req high and move to the next halfword, as the bus does
	hw <= 24'd9;
	@(posedge clk);
	while (!done) @(posedge clk);
	check("second beat answered while req stayed high", rdata === 16'h5555);
	req <= 0;
	@(posedge clk);
	check("two transactions, not one", ndone - t0 == 2);

	// ---- what the shim costs on top of the bridge's own latency: the same
	// access twice, with the bridge acking at two different latencies, and
	// the difference is the shim's own
	measure(4'd2, 1'b0, c_fast);
	measure(4'd8, 1'b0, c_slow);
	measure(4'd2, 1'b1, c_write);
	$display("info: req to done: %0d cycles at a 2-cycle bridge, %0d at 8",
	         c_fast, c_slow);
	$display("info: the shim's own cost is %0d clk_sys (a write: %0d)",
	         c_fast - 2, c_write - 2);
	check("the shim's cost does not follow bridge latency",
	      c_slow - c_fast == 6);
	check("and it is a handful of cycles", c_fast - 2 <= 4);
	check("a write costs what a read costs", c_write == c_fast);

	if (errors == 0) $display("tb_exp_ddr: PASS");
	else             $display("tb_exp_ddr: FAIL (%0d errors)", errors);
	$finish;
end

// capture what the shim asked for, on the last cycle of each request
always @(posedge clk) if (d_req && !d_ack) begin
	first_addr <= d_addr;
	first_be   <= d_be;
end

// watchdog
initial begin
	#200000;
	$display("tb_exp_ddr: FAIL -- timeout");
	$finish;
end

endmodule
