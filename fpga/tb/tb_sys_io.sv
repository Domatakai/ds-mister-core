//============================================================================
// NDS MiSTer Test — system I/O testbench
//
//   iverilog -g2012 -o /tmp/tb_sio tb/tb_sys_io.sv \
//            rtl/bus/sys_io.sv rtl/bus/nds_timers.sv rtl/bus/ipc.sv \
//            rtl/bus/math_unit.sv && vvp /tmp/tb_sio
//
// Everything here is checked against GBATEK, not against the RTL's own
// structure: the timer prescaler counts the ticks the datasheet says, the
// cascade chain counts overflows, IPCSYNC bits arrive in the remote CPU's
// bits 0-3, the FIFO edge-IRQs fire on the documented condition changes,
// division returns the documented quotients and remainders (signed), dividing
// by zero returns the documented pair, and the two IRQ banks stay separate.
//
// The CPU split is exercised by making every access as ARM9 or ARM7, which is
// the one thing this block cannot get right by accident.
//============================================================================
module tb_sys_io;

	reg clk = 0;
	always #10 clk = ~clk;

	reg         reset = 1;
	reg         tick = 0;
	reg         cpu9 = 1;
	reg  [15:0] addr = 0;
	reg         acc = 0, we = 0;
	reg  [15:0] wdata = 0;
	reg  [31:0] wdata32 = 0;
	wire [15:0] rdata;
	reg         recv_hit = 0;
	wire [31:0] recv_rdata;
	reg  [31:0] irq_src9 = 0, irq_src7 = 0;

	wire [31:0] ie9, if9, ie7, if7;
	wire        ime9, irq9, ime7, irq7, arm7_halt;

	sys_io dut (
		.clk(clk), .reset(reset), .tick(tick),
		// the RTC's own crystal reference is not under test here (tb_sys_clk
		// covers the timer/RTC split); its one-second divider just stays put
		.tick33(1'b0),
		.cpu9(cpu9), .addr(addr), .acc(acc), .we(we),
		.wdata(wdata), .wdata32(wdata32), .rdata(rdata),
		.recv_hit(recv_hit), .recv_rdata(recv_rdata),
		.irq_src9(irq_src9), .irq_src7(irq_src7),
		.ie9(ie9), .if9(if9), .ime9(ime9), .irq9(irq9),
		.ie7(ie7), .if7(if7), .ime7(ime7), .irq7(irq7),
		.arm7_halt(arm7_halt)
	);

	integer errors = 0;
	task check;
		input [8*52:1] name;
		input          cond;
		begin
			if (!cond) begin
				$display("FAIL %0s", name);
				errors = errors + 1;
			end else
				$display("ok   %0s", name);
		end
	endtask

	//------------------------------------------------------------------
	// one bus access
	//------------------------------------------------------------------
	task wr;
		input        c9;
		input [15:0] a;
		input [15:0] d;
		begin
			@(negedge clk);
			cpu9 = c9; addr = a; wdata = d; wdata32 = {16'h0000, d};
			we = 1; acc = 1;
			@(negedge clk);
			we = 0; acc = 0;
			@(posedge clk); #1;
			@(posedge clk); #1;
		end
	endtask

	task wr32;
		input        c9;
		input [15:0] a;
		input [31:0] d;
		begin
			@(negedge clk);
			cpu9 = c9; addr = a; wdata = d[15:0]; wdata32 = d;
			we = 1; acc = 1;
			@(negedge clk);
			we = 0; acc = 0;
			@(posedge clk); #1;
			@(posedge clk); #1;
		end
	endtask

	task rd;
		input        c9;
		input [15:0] a;
		output [15:0] d;
		begin
			@(negedge clk);
			cpu9 = c9; addr = a; we = 0; acc = 1;
			#1 d = rdata;
			@(negedge clk);
			acc = 0;
		end
	endtask

	task rd_recv;
		input        c9;
		output [31:0] d;
		begin
			@(negedge clk);
			cpu9 = c9; addr = 16'h0000; we = 0; acc = 1; recv_hit = 1;
			#1 d = recv_rdata;
			@(negedge clk);
			acc = 0; recv_hit = 0;
		end
	endtask

	task ticks;
		input integer n;
		integer i;
		begin
			for (i = 0; i < n; i = i + 1) begin
				@(negedge clk); tick = 1;
				@(negedge clk); tick = 0;
			end
			@(posedge clk);      // let the last overflow reach the flag bank
			@(posedge clk); #1;
		end
	endtask

	reg  [15:0] d, mode;
	reg  [31:0] w;
	reg  [63:0] q, r;
	integer     guard;

	// poll DIVCNT/SQRTCNT until the busy bit drops
	task wait_busy;
		input [15:0] a;
		begin
			guard = 0;
			rd(1'b1, a, mode);
			while (mode[15] && guard < 3000) begin
				rd(1'b1, a, mode);
				guard = guard + 1;
			end
		end
	endtask

	initial begin
		repeat (4) @(posedge clk);
		reset = 0;
		repeat (2) @(posedge clk);

		//=============================================================
		// 1. timers
		//=============================================================
		// reload FFFEh with /1 and the IRQ enabled: one tick reaches FFFFh,
		// the next wraps to the reload value and raises IF.0
		wr(1'b1, 16'h0100, 16'hFFFE);
		wr(1'b1, 16'h0102, 16'h00C0);
		ticks(1);
		check("timer 0 counts one tick", dut.u_tmr9.cnt[0] === 16'hFFFF);
		ticks(1);
		check("timer 0 reloads on overflow", dut.u_tmr9.cnt[0] === 16'hFFFE);
		check("timer 0 raises IF.0", if9[0] === 1'b1);
		wr(1'b1, 16'h0214, 16'h0001);
		check("IF.0 acknowledges on a write of 1", if9[0] === 1'b0);

		// prescaler /64: the counter steps once every 64 ticks
		wr(1'b1, 16'h0100, 16'h0000);
		wr(1'b1, 16'h0102, 16'h0081);
		ticks(63);
		check("prescaler /64 holds for 63 ticks", dut.u_tmr9.cnt[0] === 16'h0000);
		ticks(1);
		check("prescaler /64 steps on the 64th tick", dut.u_tmr9.cnt[0] === 16'h0001);

		// cascade: timer 1 counts timer 0's overflows, ignoring its prescaler
		wr(1'b1, 16'h0104, 16'h0000);
		wr(1'b1, 16'h0106, 16'h0084);
		wr(1'b1, 16'h0100, 16'hFFFE);
		wr(1'b1, 16'h0102, 16'h0080);       // /1, no IRQ, enabled
		ticks(2);
		check("cascaded timer 1 counts timer 0's overflow",
		      dut.u_tmr9.cnt[1] === 16'h0001);

		// the ARM7 has its own four timers at the same addresses
		rd(1'b0, 16'h0100, d);
		check("ARM7 timers are a separate set", d === 16'h0000);
		rd(1'b1, 16'h0100, d);
		check("ARM9 timers keep their own reload", d === 16'hFFFE);

		//=============================================================
		// 2. IPCSYNC
		//=============================================================
		wr(1'b1, 16'h0180, 16'h0A00);       // ARM9 output = Ah
		rd(1'b0, 16'h0180, d);
		check("ARM9's output appears in the ARM7's bits 0-3",
		      d[3:0] === 4'hA);
		wr(1'b0, 16'h0180, 16'h0500);       // ARM7 output = 5h
		rd(1'b1, 16'h0180, d);
		check("ARM7's output appears in the ARM9's bits 0-3",
		      d[3:0] === 4'h5);
		check("each CPU reads its own output in bits 8-11",
		      d[11:8] === 4'hA);

		// remote IRQ: enabled by the receiver's bit 14, sent by bit 13
		wr(1'b1, 16'h0180, 16'h4A00);       // enable IRQ from ARM7, keep A
		wr(1'b0, 16'h0180, 16'h2500);       // ARM7: send IRQ + output 5
		check("IPCSYNC bit 13 interrupts the other CPU", if9[16] === 1'b1);
		wr(1'b1, 16'h0216, 16'h0001);       // clear IF.16
		check("IF.16 acknowledges", if9[16] === 1'b0);

		// a disabled receiver must not be interrupted
		wr(1'b1, 16'h0180, 16'h0A00);       // bit 14 off
		wr(1'b0, 16'h0180, 16'h2500);
		check("no IPC IRQ when the receiver disables it", if9[16] === 1'b0);

		//=============================================================
		// 3. IPC FIFOs
		//=============================================================
		wr(1'b1, 16'h0184, 16'h8000);       // ARM9: enable
		wr(1'b0, 16'h0184, 16'h8000);       // ARM7: enable
		wr32(1'b1, 16'h0188, 32'hDEAD_BEEF);
		rd_recv(1'b0, w);
		check("a 32-bit word crosses from ARM9 to ARM7", w === 32'hDEAD_BEEF);
		rd(1'b0, 16'h0184, d);
		check("the receiving FIFO reads empty afterwards", d[8] === 1'b1);

		wr32(1'b0, 16'h0188, 32'h1234_5678);
		rd(1'b1, 16'h0184, d);
		check("the ARM9's send FIFO is empty again", d[0] === 1'b1);
		rd_recv(1'b1, w);
		check("and the ARM9 receives it", w === 32'h1234_5678);

		// fill the ARM9 send FIFO: 16 words, then full and error
		for (guard = 0; guard < 16; guard = guard + 1)
			wr32(1'b1, 16'h0188, 32'h1000_0000 + guard);
		rd(1'b1, 16'h0184, d);
		check("a full send FIFO reports full", d[1] === 1'b1);
		check("and reports not-empty", d[0] === 1'b0);
		wr32(1'b1, 16'h0188, 32'hFFFF_FFFF);
		rd(1'b1, 16'h0184, d);
		check("writing to a full FIFO raises the error bit", d[14] === 1'b1);

		// flush drops everything
		wr(1'b1, 16'h0184, 16'h8008);
		rd(1'b1, 16'h0184, d);
		check("bit 3 flushes the send FIFO", d[0] === 1'b1 && d[14] === 1'b0);

		// reading an empty FIFO returns the last word and sets the error
		// (the ARM9's receive FIFO is empty here; the ARM7 still has words)
		rd_recv(1'b1, w);
		check("reading an empty FIFO returns the last word",
		      w === 32'h1234_5678);
		rd(1'b1, 16'h0184, d);
		check("reading an empty FIFO raises the error bit", d[14] === 1'b1);

		// edge-triggered IRQs: send-empty on the sender, not-empty on the
		// receiver, each gated by its own enable bit
		wr(1'b1, 16'h0184, 16'h8004);       // ARM9 send-empty IRQ on
		wr(1'b1, 16'h0184, 16'h8004);
		check("send-empty IRQ fires when the FIFO empties", if9[17] === 1'b1);
		wr(1'b1, 16'h0216, 16'h0002);
		wr(1'b0, 16'h0184, 16'h8400);       // ARM7 recv not-empty IRQ on
		wr32(1'b1, 16'h0188, 32'h0000_0042);
		check("recv-not-empty IRQ fires when a word arrives", if7[18] === 1'b1);

		// a disabled FIFO ignores writes and does not raise the error bit
		wr(1'b1, 16'h0184, 16'h0000);
		wr32(1'b1, 16'h0188, 32'h0000_0001);
		rd(1'b1, 16'h0184, d);
		check("a disabled FIFO ignores sends without an error",
		      d[14] === 1'b0);

		//=============================================================
		// 4. maths coprocessor (ARM9 only)
		//=============================================================
		wr(1'b1, 16'h0280, 16'h0000);       // mode 0: 32/32
		wr(1'b1, 16'h0290, 16'h0064);       // numer = 100
		wr(1'b1, 16'h0292, 16'h0000);
		wr(1'b1, 16'h0298, 16'h0007);       // denom = 7
		wr(1'b1, 16'h029A, 16'h0000);
		wait_busy(16'h0280);
		rd(1'b1, 16'h02A0, d);
		check("100 / 7 = 14", d === 16'd14);
		rd(1'b1, 16'h02A8, d);
		check("100 % 7 = 2", d === 16'd2);

		// signed: -100 / 7 = -14 rem -2
		wr(1'b1, 16'h0290, 16'hFF9C);
		wr(1'b1, 16'h0292, 16'hFFFF);
		wr(1'b1, 16'h0294, 16'hFFFF);
		wr(1'b1, 16'h0296, 16'hFFFF);
		wr(1'b1, 16'h0298, 16'h0007);
		wr(1'b1, 16'h029A, 16'h0000);
		wr(1'b1, 16'h029C, 16'h0000);
		wr(1'b1, 16'h029E, 16'h0000);
		wait_busy(16'h0280);
		rd(1'b1, 16'h02A0, d);
		check("-100 / 7 = -14", d === 16'hFFF2);
		rd(1'b1, 16'h02A8, d);
		check("-100 % 7 = -2", d === 16'hFFFE);

		// 64/64 mode: 0x1_0000_0000 / 2 = 0x8000_0000
		wr(1'b1, 16'h0280, 16'h0002);
		wr(1'b1, 16'h0290, 16'h0000);
		wr(1'b1, 16'h0292, 16'h0000);
		wr(1'b1, 16'h0294, 16'h0001);
		wr(1'b1, 16'h0296, 16'h0000);
		wr(1'b1, 16'h0298, 16'h0002);
		wr(1'b1, 16'h029A, 16'h0000);
		wr(1'b1, 16'h029C, 16'h0000);
		wr(1'b1, 16'h029E, 16'h0000);
		wait_busy(16'h0280);
		rd(1'b1, 16'h02A0, d);
		q[15:0] = d;
		rd(1'b1, 16'h02A2, d);
		q[31:16] = d;
		check("64-bit division: 2^32 / 2 = 2^31", q[31:0] === 32'h8000_0000);
		rd(1'b1, 16'h02A8, d);
		check("and leaves no remainder", d === 16'h0000);

		// division by zero: flag, result -1, remainder = numerator
		wr(1'b1, 16'h0280, 16'h0000);
		wr(1'b1, 16'h0290, 16'h0005);
		wr(1'b1, 16'h0292, 16'h0000);
		wr(1'b1, 16'h0298, 16'h0000);
		wr(1'b1, 16'h029A, 16'h0000);
		wait_busy(16'h0280);
		rd(1'b1, 16'h0280, d);
		check("dividing by zero sets DIVCNT.14", d[14] === 1'b1);
		rd(1'b1, 16'h02A0, d);
		check("and returns -1 for a positive numerator", d === 16'hFFFF);
		rd(1'b1, 16'h02A8, d);
		check("with the numerator as remainder", d === 16'd5);

		// ARM7 sees no maths coprocessor
		rd(1'b0, 16'h02A0, d);
		check("the ARM7 reads zero from the maths block", d === 16'h0000);

		// square root: 144 = 12, and the 64-bit mode on 2^32
		wr(1'b1, 16'h02B0, 16'h0000);
		wr(1'b1, 16'h02B8, 16'h0090);
		wr(1'b1, 16'h02BA, 16'h0000);
		wr(1'b1, 16'h02BC, 16'h0000);
		wr(1'b1, 16'h02BE, 16'h0000);
		wait_busy(16'h02B0);
		rd(1'b1, 16'h02B4, d);
		check("sqrt(144) = 12", d === 16'd12);

		wr(1'b1, 16'h02B0, 16'h0001);       // 64-bit input
		wr(1'b1, 16'h02B8, 16'h0000);
		wr(1'b1, 16'h02BA, 16'h0000);
		wr(1'b1, 16'h02BC, 16'h0001);
		wr(1'b1, 16'h02BE, 16'h0000);
		wait_busy(16'h02B0);
		rd(1'b1, 16'h02B4, d);
		check("sqrt(2^32) = 65536", d === 16'd0 && d === 16'h0000);
		rd(1'b1, 16'h02B6, d);
		check("the high half of sqrt(2^32) is 1", d === 16'd1);

		//=============================================================
		// 5. two interrupt banks
		//=============================================================
		wr(1'b1, 16'h0210, 16'h0001);       // ARM9 IE = timer 0
		wr(1'b1, 16'h0208, 16'h0001);       // ARM9 IME
		check("ARM9 IRQ follows IME and IE", irq9 === 1'b0);
		wr(1'b1, 16'h0100, 16'hFFFE);
		wr(1'b1, 16'h0102, 16'h00C0);
		ticks(2);
		check("a timer overflow raises the ARM9 IRQ line", irq9 === 1'b1);
		wr(1'b1, 16'h0214, 16'h0001);
		check("acknowledging the flag drops the IRQ", irq9 === 1'b0);

		// the ARM7 bank is written by ARM7 accesses only
		wr(1'b1, 16'h0210, 16'h0000);       // ARM9 IE cleared
		wr(1'b1, 16'h0208, 16'h0000);       // ARM9 IME cleared
		wr(1'b0, 16'h0210, 16'h0004);       // ARM7 IE = timer 2
		wr(1'b0, 16'h0208, 16'h0001);       // ARM7 IME
		rd(1'b1, 16'h0208, d);
		check("an ARM7 IME write leaves the ARM9 IME alone", d[0] === 1'b0);
		check("ARM7's own IME is set", ime7 === 1'b1);
		irq_src7 = 32'h0000_0004;           // timer 2 pulse
		@(posedge clk); @(posedge clk);
		irq_src7 = 32'h0000_0000;
		check("an ARM7 source raises the ARM7 IRQ line", irq7 === 1'b1);
		check("and not the ARM9's", irq9 === 1'b0);
		wr(1'b0, 16'h0214, 16'h0004);
		check("ARM7 IF.2 acknowledges", irq7 === 1'b0);

		//=============================================================
		// 6. POSTFLG and HALT
		//=============================================================
		wr(1'b1, 16'h0300, 16'h0001);
		rd(1'b1, 16'h0300, d);
		check("POSTFLG keeps the boot-complete flag", d[0] === 1'b1);

		wr(1'b0, 16'h0301, 16'h0080);
		check("HALTCNT bit 7 halts the ARM7", arm7_halt === 1'b1);
		wr(1'b0, 16'h0301, 16'h0000);
		check("writing 0 releases the halt", arm7_halt === 1'b0);

		// a pending enabled IRQ keeps the ARM7 awake
		wr(1'b0, 16'h0210, 16'h0004);
		wr(1'b0, 16'h0208, 16'h0001);
		irq_src7 = 32'h0000_0004;
		@(posedge clk); @(posedge clk);
		irq_src7 = 32'h0000_0000;
		wr(1'b0, 16'h0301, 16'h0080);
		check("an enabled IRQ wakes the halted ARM7", arm7_halt === 1'b0);

		//=============================================================
		if (errors == 0) $display("TB SYS IO PASS");
		else             $display("TB SYS IO FAIL (%0d errors)", errors);
		$finish;
	end

	// the maths square root is 32-bit: 65536 fits, so check both halves
	initial begin
		#1;
	end

endmodule
