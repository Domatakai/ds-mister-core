//============================================================================
// NDS MiSTer Test — CPU-domain clocking of the system I/O
//
//   iverilog -g2012 -o /tmp/tb_sclk tb/tb_sys_clk.sv \
//            rtl/bus/sys_io.sv rtl/bus/nds_timers.sv rtl/bus/ipc.sv \
//            rtl/bus/math_unit.sv rtl/bus/nds_rtc.sv rtl/bus/spi.sv \
//            rtl/bus/fw_default.sv rtl/cpu/cpu_ce.sv
//   vvp /tmp/tb_sclk
//
// The timers are a divider of the clock the ARM7 runs on — GBATEK, *DS
// Timers*: "F = 33.513982 MHz (for both NDS9 and NDS7)" — so they are ticked
// from the ARM7's clock enable rather than from a timebase of their own. That
// is what makes the OSD's CPU overclock row scale them with the CPU it scales,
// and what gives both CPUs the ratio to the timer the hardware has.
//
// The RTC is the exception, and it is the reason this bench exists as its own
// file: the S-35180 counts its own crystal, so its one-second divider is fed
// from a free-running reference and must *not* move with the CPU domain.
//
// Checks:
//   1. Normal — one timer count per ARM7 enable, and the ARM7's enable is half
//      the clocks (2000 clocks -> 1000 counts, exactly)
//   2. ARM7 x2 — the same program counts twice as fast, because the ARM7 does
//   3. ARM7 x4 — the ARM9's own timer set counts on the ARM7's enable too
//      (both sets are 33.513982 MHz on hardware, so both follow that clock)
//   4. the prescaler divides those ticks, not clocks
//   5. the RTC's one-second divider counts its own reference: over the same
//      window it advances by the reference pulses and by nothing else
//   6. the overflow IRQ lands after exactly the reload's worth of ARM7 cycles
//============================================================================
`timescale 1ns / 1ps

module tb_sys_clk;

	reg clk = 0;
	always #7.4599 clk = ~clk;      // 67.0274 MHz clk_sys (the PLL output)

	reg  [1:0] mode = 2'd0;
	wire       ce9, ce7;

	cpu_ce u_ce (
		.clk(clk), .mode(mode),
		.ce9(ce9), .ce7(ce7)
	);

	reg         reset = 1;
	reg         cpu9 = 1'b1;
	reg  [15:0] addr = 16'h0000;
	reg         acc = 1'b0, we = 1'b0;
	reg  [15:0] wdata = 16'h0000;
	reg  [31:0] wdata32 = 32'h0000_0000;
	wire [15:0] rdata;
	wire [31:0] recv_rdata;
	wire [31:0] ie9, if9, ie7, if7;
	wire        ime9, irq9, ime7, irq7, arm7_halt;

	// The RTC's own reference: one pulse every third clock, so it is a rate of
	// its own and cannot be mistaken for the ARM7's enable.
	reg  [1:0] refph = 2'd0;
	wire       tick33 = (refph == 2'd0);

	always @(posedge clk) refph <= refph + 2'd1;

	sys_io dut (
		.clk(clk), .reset(reset),
		.tick(ce7), .tick33(tick33),
		.cpu9(cpu9), .addr(addr), .acc(acc), .we(we),
		.wdata(wdata), .wdata32(wdata32), .rdata(rdata),
		.recv_hit(1'b0), .recv_rdata(recv_rdata),
		.touch_x(9'd0), .touch_y(8'd0), .touch_down(1'b0), .mic_in(12'h400),
		.lang(3'd0),
		.irq_src9(32'd0), .irq_src7(32'd0),
		.ie9(ie9), .if9(if9), .ime9(ime9), .irq9(irq9),
		.ie7(ie7), .if7(if7), .ime7(ime7), .irq7(irq7),
		.arm7_halt(arm7_halt)
	);

	integer errors = 0;
	integer checks = 0;

	task check(input ok, input [8*62-1:0] what);
		begin
			checks = checks + 1;
			if (!ok) begin
				errors = errors + 1;
				$display("  FAIL %0s", what);
			end
		end
	endtask

	// one halfword write into the register file, as the bus delivers it
	task wr(input nine, input [15:0] a, input [15:0] d);
		begin
			@(posedge clk);
			cpu9  = nine;
			addr  = a;
			wdata = d;
			we    = 1'b1;
			acc   = 1'b1;
			@(posedge clk);
			we    = 1'b0;
			acc   = 1'b0;
			@(posedge clk);
		end
	endtask

	// Run n clocks, counting the ARM7's enables and the reference pulses in the
	// same window. Sampling at the negedge reads the enable that gates the next
	// rising edge, so the counts line up with the counters the DUT updates.
	integer en7, en33;

	task run(input integer n);
		begin
			en7  = 0;
			en33 = 0;
			repeat (n) begin
				@(negedge clk);
				if (ce7)  en7  = en7 + 1;
				if (tick33) en33 = en33 + 1;
				@(posedge clk);
			end
		end
	endtask

	integer base, base9, delta, delta9, rtc_base, rtc_delta;

	initial begin
		repeat (4) @(posedge clk);
		reset = 1'b0;
		repeat (4) @(posedge clk);

		//--------------------------------------------------------------
		// 1. Normal: the timer counts the ARM7's clock
		//--------------------------------------------------------------
		mode = 2'd0;
		wr(1'b0, 16'h0100, 16'h0000);      // ARM7 timer 0 reload 0
		wr(1'b0, 16'h0102, 16'h0080);      // enable, prescaler /1
		base = dut.u_tmr7.cnt[0];
		run(2000);
		delta = dut.u_tmr7.cnt[0] - base;
		$display("  Normal  : %0d clocks -> %0d ARM7 enables, timer +%0d",
		         2000, en7, delta);
		check(delta == en7, "timer 0 advanced once per ARM7 enable");
		check(en7 == 1000, "Normal gives the ARM7 every second clock");
		// and not once per clock, which is the defect this retiming removed
		check(delta != 2000, "the timer is not counting clk_sys");

		//--------------------------------------------------------------
		// 2. ARM7 x2: the same timer, twice the rate
		//--------------------------------------------------------------
		mode = 2'd1;
		wr(1'b0, 16'h0100, 16'h0000);      // reload write also clears the count
		wr(1'b0, 16'h0102, 16'h0080);
		base = dut.u_tmr7.cnt[0];
		run(2000);
		delta = dut.u_tmr7.cnt[0] - base;
		$display("  ARM7 x2 : %0d clocks -> %0d ARM7 enables, timer +%0d",
		         2000, en7, delta);
		check(delta == en7 && en7 == 2000,
		      "ARM7 x2 doubles the timer with the CPU, not with the display");

		//--------------------------------------------------------------
		// 3. ARM7 x4: both timer sets follow the ARM7's clock
		//--------------------------------------------------------------
		// GBATEK gives the same 33.513982 MHz for the ARM9's timers, so they are
		// clocked by that clock too -- not by the ARM9's enable, which this mode
		// halves.
		// The counters are sampled just after programming, because the register
		// writes are clocks too and the timers run through them.
		mode = 2'd2;
		wr(1'b0, 16'h0100, 16'h0000);
		wr(1'b0, 16'h0102, 16'h0080);
		wr(1'b1, 16'h0100, 16'h0000);      // the ARM9's own timer 0
		wr(1'b1, 16'h0102, 16'h0080);
		base  = dut.u_tmr7.cnt[0];
		base9 = dut.u_tmr9.cnt[0];
		run(2000);
		delta  = dut.u_tmr7.cnt[0] - base;
		delta9 = dut.u_tmr9.cnt[0] - base9;
		$display("  ARM7 x4 : %0d ARM7 enables, ARM7 timer +%0d, ARM9 timer +%0d",
		         en7, delta, delta9);
		check(delta == en7, "the ARM7's timer still counts ARM7 cycles");
		check(delta9 == en7,
		      "the ARM9's timer set counts the same clock, as GBATEK says");
		check(delta9 != 1000,
		      "the ARM9's timers are not gated by the ARM9's own enable");

		//--------------------------------------------------------------
		// 4. the prescaler divides ticks, not clocks
		//--------------------------------------------------------------
		mode = 2'd0;
		wr(1'b1, 16'h0100, 16'h0000);
		wr(1'b1, 16'h0102, 16'h0081);      // enable, prescaler /64
		base = dut.u_tmr9.cnt[0];
		run(4096);
		delta = dut.u_tmr9.cnt[0] - base;
		$display("  /64     : %0d ARM7 enables -> timer +%0d", en7, delta);
		check(delta == en7 / 64, "the /64 prescaler divides the ARM7's ticks");

		//--------------------------------------------------------------
		// 5. the RTC keeps its own crystal
		//--------------------------------------------------------------
		rtc_base = dut.rtc_div;
		run(300);
		rtc_delta = dut.rtc_div - rtc_base;
		$display("  RTC     : %0d reference pulses, %0d ARM7 enables -> divider +%0d",
		         en33, en7, rtc_delta);
		check(rtc_delta == en33, "the RTC's second counts its reference, not the CPU");
		check(rtc_delta != en7, "the RTC divider does not follow the ARM7's clock");

		//--------------------------------------------------------------
		// 6. overflow after exactly the reload's worth of ARM7 cycles
		//--------------------------------------------------------------
		// 0xFFFA + 5 counts = 0xFFFF, so the sixth count is the overflow. Step to
		// FFFFh from wherever the programming left the counter: an even number of
		// clocks is exactly half as many ARM7 enables, whatever the phase.
		wr(1'b0, 16'h0102, 16'h00C0);      // enable, IRQ on overflow
		wr(1'b0, 16'h0100, 16'hFFFA);      // reload write also loads the counter
		delta = 16'hFFFF - dut.u_tmr7.cnt[0];
		run(delta * 2);
		$display("  overflow: at FFFFh cnt=%h IF.0=%b", dut.u_tmr7.cnt[0], if7[0]);
		check(dut.u_tmr7.cnt[0] == 16'hFFFF, "the counter stops at FFFFh before the wrap");
		check(if7[0] === 1'b0, "no overflow yet");
		run(2);                            // the next count is the overflow
		check(dut.u_tmr7.cnt[0] == 16'hFFFA, "the overflow reloads TM0CNT_L");
		check(if7[0] === 1'b1, "the overflow raised IF.0");

		$display("");
		$display("  %0d checks, %0d failure(s)", checks, errors);
		if (errors == 0) $display("TB SYS CLK PASS");
		else             $display("TB SYS CLK FAIL");
		$finish;
	end

endmodule
