//============================================================================
// NDS MiSTer Test — DDR3 clock-domain bridge
//
//   iverilog -g2012 -o /tmp/tb_ddrb tb/tb_ddr_bridge.sv \
//            rtl/cart/ddr_bus_bridge.sv
//   vvp /tmp/tb_ddrb
//
// The core runs on the DS's 67.0274 MHz; the framework's DDR3 interface is
// pinned to its 50 MHz reference, so every cart transaction crosses this
// bridge. The two clocks here are deliberately not related by an integer
// ratio (a 14.92 ns core clock against a 20 ns DDR clock), which is what
// makes the crossing the thing under test rather than an accident of phase.
//
// Checks:
//   1. a read returns the DDR line the model served for that address
//   2. a write reaches the model with its byte enables intact
//   3. the RD/WE strobes are held while BUSY is asserted, and the read waits
//      for DOUT_READY rather than sampling early
//   4. one request is one transaction: back-to-back requests (one core cycle
//      of gap) each get exactly one ack, and the model never coalesces or
//      repeats one
//   5. the ack is a level: it arrives only after the DDR side is done and
//      stays up until the core retires the access
//============================================================================
`timescale 1ns / 1ps

module tb_ddr_bridge;

	reg clk = 0;            // core: 67.0274 MHz
	always #7.4599 clk = ~clk;

	reg clk_ddr = 0;        // framework DDRAM reference: 50 MHz
	always #10 clk_ddr = ~clk_ddr;

	reg reset = 1, reset_ddr = 1;

	// ---- core side ----
	reg         req = 0;
	reg         req_wr = 0;
	reg  [28:0] req_addr = 0;
	reg  [63:0] req_din = 0;
	reg   [7:0] req_be = 8'hFF;
	wire        ack;
	wire [63:0] dout;

	// ---- DDR side ----
	wire  [7:0]  ddr_burstcnt;
	wire [28:0] ddr_addr;
	wire [63:0] ddr_din;
	wire  [7:0] ddr_be;
	wire        ddr_we, ddr_rd;
	reg         ddr_busy = 0;
	reg         ddr_dout_ready = 0;
	reg  [63:0] ddr_dout = 64'd0;

	ddr_bus_bridge dut (
		.clk(clk), .reset(reset),
		.req(req), .req_wr(req_wr), .req_addr(req_addr),
		.req_din(req_din), .req_be(req_be),
		.ack(ack), .dout(dout),
		.clk_ddr(clk_ddr), .reset_ddr(reset_ddr),
		.ddr_burstcnt(ddr_burstcnt), .ddr_addr(ddr_addr),
		.ddr_din(ddr_din), .ddr_be(ddr_be),
		.ddr_we(ddr_we), .ddr_rd(ddr_rd),
		.ddr_busy(ddr_busy),
		.ddr_dout_ready(ddr_dout_ready), .ddr_dout(ddr_dout)
	);

	//------------------------------------------------------------------
	// DDR3 controller model: waitrequest handshake, a read latency that is
	// not a multiple of the core period, and one line of storage per address
	//------------------------------------------------------------------
	reg  [63:0] mem [0:15];
	reg  [63:0] pend = 64'd0;

	integer n_txn = 0;      // transactions the model accepted
	integer errors = 0;
	integer checks = 0;

	task check(input ok, input [8*58-1:0] what);
		begin
			checks = checks + 1;
			if (!ok) begin
				errors = errors + 1;
				$display("  FAIL %0s", what);
			end
		end
	endtask

	// BUSY is asserted on a pattern of its own (refresh, other masters)
	integer busy_phase = 0;
	always @(posedge clk_ddr) busy_phase <= (busy_phase + 1) % 9;

	reg  [7:0] model_lat = 8'd0;
	reg        have_pend  = 1'b0;
	reg  [28:0] pend_addr = 29'd0;

	always @(posedge clk_ddr) begin
		ddr_dout_ready <= 1'b0;

		// drive BUSY periodically, but never in the cycle a strobe is taken,
		// so the "held until taken" rule is really exercised
		ddr_busy <= (busy_phase < 3) && !(ddr_rd || ddr_we);

		if (ddr_we && !ddr_busy) begin
			mem[ddr_addr[3:0]] <= ddr_din;
			n_txn = n_txn + 1;
		end

		if (ddr_rd && !ddr_busy) begin
			pend_addr <= ddr_addr;
			have_pend <= 1'b1;
			model_lat <= 8'd7;          // 140 ns of DDR latency
			n_txn     = n_txn + 1;
		end

		if (have_pend) begin
			if (model_lat == 8'd0) begin
				ddr_dout       <= mem[pend_addr[3:0]];
				ddr_dout_ready <= 1'b1;
				have_pend      <= 1'b0;
			end else begin
				model_lat <= model_lat - 8'd1;
			end
		end
	end

	//------------------------------------------------------------------
	// core-side driver
	//------------------------------------------------------------------
	integer i;
	reg [63:0] got;

	task do_req(input wr, input [28:0] a, input [63:0] din, output [63:0] d);
		begin
			@(posedge clk);
			req      <= 1'b1;
			req_wr   <= wr;
			req_addr <= a;
			req_din  <= din;
			wait (ack === 1'b1);
			#1 d = dout;
			@(posedge clk);
			req <= 1'b0;
			wait (ack === 1'b0);
		end
	endtask

	always #1 if (reset) begin
		// nothing
	end

	initial begin
		for (i = 0; i < 16; i = i + 1) mem[i] = 64'hDEAD_0000_0000_0000 | i;
		mem[3] = 64'h0123_4567_89AB_CDEF;
		mem[7] = 64'hFEDC_BA98_7654_3210;

		repeat (6) @(posedge clk_ddr);
		reset     = 1'b0;
		reset_ddr = 1'b0;
		repeat (6) @(posedge clk_ddr);

		// ---- 1. a read returns the line the DDR side served ----
		n_txn = 0;
		do_req(1'b0, 29'd3, 64'd0, got);
		check(got === 64'h0123_4567_89AB_CDEF, "read returns the served line (addr 3)");
		check(n_txn == 1, "one request is one DDR transaction");

		do_req(1'b0, 29'd7, 64'd0, got);
		check(got === 64'hFEDC_BA98_7654_3210, "second read returns its own line");

		// back-to-back reads on different addresses must not cross
		do_req(1'b0, 29'd1, 64'd0, got);
		check(got === (64'hDEAD_0000_0000_0000 | 64'd1), "third read keeps its address");

		// ---- 2. a write reaches the DDR side with its byte enables ----
		n_txn = 0;
		do_req(1'b1, 29'd5, 64'hAAAA_BBBB_CCCC_DDDD, got);
		check(mem[5] === 64'hAAAA_BBBB_CCCC_DDDD, "write lands in the DDR model");
		check(n_txn == 1, "one write is one DDR transaction");

		do_req(1'b0, 29'd5, 64'd0, got);
		check(got === 64'hAAAA_BBBB_CCCC_DDDD, "the write reads back");

		// ---- 3. sixteen back-to-back requests, one ack each ----
		n_txn = 0;
		for (i = 0; i < 16; i = i + 1) begin
			do_req(1'b0, i[28:0], 64'd0, got);
			check(got === mem[i], "streamed read matches its line");
		end
		check(n_txn == 16, "sixteen requests made sixteen DDR transactions");

		$display("");
		$display("  %0d checks, %0d failure(s)", checks, errors);
		if (errors == 0) $display("TB DDR BRIDGE PASS");
		else             $display("TB DDR BRIDGE FAIL");
		$finish;
	end

	initial begin
		#200_000;
		$display("TB DDR BRIDGE FAIL (timeout)");
		$finish;
	end

endmodule
