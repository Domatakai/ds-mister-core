//============================================================================
// NDS MiSTer Test — shared BIOS SWI bank bench
//
//   iverilog -g2012 -o /tmp/tb_swi_share tb/tb_swi_share.sv \
//            rtl/cpu/swi_hle.sv rtl/cpu/swi_share.sv
//   vvp /tmp/tb_swi_share
//
// One engine, two callers, each with its **own** memory model. That is the
// point of this bench: it is not enough that both calls return the right
// number — the engine's bus traffic has to appear on the caller's master and
// nowhere else, because a Div or a CpuSet aimed at the ARM9's address space
// must not be served out of the ARM7's.
//
// Each side's model answers like `main_bus` does for RAM: a whole word from the
// aligned address, one cycle after the request, then a **level** acknowledge
// that stays up until the engine drops the request. A one-cycle pulse would be
// wrong for the ARM7 case, whose engine step only happens on `ce7`: the ack has
// to outlive the gated cycles, which is what `cpu_ce_bridge` does in the design.
//
// Results are read one step after `done` is seen, not in the edge that raised
// it: `done` and `res*` are updated by the same clock edge, so reading inside
// that delta would sample the previous call's number. The cores do not have
// that problem — they act on `done` in the cycle *after* it rises.
//
//   1. ARM9 alone: Div, results and write-backs to the ARM9, zero bus hits on
//      the ARM7 side
//   2. ARM7 alone: the same the other way round
//   3. both calling in the same cycle: one runs, the other waits, both get
//      their own answer, and no cycle ever has two masters on the engine
//   4. round robin, tested both ways: whichever core ran most recently yields,
//      so neither can starve the other
//   5. an SWI that is not in the bank: handled = 0, no bus traffic, and the
//      completion still goes to the caller
//   6. CpuSet on each side lands in that side's memory only
//   7. the ARM7 calling while its `ce` is at half rate still completes (the
//      engine steps on the owner's enable)
//   8. `busy` is clear when the bank is idle and the two masters never overlap
//============================================================================
`timescale 1ns / 1ps

module tb_swi_share;

reg clk = 0;
always #5 clk = ~clk;

reg reset = 1;

//------------------------------------------------------------------
// caller 0: the ARM9
//------------------------------------------------------------------
reg        c9_go = 0;
reg  [7:0] c9_num = 8'h00;
reg [31:0] c9_r0 = 0, c9_r1 = 0, c9_r2 = 0, c9_r3 = 0;
wire       c9_done, c9_handled, c9_wr0, c9_wr1, c9_wr3;
wire [31:0] c9_res0, c9_res1, c9_res3;
wire        c9_b_req, c9_b_wr;
wire [31:0] c9_b_addr, c9_b_wlane;
wire  [3:0] c9_b_be;
reg         c9_b_ack = 0;
reg  [31:0] c9_b_rdata = 0;

//------------------------------------------------------------------
// caller 1: the ARM7
//------------------------------------------------------------------
reg        c7_go = 0;
reg  [7:0] c7_num = 8'h00;
reg [31:0] c7_r0 = 0, c7_r1 = 0, c7_r2 = 0, c7_r3 = 0;
wire       c7_done, c7_handled, c7_wr0, c7_wr1, c7_wr3;
wire [31:0] c7_res0, c7_res1, c7_res3;
wire        c7_b_req, c7_b_wr;
wire [31:0] c7_b_addr, c7_b_wlane;
wire  [3:0] c7_b_be;
reg         c7_b_ack = 0;
reg  [31:0] c7_b_rdata = 0;

wire busy, owner;

// clock enables: both full rate, except test 7 where the ARM7's is halved
reg ce7 = 1;
reg slow7 = 0;
always @(posedge clk) if (slow7) ce7 <= ~ce7;

swi_share dut (
	.clk(clk), .reset(reset), .ce9(1'b1), .ce7(ce7),
	.c9_go(c9_go), .c9_num(c9_num),
	.c9_r0(c9_r0), .c9_r1(c9_r1), .c9_r2(c9_r2), .c9_r3(c9_r3),
	.c9_done(c9_done), .c9_handled(c9_handled),
	.c9_res0(c9_res0), .c9_res1(c9_res1), .c9_res3(c9_res3),
	.c9_wr0(c9_wr0), .c9_wr1(c9_wr1), .c9_wr3(c9_wr3),
	.c9_b_req(c9_b_req), .c9_b_wr(c9_b_wr), .c9_b_be(c9_b_be),
	.c9_b_addr(c9_b_addr), .c9_b_wlane(c9_b_wlane),
	.c9_b_ack(c9_b_ack), .c9_b_rdata(c9_b_rdata),
	.c7_go(c7_go), .c7_num(c7_num),
	.c7_r0(c7_r0), .c7_r1(c7_r1), .c7_r2(c7_r2), .c7_r3(c7_r3),
	.c7_done(c7_done), .c7_handled(c7_handled),
	.c7_res0(c7_res0), .c7_res1(c7_res1), .c7_res3(c7_res3),
	.c7_wr0(c7_wr0), .c7_wr1(c7_wr1), .c7_wr3(c7_wr3),
	.c7_b_req(c7_b_req), .c7_b_wr(c7_b_wr), .c7_b_be(c7_b_be),
	.c7_b_addr(c7_b_addr), .c7_b_wlane(c7_b_wlane),
	.c7_b_ack(c7_b_ack), .c7_b_rdata(c7_b_rdata),
	.busy(busy), .owner(owner)
);

//------------------------------------------------------------------
// two independent 4 KB memories, one per caller
//------------------------------------------------------------------
reg [31:0] mem9 [0:1023];
reg [31:0] mem7 [0:1023];

wire [9:0] idx9 = c9_b_addr[11:2];
wire [9:0] idx7 = c7_b_addr[11:2];

reg        armed9 = 0, armed7 = 0;
integer    hits9 = 0, hits7 = 0;

always @(posedge clk) begin
	if (!c9_b_req) begin
		armed9 <= 1'b0;
	end else if (!armed9) begin
		armed9     <= 1'b1;
		c9_b_rdata <= mem9[idx9];
		hits9       = hits9 + 1;
		if (c9_b_wr) begin
			if (c9_b_be[0]) mem9[idx9][7:0]   <= c9_b_wlane[7:0];
			if (c9_b_be[1]) mem9[idx9][15:8]  <= c9_b_wlane[15:8];
			if (c9_b_be[2]) mem9[idx9][23:16] <= c9_b_wlane[23:16];
			if (c9_b_be[3]) mem9[idx9][31:24] <= c9_b_wlane[31:24];
		end
	end
end
always @(*) c9_b_ack = c9_b_req & armed9;

always @(posedge clk) begin
	if (!c7_b_req) begin
		armed7 <= 1'b0;
	end else if (!armed7) begin
		armed7     <= 1'b1;
		c7_b_rdata <= mem7[idx7];
		hits7       = hits7 + 1;
		if (c7_b_wr) begin
			if (c7_b_be[0]) mem7[idx7][7:0]   <= c7_b_wlane[7:0];
			if (c7_b_be[1]) mem7[idx7][15:8]  <= c7_b_wlane[15:8];
			if (c7_b_be[2]) mem7[idx7][23:16] <= c7_b_wlane[23:16];
			if (c7_b_be[3]) mem7[idx7][31:24] <= c7_b_wlane[31:24];
		end
	end
end
always @(*) c7_b_ack = c7_b_req & armed7;

//------------------------------------------------------------------
// scoring
//------------------------------------------------------------------
integer checks = 0, errors = 0;
integer both_bus = 0;          // cycles with two masters driving the engine
integer grants = 0;
integer first_owner = -1;      // who was granted first in a section
reg     busy_d = 0;

always @(posedge clk) begin
	if (busy && !busy_d) begin
		grants = grants + 1;
		if (first_owner < 0) first_owner = owner ? 1 : 0;
	end
	busy_d <= busy;
	if (c9_b_req && c7_b_req) both_bus = both_bus + 1;
end

task chk(input [8*40-1:0] what, input [31:0] got, input [31:0] want);
	begin
		checks = checks + 1;
		if (got !== want) begin
			errors = errors + 1;
			$display("  FAIL %0s: %h, expected %h", what, got, want);
		end
	end
endtask

reg [31:0] r9_0, r9_1, r9_3, r7_0, r7_1, r7_3;
reg        r9_h, r7_h, r9_w0, r9_w1, r9_w3, r7_w0, r7_w1, r7_w3;
integer    cap9 = 0, cap7 = 0;      // completions seen, so a task can wait on one

// A core drops its `go` in the same cycle `done` arrives; the bench does the
// same, so the arbiter never sees a request still standing after a completion
// (which would be a second call, not a continuation).
always @(posedge clk) if (c9_done) begin
	r9_0 <= c9_res0; r9_1 <= c9_res1; r9_3 <= c9_res3;
	r9_h <= c9_handled;
	r9_w0 <= c9_wr0; r9_w1 <= c9_wr1; r9_w3 <= c9_wr3;
	c9_go <= 1'b0;
	cap9 <= cap9 + 1;
end

always @(posedge clk) if (c7_done) begin
	r7_0 <= c7_res0; r7_1 <= c7_res1; r7_3 <= c7_res3;
	r7_h <= c7_handled;
	r7_w0 <= c7_wr0; r7_w1 <= c7_wr1; r7_w3 <= c7_wr3;
	c7_go <= 1'b0;
	cap7 <= cap7 + 1;
end

task call9(input [7:0] n, input [31:0] a0, a1, a2, a3);
	integer c9n;
	begin
		@(negedge clk);
		c9_num <= n; c9_r0 <= a0; c9_r1 <= a1; c9_r2 <= a2; c9_r3 <= a3;
		c9_go  <= 1'b1;
		c9n = cap9;
		while (cap9 == c9n) @(posedge clk);
		@(negedge clk);
		// `done` outlives the edge by one engine step: let it clear, so the
		// next call cannot mistake it for its own
		while (c9_done) @(posedge clk);
	end
endtask

task call7(input [7:0] n, input [31:0] a0, a1, a2, a3);
	integer c7n;
	begin
		@(negedge clk);
		c7_num <= n; c7_r0 <= a0; c7_r1 <= a1; c7_r2 <= a2; c7_r3 <= a3;
		c7_go  <= 1'b1;
		c7n = cap7;
		while (cap7 == c7n) @(posedge clk);
		@(negedge clk);
		while (c7_done) @(posedge clk);
	end
endtask

integer h9_before, h7_before, g_before, i;

initial begin
	for (i = 0; i < 1024; i = i + 1) begin
		mem9[i] = 32'd0;
		mem7[i] = 32'd0;
	end
	reset = 1;
	repeat (4) @(posedge clk);
	reset = 0;
	repeat (2) @(posedge clk);

	//==================== 1. the ARM9 alone ====================
	$display("  -- ARM9 alone");
	h7_before = hits7;
	fork call9(8'h09, 32'd100, 32'd7, 32'd0, 32'd0); join
	chk("Div quotient",  r9_0, 32'd14);
	chk("Div remainder", r9_1, 32'd2);
	chk("Div |quotient|", r9_3, 32'd14);
	chk("Div wrote r0",  r9_w0, 1);
	chk("Div wrote r1",  r9_w1, 1);
	chk("Div wrote r3",  r9_w3, 1);
	chk("Div was handled", r9_h, 1);
	chk("the ARM7 saw no traffic", hits7, h7_before);
	chk("the engine is idle again", busy, 0);

	//==================== 2. the ARM7 alone ====================
	$display("  -- ARM7 alone");
	h9_before = hits9;
	fork call7(8'h09, 32'd200, 32'd9, 32'd0, 32'd0); join
	chk("Div quotient",  r7_0, 32'd22);
	chk("Div remainder", r7_1, 32'd2);
	chk("Div |quotient|", r7_3, 32'd22);
	chk("the ARM9 saw no traffic", hits9, h9_before);
	chk("the engine is idle again", busy, 0);

	//==================== 3. both at once ====================
	// `last` resets to 1, so with both waiting the ARM9 goes first; the ARM7
	// holds its `go` and waits for the engine, exactly as a trapped core does.
	$display("  -- both in the same cycle");
	first_owner = -1;
	fork
		call9(8'h0D, 32'd256, 32'd0, 32'd0, 32'd0);
		call7(8'h0D, 32'd100, 32'd0, 32'd0, 32'd0);
	join
	chk("Sqrt(256) on the ARM9", r9_0, 32'd16);
	chk("Sqrt(100) on the ARM7", r7_0, 32'd10);
	chk("the ARM9 went first", first_owner, 0);
	chk("never two masters on the engine", both_bus, 0);

	//==================== 4. round robin, both directions ====================
	// The ARM9 has just run on its own, so it is the one that yields: this is
	// what separates a fair arbiter from a fixed-priority one, which would
	// keep handing the engine to the ARM9 here.
	$display("  -- whoever ran last yields");
	g_before = grants;
	fork call9(8'h0D, 32'd81, 32'd0, 32'd0, 32'd0); join   // ARM9 alone: last = ARM9
	first_owner = -1;
	fork
		call9(8'h0D, 32'd49, 32'd0, 32'd0, 32'd0);
		call7(8'h0D, 32'd36, 32'd0, 32'd0, 32'd0);
	join
	chk("the ARM7 went first", first_owner, 1);
	chk("Sqrt(49) on the ARM9", r9_0, 32'd7);
	chk("Sqrt(36) on the ARM7", r7_0, 32'd6);

	// and the other way round: the ARM7 ran alone last, so it now yields
	fork call7(8'h0D, 32'd64, 32'd0, 32'd0, 32'd0); join
	first_owner = -1;
	fork
		call9(8'h0D, 32'd25, 32'd0, 32'd0, 32'd0);
		call7(8'h0D, 32'd16, 32'd0, 32'd0, 32'd0);
	join
	chk("the ARM9 went first", first_owner, 0);
	chk("Sqrt(25) on the ARM9", r9_0, 32'd5);
	chk("Sqrt(16) on the ARM7", r7_0, 32'd4);
	chk("six calls, six grants", grants - g_before, 6);

	//==================== 5. not in the bank ====================
	$display("  -- an SWI the bank does not implement");
	h9_before = hits9;
	h7_before = hits7;
	fork call9(8'h00, 32'd0, 32'd0, 32'd0, 32'd0); join
	chk("SoftReset is not handled", r9_h, 0);
	chk("and it made no bus access", hits9, h9_before);
	chk("and nothing was written back", r9_w0, 0);
	fork call7(8'h00, 32'd0, 32'd0, 32'd0, 32'd0); join
	chk("SoftReset is not handled on the ARM7", r7_h, 0);
	chk("and it made no bus access either", hits7, h7_before);

	//==================== 6. whose memory is it? ====================
	// CpuSet: r0 source, r1 destination, r2 count (32-bit words)
	$display("  -- the engine's traffic follows the caller");
	mem9[0] = 32'hDEAD_BEEF;
	mem9[1] = 32'h0BAD_F00D;
	fork call9(8'h0B, 32'h0200_0000, 32'h0200_0040, 32'd2 | (1 << 26), 32'd0); join
	chk("CpuSet copied on the ARM9", mem9[16], 32'hDEAD_BEEF);
	chk("CpuSet copied word 2",     mem9[17], 32'h0BAD_F00D);
	chk("the ARM9 left the source alone", mem9[0], 32'hDEAD_BEEF);
	chk("the ARM7's memory is untouched", mem7[16], 32'd0);

	mem7[0] = 32'h1234_5678;
	mem7[1] = 32'h9ABC_DEF0;
	fork call7(8'h0B, 32'h0200_0000, 32'h0200_0040, 32'd2 | (1 << 26), 32'd0); join
	chk("CpuSet copied on the ARM7", mem7[16], 32'h1234_5678);
	chk("CpuSet copied word 2",      mem7[17], 32'h9ABC_DEF0);
	chk("the ARM9's memory kept its own copy", mem9[16], 32'hDEAD_BEEF);
	chk("never two masters on the engine", both_bus, 0);

	//==================== 7. the ARM7 at half rate ====================
	// ce7 every second cycle: the engine steps on the *owner's* enable, so an
	// ARM7 call has to keep working — and the ARM9's model must not serve it.
	$display("  -- the ARM7 calling with ce7 at half rate");
	slow7 = 1;
	fork call7(8'h0D, 32'd400, 32'd0, 32'd0, 32'd0); join
	chk("Sqrt(400) at half rate", r7_0, 32'd20);
	h9_before = hits9;
	fork call7(8'h0B, 32'h0200_0000, 32'h0200_0080, 32'd2 | (1 << 26), 32'd0); join
	chk("CpuSet at half rate, word 1", mem7[32], 32'h1234_5678);
	chk("CpuSet at half rate, word 2", mem7[33], 32'h9ABC_DEF0);
	chk("the ARM9 did not serve it", hits9, h9_before);
	slow7 = 0;
	repeat (2) @(posedge clk);

	//==================== 8. the outputs ====================
	$display("  -- status");
	chk("busy is clear when idle", busy, 0);
	chk("never two masters on the engine", both_bus, 0);

	$display("  %0d checks, %0d failure(s)", checks, errors);
	if (errors == 0) $display("TB SWI_SHARE PASS");
	else             $display("TB SWI_SHARE FAIL");
	$finish;
end

// a call must never be dropped on the floor: if the sim runs long, say so
initial begin
	#4000000;
	$display("  FAIL the bench timed out (checks = %0d)", checks);
	$display("TB SWI_SHARE FAIL");
	$finish;
end

endmodule
