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
		if (cond !== 1'b1) begin
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

// drop the request and let the write buffer empty itself
task flushw;
	begin
		req <= 0;
		while (dut.pw_val) @(posedge clk);
		@(posedge clk);
	end
endtask

reg [15:0] rd;
integer    cyc, c_fast, c_slow, c_write, c_hit;

// one access, counting the cycles it takes with the bridge at `lat`
task measure;
	input  [3:0] lat;
	input         w;
	input  [23:0] off;
	output integer c;
	begin
		bm_lat = lat;
		req <= 0;
		@(posedge clk);
		// let any idle prefetch finish, so this measures the access and not
		// a wait behind the prefetch
		while (dut.st !== 3'd0 || dut.pf_want || dut.pw_val) @(posedge clk);
		hw <= off; wr <= w; wdata <= 16'h5A5A; be <= 2'b11; req <= 1;
		c = 0;
		@(posedge clk);
		while (!done) begin @(posedge clk); c = c + 1; end
		req <= 0;
		@(posedge clk);
	end
endtask

// the prefetch gate's own guard (the monitor that drives these is below)
integer pf_starts = 0;
integer pf_early  = 0;
reg     pf_seen   = 1'b0;

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

	// and the line it asked the bridge for -- fresh lines, because a line
	// the cache holds is not fetched again and would leave first_addr stale
	acc(24'd96, 1'b0, 16'd0, 2'b11, rd);
	check("hw 96 is 256 MB + 24 lines in", first_addr === 29'h200_0018);
	acc(24'd100, 1'b0, 16'd0, 2'b11, rd);
	check("hw 100 asks for the line after it", first_addr === 29'h200_0019);
	while (dut.st !== 3'd0 || dut.pf_want) @(posedge clk);
	t0 = ndone;
	acc(24'd100, 1'b0, 16'd0, 2'b11, rd);
	check("a line already cached is not fetched again", ndone == t0);
	check("and still answers with its own data", rd === line[9][15:0]);

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

	// the enables the bridge sees for those writes, each on its own
	acc(24'd1, 1'b1, 16'h1234, 2'b01, rd);
	flushw;
	check("low byte only -> bridge be 0x04", first_be == 8'h04);
	acc(24'd1, 1'b1, 16'h1234, 2'b10, rd);
	flushw;
	check("high byte only -> bridge be 0x08", first_be == 8'h08);
	acc(24'd1, 1'b1, 16'h1234, 2'b11, rd);
	flushw;
	check("both bytes -> bridge be 0x0C", first_be == 8'h0C);

	// ---- two halfword beats of one 32-bit store become one line
	flushw;
	t0 = ndone;
	acc(24'd116, 1'b1, 16'h1111, 2'b11, rd);
	acc(24'd117, 1'b1, 16'h2222, 2'b11, rd);
	flushw;
	check("a 32-bit write costs one line, not two", ndone - t0 == 1);
	check("and both halves merge into it", first_be == 8'h0F);
	acc(24'd116, 1'b0, 16'd0, 2'b11, rd);
	check("the merged low half reads back", rd === 16'h1111);
	acc(24'd117, 1'b0, 16'd0, 2'b11, rd);
	check("and the high half too", rd === 16'h2222);

	// a lone halfword still reaches the memory when nothing follows it
	flushw;
	acc(24'd24, 1'b1, 16'h5A5A, 2'b11, rd);
	flushw;
	acc(24'd24, 1'b0, 16'd0, 2'b11, rd);
	check("a write with nothing behind it still lands", rd === 16'h5A5A);

	// ---- the bus holding req across both halves of a 32-bit access
	line[2] = 64'h7777_6666_5555_4444;
	flushw;
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
	check("a 32-bit read costs one line, not two", ndone - t0 == 1);

	// ---- what the shim costs on top of the bridge's own latency: the same
	// access twice, with the bridge acking at two different latencies, and
	// the difference is the shim's own
	// different lines each time, so neither run is served from the cache
	measure(4'd2, 1'b0, 24'd200, c_fast);
	measure(4'd8, 1'b0, 24'd400, c_slow);
	measure(4'd2, 1'b1, 24'd600, c_write);
	$display("info: req to done: %0d cycles at a 2-cycle bridge, %0d at 8",
	         c_fast, c_slow);
	$display("info: the shim's own cost is %0d clk_sys, a write answers in %0d",
	         c_fast - 2, c_write);
	check("the shim's cost does not follow bridge latency",
	      c_slow - c_fast == 6);
	check("and it is a handful of cycles", c_fast - 2 <= 4);
	// the store is collected, not sent: the answer does not wait for a line
	check("a write is answered without waiting for the port",
	      c_write > 0 && c_write < c_fast);

	// ---- the prefetch, tested the way it is used: a sequential walk. Two
	// adjacent lines establish the direction, the second one's serve is
	// followed by an idle fetch of the third, and the third must then cost
	// nothing at all.
	// a miss on a line that follows the one just read starts the fetch of
	// the line after it, so a walk costs one fetch per two lines
	acc(24'd2400, 1'b0, 16'd0, 2'b11, rd);   // line 600: cold, prefetches 601
	repeat (16) @(posedge clk);              // time for the prefetch to land
	while (dut.st !== 3'd0 || dut.pf_want) @(posedge clk);  // port quiet
	measure(4'd2, 1'b0, 24'd2404, c_hit);    // line 601, already here
	$display("info: a prefetched line: %0d clk_sys at a 2-cycle bridge", c_hit);
	check("a prefetched line answers in a couple of cycles",
	      c_hit > 0 && c_hit <= 4);
	acc(24'd2404, 1'b0, 16'd0, 2'b11, rd);
	check("and it carries the right data", rd === line[9][15:0]);

	// that line is still cached: the store is collected, the read that
	// follows pushes it out as one line, and the cached copy follows it
	acc(24'd2404, 1'b1, 16'hBEEF, 2'b11, rd);
	t0 = ndone;
	acc(24'd2404, 1'b0, 16'd0, 2'b11, rd);
	check("a write to a cached line is visible at once", rd === 16'hBEEF);
	check("and the store cost one line, not two", ndone - t0 == 1);

	// the guard is only worth having if prefetches happen at all
	$display("info: prefetches started %0d, of those early %0d",
	         pf_starts, pf_early);
	check("prefetches do happen in this bench", pf_starts > 0);
	check("none starts inside the quiet window", pf_early == 0);

	if (errors == 0) $display("tb_exp_ddr: PASS");
	else             $display("tb_exp_ddr: FAIL (%0d errors)", errors);
	$finish;
end

// The prefetch may only start once the bus has been quiet for its window.
// The request is registered, so a start is observed on the first cycle in
// E_PFWAIT; by then `quiet` has counted one more cycle than the gate
// looked at, which is why a legal start reads 9 and not 8.
always @(posedge clk) begin
	if (dut.st != 4'd4) pf_seen <= 1'b0;
	if (dut.st === 4'd4 && !pf_seen) begin
		pf_seen   <= 1'b1;
		pf_starts  = pf_starts + 1;
		if (dut.quiet < 4'd9) pf_early = pf_early + 1;
	end
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
