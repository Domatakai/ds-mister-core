//============================================================================
// tb_sdram_ctrl — SDRAM controller against a protocol-checking chip model
//
//   iverilog -g2012 -o /tmp/tb_sd tb/tb_sdram_ctrl.sv \
//            rtl/mem/sdram_ctrl.sv tb/sdram_model.sv && vvp /tmp/tb_sd
//
// sdram_ctrl had no bench of its own: every memory test in the repo stops
// at mem_arbiter, so the controller's command sequences were never checked
// against a device. This bench drives it exactly the way mem_arbiter does
// (a one-cycle request pulse, one done pulse back) and puts a strict
// SDRAM device model behind it that fails on real protocol violations:
//
//   * ACTIVE to a new row without precharging the open one
//   * READ/WRITE with the bank precharged, or inside tRCD
//   * AUTO REFRESH with a row still open
//
// Checks:
//   1. init completes: precharge, two refreshes, mode register, no errors
//   2. write + read back through open-row reuse (one ACTIVE for both)
//   3. a sequential read run stays inside one open row (still one ACTIVE)
//      and is measurably faster than the same count of row-crossing reads
//   4. a read in another row precharges first (PRE before ACT, no error)
//   5. byte-mask writes leave the masked byte alone
//   6. idle time refreshes without leaving rows open
//   7. a linear read burst of 64 halfwords returns every beat in address
//      order and costs about a clock each in an open row, not the ~9 of the
//      single-access path
//   8. a burst that walks into a bank whose other row is open precharges and
//      re-activates inside the burst, and still returns every beat
//============================================================================
`timescale 1ns/1ps

module tb_sdram_ctrl;

reg clk = 0;
always #10 clk = ~clk;   // 50 MHz

reg reset = 1;

reg  [24:0] addr = 0;
reg  [15:0] din = 0;
reg  [1:0]  be = 2'b11;
reg         rd = 0, wr = 0;
reg         rd_bst = 0;
reg  [7:0]  bst_len = 0;
reg   [1:0] bst_step = 1;   // 1 = linear; the 3D frame fetch uses 2
wire [15:0] dout;
wire        rd_done, wr_done;
wire [15:0] bst_data;
wire        bst_valid, bst_done;

wire [12:0] SDRAM_A;
wire  [1:0] SDRAM_BA;
wire [15:0] SDRAM_DQ;
wire        SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH;
wire        SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE;

sdram_ctrl dut (
	.clk(clk),
	.reset(reset),
	.addr(addr),
	.din(din),
	.be(be),
	.rd(rd),
	.wr(wr),
	.rd_bst(rd_bst),
	.bst_len(bst_len),
	.bst_step(bst_step),
	.dout(dout),
	.rd_done(rd_done),
	.wr_done(wr_done),
	.bst_valid(bst_valid),
	.bst_data(bst_data),
	.bst_done(bst_done),
	.SDRAM_CLK(SDRAM_CLK),
	.SDRAM_CKE(SDRAM_CKE),
	.SDRAM_A(SDRAM_A),
	.SDRAM_BA(SDRAM_BA),
	.SDRAM_DQ(SDRAM_DQ),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nWE(SDRAM_nWE)
);

sdram_model chip (
	.sclk(SDRAM_CLK),
	.a(SDRAM_A),
	.ba(SDRAM_BA),
	.dq(SDRAM_DQ),
	.dqm({SDRAM_DQMH, SDRAM_DQML}),
	.op({SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE}),
	.cke(SDRAM_CKE)
);

//------------------------------------------------------------------ helpers
integer errors = 0;
integer i, guard, t0;

task check(input ok, input [8*56:1] what);
	begin
		if (!ok) begin
			errors = errors + 1;
			$display("FAIL %0s (time %0t)", what, $time);
		end else begin
			$display("ok   %0s", what);
		end
	end
endtask

// addr[8:0] column, addr[10:9] bank, addr[23:11] row
function [24:0] adr;
	input [1:0]  bank;
	input [12:0] row;
	input [8:0]  col;
	begin
		adr = {row, bank, col};
	end
endfunction

// one-cycle request pulse, then wait for the matching done pulse
task req_rd(input [24:0] a, output [15:0] data);
	begin
		@(posedge clk);
		addr <= a; rd <= 1; wr <= 0;
		@(posedge clk);
		rd <= 0;
		guard = 0;
		while (!rd_done && guard < 200) begin
			@(posedge clk);
			guard = guard + 1;
		end
		if (!rd_done) begin
			errors = errors + 1;
			$display("FAIL read never completed (addr %h)", a);
		end
		#1 data = dout;
	end
endtask

task req_wr(input [24:0] a, input [15:0] d, input [1:0] b);
	begin
		@(posedge clk);
		addr <= a; din <= d; be <= b; wr <= 1; rd <= 0;
		@(posedge clk);
		wr <= 0;
		guard = 0;
		while (!wr_done && guard < 200) begin
			@(posedge clk);
			guard = guard + 1;
		end
		if (!wr_done) begin
			errors = errors + 1;
			$display("FAIL write never completed (addr %h)", a);
		end
	end
endtask

reg [15:0] v, v2;
integer    seq_cycles, cross_cycles;   // clocks for 8 reads each way
integer    act_before, pre_before;
integer    bst_beats, bst_cyc;

//------------------------------------------------------------------ bursts
// Fill the device with a known pattern: halfword n of a range reads back as
// (n ^ 0x5A5A), so a burst that loses, repeats or reorders a beat fails.
integer k2;
reg [24:0] p2;

task fill(input [24:0] base, input integer n);
	begin
		for (k2 = 0; k2 < n; k2 = k2 + 1) begin
			p2 = base + k2;
			chip.poke(p2[10:9], p2[23:11], p2[8:0], p2[15:0] ^ 16'h5A5A);
		end
	end
endtask

// Issue a burst and check every beat against the pattern. Returns how many
// beats arrived and how many clocks the whole thing took.
task burst(input [24:0] base, input [7:0] len,
           output integer beats, output integer cyc);
	begin
		burst_step(base, len, beats, cyc, 2'd1);
	end
endtask

task burst_step(input [24:0] base, input [7:0] len,
                output integer beats, output integer cyc, input [1:0] step);
	reg [15:0] want;
	reg [24:0] ea;
	integer    n, stray;
	begin
		@(posedge clk);
		addr <= base; bst_len <= len; bst_step <= step;
		rd_bst <= 1; rd <= 0; wr <= 0;
		@(posedge clk);
		rd_bst <= 0;
		beats = 0;
		cyc   = 0;
		guard = 0;
		while (beats < len && guard < 2000) begin
			@(posedge clk);
			#1;
			cyc = cyc + 1;
			if (bst_valid) begin
				n    = beats;
				ea   = base + n[24:0] * {{24{1'b0}}, step};
				want = ea[15:0] ^ 16'h5A5A;
				if (bst_data !== want) begin
					errors = errors + 1;
					$display("FAIL burst beat %0d: got %h expected %h",
					         n, bst_data, want);
				end
				beats = beats + 1;
			end
			guard = guard + 1;
		end
		check(beats == len, "burst returned every beat it was asked for");
		if (beats >= len) begin
			// done follows a couple of clocks behind the last beat
			guard = 0;
			while (!bst_done && guard < 16) begin
				@(posedge clk); #1;
				guard = guard + 1;
			end
			check(bst_done, "burst raised done after the last beat");
			stray = 0;
			for (k2 = 0; k2 < 4; k2 = k2 + 1) begin
				@(posedge clk); #1;
				if (bst_valid) stray = stray + 1;
			end
			check(stray == 0, "no beats after the burst completed");
		end
	end
endtask

//------------------------------------------------------------------ stimulus
initial begin
	chip.clear();
	repeat (4) @(negedge clk);
	reset = 1'b0;

	// 1 — initialisation
	guard = 0;
	while (chip.n_lmr == 0 && guard < 8000) begin
		@(posedge clk);
		guard = guard + 1;
	end
	repeat (10) @(posedge clk);
	check(chip.n_lmr >= 1, "mode register written during init");
	check(chip.n_ref >= 2, "two auto-refreshes during init");
	check(chip.errs == 0, "init left no protocol violation");

	// 2 — write then read the same halfword: one ACTIVE for both
	req_wr(adr(2'd0, 13'd0, 9'd5), 16'hBEEF, 2'b11);
	check(chip.n_write == 1, "write accepted once");
	check(chip.n_act == 1, "write activated the row once");
	req_rd(adr(2'd0, 13'd0, 9'd5), v);
	check(v === 16'hBEEF, "read returns the halfword just written");
	check(chip.n_act == 1, "read reused the open row (still one ACTIVE)");

	// 3 — sequential run inside the row: no ACTIVE per read, and measurably
	//     faster than the same number of reads that each reopen a row.
	//     A refresh during the run legitimately closes and reopens the row,
	//     so one extra ACTIVE is allowed; more than that means the reuse is
	//     not working.
	act_before = chip.n_act;
	t0 = $time / 20;
	for (i = 0; i < 8; i = i + 1) begin
		req_rd(adr(2'd0, 13'd0, 9'd20 + i[8:0]), v);
		if (v !== 16'h0000) begin
			errors = errors + 1;
			$display("FAIL sequential read %0d returned %h", i, v);
		end
	end
	seq_cycles = ($time / 20) - t0;
	$display("  \"ACTIVEs during the sequential run: %0d (refreshes so far %0d)",
	         chip.n_act - act_before, chip.n_ref);
	check(chip.n_act - act_before <= 1, "8 sequential reads needed at most one ACTIVE");
	check(chip.n_read == 9, "9 reads issued so far");

	t0 = $time / 20;
	for (i = 0; i < 8; i = i + 1)
		req_rd(adr(2'd0, 13'd4 + i[12:0], 9'd0), v2);
	cross_cycles = ($time / 20) - t0;
	check(chip.errs == 0, "row-crossing reads left no protocol violation");
	$display("  8 same-row reads: %0d clocks; 8 row-crossing reads: %0d clocks",
	         seq_cycles, cross_cycles);
	check(seq_cycles < cross_cycles, "open-row reuse is faster than reopening the row");

	// 4 — a different row in the same bank must precharge the open row
	t0 = $time / 20;
	req_rd(adr(2'd0, 13'd1, 9'd5), v);
	check(chip.n_pre >= 1, "row crossing precharged the old row");
	check(chip.errs == 0, "row crossing left no protocol violation");
	$display("  one row-crossing read: %0d clocks", ($time / 20) - t0);

	// 5 — byte masks: only the unmasked byte changes
	chip.poke(2'd0, 13'd1, 9'd40, 16'h1234);
	req_wr(adr(2'd0, 13'd1, 9'd40), 16'hFF00, 2'b10);   // high byte only
	req_rd(adr(2'd0, 13'd1, 9'd40), v);
	check(v === 16'hFF34, "masked write keeps the low byte");
	req_wr(adr(2'd0, 13'd1, 9'd40), 16'h0000, 2'b01);   // low byte only
	req_rd(adr(2'd0, 13'd1, 9'd40), v);
	check(v === 16'hFF00, "masked write keeps the high byte");

	// 6 — idle refreshes must not run with a row open
	t0 = chip.n_ref;
	repeat (1200) @(posedge clk);
	check(chip.n_ref > t0, "refresh ran while idle");
	check(chip.errs == 0, "no protocol violation across the whole run");

	// 7 — a burst inside one row: 64 halfwords for about 64 clocks
	fill(adr(2'd0, 13'd5, 9'd200), 64);
	act_before = chip.n_act;
	burst(adr(2'd0, 13'd5, 9'd200), 8'd64, bst_beats, bst_cyc);
	$display("  64-halfword burst in an open row: %0d clocks (%0d ACTIVE)",
	         bst_cyc, chip.n_act - act_before);
	check(chip.n_act - act_before <= 1, "burst needed at most one ACTIVE");
	check(bst_cyc < 64 * 4, "burst streams at close to one halfword per clock");
	check(chip.errs == 0, "burst left no protocol violation");

	// 8 — a burst that walks out of its row and into a bank whose other row
	//     is open: the controller must precharge and re-activate mid-burst.
	//     Opening bank 1 row 3 first is what makes the precharge necessary.
	req_rd(adr(2'd1, 13'd3, 9'd0), v);
	fill(adr(2'd0, 13'd5, 9'd480), 64);   // 480 + 64 wraps into bank 1, row 5
	req_wr(adr(2'd0, 13'd5, 9'd1), 16'h1234, 2'b11);   // row 5 back in bank 0
	act_before = chip.n_act;
	pre_before = chip.n_pre;
	burst(adr(2'd0, 13'd5, 9'd480), 8'd64, bst_beats, bst_cyc);
	$display("  64-halfword burst across a bank/row change: %0d clocks (%0d ACTIVE, %0d PRE)",
	         bst_cyc, chip.n_act - act_before, chip.n_pre - pre_before);
	// bank 0 row 5 was already open, so the walk into bank 1 needs the
	// precharge and the re-activate, not a new activate for the start
	check(chip.n_act - act_before >= 1, "row-crossing burst re-activated");
	check(chip.n_pre - pre_before >= 1, "row-crossing burst precharged the other row");
	check(chip.errs == 0, "row-crossing burst left no protocol violation");

	// 9 — a one-halfword burst behaves like a single read
	fill(adr(2'd2, 13'd1, 9'd9), 1);
	burst(adr(2'd2, 13'd1, 9'd9), 8'd1, bst_beats, bst_cyc);
	check(chip.errs == 0, "one-beat burst left no protocol violation");

	// 10 — a strided burst (the 3D frame fetch: every other halfword) reads
	//      the pixels and skips the gap halfword, still one beat per clock
	fill(adr(2'd3, 13'd2, 9'd0), 129);
	act_before = chip.n_act;
	burst_step(adr(2'd3, 13'd2, 9'd0), 8'd64, bst_beats, bst_cyc, 2'd2);
	$display("  64-beat strided burst: %0d clocks (%0d ACTIVE)",
	         bst_cyc, chip.n_act - act_before);
	check(bst_cyc < 64 * 4, "a strided burst also streams one beat per clock");
	check(chip.errs == 0, "strided burst left no protocol violation");

	if (chip.errs != 0) errors = errors + 1;
	if (errors == 0) $display("tb_sdram_ctrl: PASS");
	else             $display("tb_sdram_ctrl: FAIL (%0d errors)", errors);
	$finish;
end

initial begin
	#5_000_000;
	$display("tb_sdram_ctrl: FAIL (timeout)");
	$finish;
end

endmodule
