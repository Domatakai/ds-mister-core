//============================================================================
// NDS MiSTer Test — CPU clock-enable ratio bench
//
//   iverilog -g2012 -o /tmp/tb_clk tb/tb_cpu_clk.sv \
//            rtl/cpu/arm9_core.sv rtl/cpu/arm7_core.sv rtl/cpu/cpu_ce.sv \
//            rtl/cpu/cpu_ce_bridge.sv rtl/bus/main_bus.sv \
//            rtl/mem/mem_arbiter.sv, rtl/cart/cheat_engine.sv, ...
//   vvp /tmp/tb_clk
//
// The DS runs the ARM9 at 67.0274 MHz and the ARM7 at 33.5137 MHz: a 2:1
// clock ratio. `cpu_ce` produces it as a pattern of enables on this core's
// single clk_sys domain, and `cpu_ce_bridge` is what makes a gated core able
// to use the bus at all (main_bus answers a master once and blocks it until it
// retires the access, so a response landing on a gated-off cycle would hang it
// for good).
//
// This bench checks both halves of that, against the REAL fabric — `main_bus`,
// `mem_arbiter` and an SDRAM device model, the same path a game's fetch takes:
//
//   1. the pattern itself: over a window of clk_sys cycles, the ARM9's enable
//      is high twice as often as the ARM7's (Normal), equally often (ARM7 x2)
//      and half as often (ARM7 x4)
//   2. what the pattern does: the same program — assembled once, loaded twice,
//      only its data-base literal differing — runs on both cores and on every
//      mode, and each run must produce the same sums and read them back through
//      main RAM (a missed bus response is a hang, not a wrong answer, so
//      reaching the marker at all is the test)
//   3. that the ARM7 really is the slower core: gating its enable makes its run
//      take longer than the ARM7 x2 mode, and the ARM7 spends twice as many
//      clk_sys cycles as it does enabled cycles
//
// What this bench does *not* claim: that the ARM7 takes twice as long as the
// ARM9 end to end on this program. Its own cycles are twice as long, but the
// memory it waits on is clocked at the ARM9's rate (as the DS's is), so a
// bus-bound run gains less than 2x. The measured ratio is printed, not
// asserted away.
//============================================================================
`timescale 1ns / 1ps

module tb_cpu_clk;

localparam integer WINDOW = 1024;      // enable-pattern window, in clk_sys cycles

reg clk = 0;
always #7.4599 clk = ~clk;             // 67.0274 MHz, the clock the core runs on

reg        reset9 = 1;    // the two cores are parked independently, so one can
reg        reset7 = 1;    // run alone (the other is held down, not fetching)
reg        bus_reset = 1; // the fabric's own reset, released for every run
reg  [1:0] mode = 2'd0;

wire       ce9, ce7;

integer errors = 0;
integer checks = 0;

//------------------------------------------------------------------
// the bench's program
//------------------------------------------------------------------
reg [15:0] ram [0:32767];
integer li;
`include "tb_clk_prog.svh"

//------------------------------------------------------------------
// clock enables
//------------------------------------------------------------------
cpu_ce u_ce (
	.clk(clk), .mode(mode),
	.ce9(ce9), .ce7(ce7)
);

//------------------------------------------------------------------
// the two cores, each behind its enable-aware bus bridge
//------------------------------------------------------------------
wire [31:0] c9_addr, c9_wdata, c9_rdata;
wire [31:0] c7_addr, c7_wdata, c7_rdata;
wire  [3:0] c9_be, c7_be;
wire        c9_rd, c9_wr, c9_ready;
wire        c7_rd, c7_wr, c7_ready;
wire        c9_halted, c9_thumb, c7_halted, c7_thumb;
wire [31:0] pc9, pc7;

wire [31:0] m9_addr, m9_wdata, m9_rdata;
wire [31:0] m7_addr, m7_wdata, m7_rdata;
wire  [3:0] m9_be, m7_be;
wire        m9_rd, m9_wr, m9_ready;
wire        m7_rd, m7_wr, m7_ready;

arm9_core u9 (
	.clk(clk), .reset(reset9), .ce(ce9),
	.boot_pc(CLK_PROG9), .boot_sp(32'h0200_3000),
	.bus_addr(c9_addr), .bus_wdata(c9_wdata), .bus_be(c9_be),
	.bus_rd(c9_rd), .bus_wr(c9_wr),
	.bus_rdata(c9_rdata), .bus_ready(c9_ready),
	.irq(1'b0), .fiq(1'b0), .halt(1'b0),
	.halted(c9_halted), .thumb_state(c9_thumb), .pc_out(pc9)
);

cpu_ce_bridge b9 (
	.clk(clk), .ce(ce9),
	.core_addr(c9_addr), .core_wdata(c9_wdata), .core_be(c9_be),
	.core_rd(c9_rd), .core_wr(c9_wr),
	.core_rdata(c9_rdata), .core_ready(c9_ready),
	.bus_addr(m9_addr), .bus_wdata(m9_wdata), .bus_be(m9_be),
	.bus_rd(m9_rd), .bus_wr(m9_wr),
	.bus_rdata(m9_rdata), .bus_ready(m9_ready)
);

arm7_core u7 (
	.clk(clk), .reset(reset7), .ce(ce7),
	.boot_pc(CLK_PROG7), .boot_sp(32'h0200_3800),
	.bus_addr(c7_addr), .bus_wdata(c7_wdata), .bus_be(c7_be),
	.bus_rd(c7_rd), .bus_wr(c7_wr),
	.bus_rdata(c7_rdata), .bus_ready(c7_ready),
	.irq(1'b0), .fiq(1'b0), .halt(1'b0),
	.halted(c7_halted), .thumb_state(c7_thumb), .pc_out(pc7)
);

cpu_ce_bridge b7 (
	.clk(clk), .ce(ce7),
	.core_addr(c7_addr), .core_wdata(c7_wdata), .core_be(c7_be),
	.core_rd(c7_rd), .core_wr(c7_wr),
	.core_rdata(c7_rdata), .core_ready(c7_ready),
	.bus_addr(m7_addr), .bus_wdata(m7_wdata), .bus_be(m7_be),
	.bus_rd(m7_rd), .bus_wr(m7_wr),
	.bus_rdata(m7_rdata), .bus_ready(m7_ready)
);

//------------------------------------------------------------------
// the real bus, both CPUs on it, everything else tied off
//------------------------------------------------------------------
wire        bus_ram_req, bus_ram_wr, bus_ram_done;
wire [24:0] bus_ram_addr;
wire [15:0] bus_ram_wdata;
wire  [1:0] bus_ram_be;
wire        arb_req, arb_wr;
wire [24:0] arb_addr;
wire [15:0] arb_wdata;
wire  [1:0] arb_be;
wire        arb_rd_done, arb_wr_done;
wire [15:0] arb_rdata;

main_bus dut (
	.clk(clk), .reset(bus_reset),
	.ce7(ce7),
	.ds_keys(12'hFFF), .lang(3'd0), .hinge_closed(1'b0),
	.touch_x(9'd0), .touch_y(8'd0), .touch_down(1'b0), .mic_in(1'b0),
	.m9_addr(m9_addr), .m9_wdata(m9_wdata), .m9_be(m9_be),
	.m9_rd(m9_rd), .m9_wr(m9_wr), .m9_ready(m9_ready), .m9_rdata(m9_rdata),
	.m7_addr(m7_addr), .m7_wdata(m7_wdata), .m7_be(m7_be),
	.m7_rd(m7_rd), .m7_wr(m7_wr), .m7_ready(m7_ready), .m7_rdata(m7_rdata),
	.cart_req(), .cart_addr(), .cart_valid(1'b0), .cart_rdata(16'd0),
	.ram_req(bus_ram_req), .ram_wr(bus_ram_wr), .ram_addr(bus_ram_addr),
	.ram_wdata(bus_ram_wdata), .ram_be(bus_ram_be),
	.ram_done(bus_ram_done), .ram_rdata(arb_rdata),
	.vramcnt_we(), .vramcnt_addr(), .vramcnt_data(),
	.vram_valid(1'b0), .vram_rdata(16'd0),
	.dma_reg_rdata(16'd0),
	.d_addr(32'd0), .d_wdata(32'd0), .d_be(4'd0),
	.d_rd(1'b0), .d_wr(1'b0), .dma_irq(4'd0),
	.pal_ra_a(10'd0), .pal_ra_b(10'd0),
	.oam_ra_a(10'd0), .oam_ra_b(10'd0),
	.cheat_chk_en(), .cheat_chk_addr(), .cheat_chk_word(),
	.cheat_patch(16'd0), .cheat_patch_hi_en(1'b0), .cheat_patch_hi(16'd0),
	.cheat_hit(1'b0), .cheat_ready(1'b1),
	.gx_we(), .gx_addr(), .gx_data(), .gx_rdata(32'h0100_0000),
	.midi_wr(), .midi_rd(),
	.midi_addr(), .midi_wdata(), .midi_rdata(16'd0),
	.spu_acc(), .spu_we(), .spu_addr(), .spu_wdata(), .spu_rdata(16'd0),
	.dispcnt_a(), .dispcnt_b(), .irq_master_enable(),
	.irq_enable(), .irq_flags()
);

mem_arbiter arbiter (
	.clk(clk), .reset(bus_reset),
	.bus_req(bus_ram_req), .bus_wr(bus_ram_wr), .bus_addr(bus_ram_addr),
	.bus_wdata(bus_ram_wdata), .bus_be(bus_ram_be), .bus_ready(bus_ram_done),
	.save_req(1'b0), .save_wr(1'b0), .save_addr(25'd0),
	.save_wdata(16'd0), .save_be(2'b00), .save_ready(),
	.vram_req(1'b0), .vram_wr(1'b0), .vram_addr(25'd0),
	.vram_wdata(16'd0), .vram_be(2'b00), .vram_ready(),
	.sdram_req(arb_req), .sdram_wr(arb_wr), .sdram_addr(arb_addr),
	.sdram_wdata(arb_wdata), .sdram_be(arb_be),
	.sdram_rd_done(arb_rd_done), .sdram_wr_done(arb_wr_done),
	.sdram_rdata(arb_rdata)
);

// behavioural SDRAM device: one-cycle accept, byte-masked writes
reg [15:0] sd_dout = 16'd0;
reg        sd_rd_done = 0, sd_wr_done = 0;

always @(posedge clk) begin : sdram_device
	reg [15:0] t;
	sd_rd_done <= 0;
	sd_wr_done <= 0;
	if (arb_req && !arb_wr) begin
		sd_dout    <= ram[arb_addr[14:0]];
		sd_rd_done <= 1;
	end else if (arb_req && arb_wr) begin
		t = ram[arb_addr[14:0]];
		if (arb_be[0]) t[7:0]  = arb_wdata[7:0];
		if (arb_be[1]) t[15:8] = arb_wdata[15:8];
		ram[arb_addr[14:0]] <= t;
		sd_wr_done <= 1;
	end
end

assign arb_rdata = sd_dout;
assign arb_rd_done = sd_rd_done;
assign arb_wr_done = sd_wr_done;

//------------------------------------------------------------------
// checks
//------------------------------------------------------------------
// bus trace, for diagnosing a stuck run (+trace): it is what found the bus's
// block-clear bug — a served master that re-requests immediately never left the
// bus an idle cycle to notice the strobe had dropped, so it stayed blocked
reg trace_on = 0;
integer trace_left = 0;

always @(posedge clk) begin
	if (trace_on && trace_left > 0) begin
		trace_left = trace_left - 1;
		$display("    %5d st=%0d act=%b%b%b blk=%b%b req=%b%b rdy=%b%b rdat=%h pc9=%h pc7=%h",
		         $time / 20, dut.state, dut.m9_active, dut.m7_active, dut.d_active,
		         dut.m9_block, dut.m7_block, m9_rd, m7_rd, m9_ready, m7_ready,
		         m9_rdata, pc9, pc7);
	end
end

task check(input ok, input [8*56-1:0] what);
	begin
		checks = checks + 1;
		if (!ok) begin
			errors = errors + 1;
			$display("  FAIL %0s", what);
		end
	end
endtask

task check_word(input [31:0] addr, input [31:0] want, input [8*56-1:0] what);
	begin
		checks = checks + 1;
		if ({ram[16'h1 + (addr - 32'h0200_0000) / 2],
		     ram[16'h0 + (addr - 32'h0200_0000) / 2]} !== want) begin
			errors = errors + 1;
			$display("  FAIL %0s: %h = %h, expected %h", what, addr,
			         {ram[(addr - 32'h0200_0000) / 2 + 1],
			          ram[(addr - 32'h0200_0000) / 2]}, want);
		end
	end
endtask

//------------------------------------------------------------------
// a run: reset both cores, release the ones in use, count clk_sys cycles and
// each core's enabled cycles until its marker
//------------------------------------------------------------------
integer c9, e9, c7, e7, guard;
reg     d9, d7;

task run(input [1:0] md, input use9, input use7);
	begin
		mode      = md;
		bus_reset = 1'b1;
		reset9    = 1'b1;
		reset7    = 1'b1;
		repeat (8) @(posedge clk);
		bus_reset = 1'b0;
		reset9    = use9 ? 1'b0 : 1'b1;
		reset7    = use7 ? 1'b0 : 1'b1;
		c9 = 0; e9 = 0; c7 = 0; e7 = 0;
		d9 = ~use9;
		d7 = ~use7;
		guard = 0;
		while (!(d9 && d7) && guard < 200000) begin
			@(posedge clk);
			guard = guard + 1;
			if (!d9) begin
				c9 = c9 + 1;
				if (ce9) e9 = e9 + 1;
				if (pc9 === CLK_MARK9) d9 = 1'b1;
			end
			if (!d7) begin
				c7 = c7 + 1;
				if (ce7) e7 = e7 + 1;
				if (pc7 === CLK_MARK7) d7 = 1'b1;
			end
		end
		if (!(d9 && d7)) begin
			$display("    stuck: pc9=%h pc7=%h bus state=%0d m9_rd=%b m9_rdy=%b blk=%b | m7_rd=%b m7_rdy=%b blk=%b",
			         pc9, pc7, dut.state, m9_rd, m9_ready, dut.m9_block,
			         m7_rd, m7_ready, dut.m7_block);
		end
		check(d9 && d7, "both cores reached their marker");
		// let the last store drain before the caller looks at memory: a core's
		// pc is already past an instruction's address while that instruction is
		// still in its bus transaction
		repeat (16) @(posedge clk);
	end
endtask

// measure the enable pattern over a quiet window (both cores held in reset)
integer w9, w7, k;
task window(input [1:0] md, output integer n9, output integer n7);
	begin
		mode   = md;
		bus_reset = 1'b0;
		reset9 = 1'b1;
		reset7 = 1'b1;
		repeat (8) @(posedge clk);
		n9 = 0; n7 = 0;
		for (k = 0; k < WINDOW; k = k + 1) begin
			@(posedge clk);
			if (ce9) n9 = n9 + 1;
			if (ce7) n7 = n7 + 1;
		end
	end
endtask

integer n9, n7;
integer r9, r7;        // the ARM9's and ARM7's run times, per mode
integer q9, q7;        // and their enabled-cycle counts
integer i;

// clear both result words, so a run that never stores cannot pass by finding
// the previous run's numbers still there
task wipe;
	begin
		for (i = 0; i < 4; i = i + 1)
			ram[(CLK_DATA9 - 32'h0200_0000) / 2 + i] = 16'h0000;
		for (i = 0; i < 4; i = i + 1)
			ram[(CLK_DATA7 - 32'h0200_0000) / 2 + i] = 16'h0000;
	end
endtask

initial begin
	for (li = 0; li < 32768; li = li + 1) ram[li] = 16'h0000;
	load_p9;
	load_p7;

	// ---- 1. the pattern itself ----
	window(2'd0, n9, n7);
	$display("  Normal   : ARM9 %0d/%0d enabled, ARM7 %0d/%0d (%.2f:1)",
	         n9, WINDOW, n7, WINDOW, (n7 == 0) ? 0.0 : n9 * 1.0 / n7);
	check(n9 == WINDOW && n7 == WINDOW / 2,
	      "Normal gives the ARM9 every cycle and the ARM7 every second one");

	window(2'd1, n9, n7);
	check(n9 == WINDOW && n7 == WINDOW, "ARM7 x2 gives both cores every cycle");

	window(2'd2, n9, n7);
	$display("  ARM7 x4  : ARM9 %0d/%0d enabled, ARM7 %0d/%0d",
	         n9, WINDOW, n7, WINDOW);
	check(n9 == WINDOW / 2 && n7 == WINDOW,
	      "ARM7 x4 gives the ARM9 every second cycle and the ARM7 every one");

	// ---- 2. each core alone, running the same program ----
	$display("");
	wipe;
	run(2'd0, 1'b1, 1'b0);
	r9 = c9; q9 = e9;
	$display("  Normal   : ARM9 alone: %0d cycles, %0d enabled (%.2f clk_sys per instruction)",
	         c9, e9, c9 * 1.0 / CLK_STEPS);
	check(c9 == e9, "the ARM9 runs on every cycle in Normal");
	check_word(CLK_DATA9, CLK_SUM, "ARM9 store reached main RAM");
	check_word(CLK_DATA9 + 4, CLK_SUM + 1, "ARM9 load/store round trip");

	wipe;
	run(2'd0, 1'b0, 1'b1);
	r7 = c7; q7 = e7;
	$display("  Normal   : ARM7 alone: %0d cycles, %0d enabled (%.2f clk_sys, %.2f own cycles per instruction)",
	         c7, e7, c7 * 1.0 / CLK_STEPS, e7 * 1.0 / CLK_STEPS);
	check(c7 >= 2 * e7 - 1 && c7 <= 2 * e7 + 1,
	      "the ARM7's clock is half the ARM9's: two clk_sys cycles per own cycle");
	check(c7 > r9, "the ARM7 takes longer than the ARM9 on the same program");
	// but the shared memory path is not slowed for it: GBATEK times the DS's
	// memory in 33.5 MHz bus units, which both CPUs pay the same wall clock
	// (a 32-bit main-RAM data access is 10 units, i.e. 10 ARM7 cycles or 20
	// ARM9 cycles, for the same 298 ns). A gate that doubled the ARM7's memory
	// latency as well would show up here as ~2x.
	check(c7 < r9 + r9 / 4, "the ARM7's memory access is not slowed, only its clock");
	// The same shared work, counted on a clock that is twice as long: what the
	// ARM7 waits for costs it half as many of its own cycles as the ARM9
	// spends clk_sys cycles waiting, and only its *own* execution is at half
	// rate. That is the shape the DS's timing table has.
	check(q7 > q9 / 3 && q7 < q9 * 2 / 3,
	      "the ARM7 spends about half as many of its own cycles on the same work");
	check_word(CLK_DATA7, CLK_SUM, "ARM7 store reached main RAM");
	check_word(CLK_DATA7 + 4, CLK_SUM + 1, "ARM7 load/store round trip");
	$display("  Normal   : ARM7/ARM9 end to end = %.2fx on this program",
	         c7 * 1.0 / r9);

	wipe;
	run(2'd1, 1'b0, 1'b1);
	$display("  ARM7 x2  : ARM7 alone: %0d cycles, %0d enabled", c7, e7);
	check(c7 < r7, "ARM7 x2 is faster than Normal: the enable really gates the core");
	check_word(CLK_DATA7, CLK_SUM, "ARM7 x2 result reached main RAM");

	wipe;
	run(2'd2, 1'b1, 1'b0);
	$display("  ARM7 x4  : ARM9 alone: %0d cycles, %0d enabled", c9, e9);
	check(c9 > r9, "ARM7 x4 slows the ARM9: the same 2:1 pattern, the other way");
	check_word(CLK_DATA9, CLK_SUM, "ARM7 x4 result reached main RAM");

	// both cores at once, contending for the bus: neither may hang, and both
	// must still get their results through
	wipe;
	trace_on = $test$plusargs("trace");
	trace_left = 400;
	run(2'd0, 1'b1, 1'b1);
	trace_on = 0;
	$display("  Normal   : both     : ARM9 %0d cycles (%0d enabled), ARM7 %0d (%0d)",
	         c9, e9, c7, e7);
	check_word(CLK_DATA9, CLK_SUM, "ARM9 result with both cores running");
	check_word(CLK_DATA7, CLK_SUM, "ARM7 result with both cores running");

	$display("");
	$display("  %0d checks, %0d failure(s)", checks, errors);
	if (errors == 0) $display("TB CPUCLK PASS");
	else             $display("TB CPUCLK FAIL");
	$finish;
end

endmodule
