//============================================================================
// NDS MiSTer Test — ARM7TDMI core bench
//
//   iverilog -g2012 -o /tmp/tb_arm7 tb/tb_arm7.sv rtl/cpu/arm7_core.sv
//   vvp /tmp/tb_arm7
//
// The core runs a hand-assembled program out of a bus model that speaks the
// same protocol as main_bus (request held until ready, one clock of latency,
// byte enables on writes). Nothing is poked into the register file: every
// value checked below was produced by an instruction the core fetched,
// decoded and executed.
//
// The program (ARM at 0x02000000, Thumb at 0x02000100):
//
//   MOV r0,#5 ; MOV r1,#7 ; ADD r2,r0,r1     r2 = 12
//   CMP r2,#12                               Z set
//   MOVEQ r3,#1                              conditional execution
//   MOV r5,#0x2000 ; STR r2,[r5] ; LDR r4,[r5]
//   ADD r6,r2,r2,LSL #2                      r6 = 60, barrel shifter
//   SUBS r7,r6,#60                           r7 = 0, Z set
//   MUL r8,r0,r1                             r8 = 35
//   ADD r10,pc,#0xCD ; BX r10                enter Thumb at 0x02000100
//     Thumb: MOVS r0,#3 ; ADDS r0,#4         r0 = 7
//            BNE over a MOVS                 condition in bits 11:8
//            LDR r3,[pc,#4] ; BX r3          back to ARM at 0x02000040
//   MOV r11,#1 ; SWI #0                      vector 0x08: MOVS pc,lr
//   MOV r12,#2 ; BL subroutine ; B .          end marker; the subroutine at
//   0x02000064 returns with MOV pc,lr
//
// A second program (loaded over the first, after a reset, so its checks see
// only its own results) covers the families the first one does not reach:
//
//   STMIA r0!,{r1-r3} ; LDMIA r0,{r4-r6}      writeback, no writeback on LDM
//   STRH/LDRH, STRB + LDRSB, STRH + LDRSH      halfword, byte, sign extension
//   SWP r9,r12,[r7]                           both halves, memory updated
//   Thumb PUSH {r2,r3} ; POP {r0,r1}          stack round trip on a stack the
//                                             program places in modelled memory
//
// Checks: every register above, the Z flag, the SVC mode after the exception
// return, the stored word in the bus model, the IRQ vector taken and returned
// from, and HALTCNT keeps the core stopped until an interrupt arrives.
//============================================================================
`timescale 1ns / 1ps

module tb_arm7 #(
	// forwarded to the core so the bench can measure the fetch buffer's effect
	parameter FETCH_BUF = 1
);

reg clk = 0;
reg reset = 1;
reg irq = 0;
reg fiq = 0;
reg halt = 0;

wire [31:0] bus_addr, bus_wdata;
wire  [3:0] bus_be;
wire        bus_rd, bus_wr;
reg  [31:0] bus_rdata;
reg         bus_ready = 0;
wire        halted, thumb_state;
wire [31:0] pc_out;

integer errors = 0;
integer checks = 0;

always #10 clk = ~clk;

//------------------------------------------------------------------
// memory: 256 KB low (vectors) and 4 MB main RAM
//------------------------------------------------------------------
reg [31:0] lo  [0:16383];        // 0x00000000..0x0000FFFF
reg [31:0] ram [0:65535];        // 0x02000000..0x0203FFFF

wire        is_lo  = (bus_addr[31:24] == 8'h00);
wire        is_ram = (bus_addr[31:24] == 8'h02);
wire [13:0] lo_idx  = bus_addr[15:2];
wire [15:0] ram_idx = bus_addr[17:2];

always @(*) begin
	bus_rdata = 32'h0000_0000;
	if (is_lo)  bus_rdata = lo[lo_idx];
	if (is_ram) bus_rdata = ram[ram_idx];
end

// one wait state, then ready for exactly one cycle
reg [1:0] wait_cnt = 0;
always @(posedge clk) begin
	bus_ready <= 1'b0;
	if (bus_rd || bus_wr) begin
		if (wait_cnt == 2'd1) begin
			bus_ready <= 1'b1;
			wait_cnt  <= 2'd0;
			if (bus_wr) begin
				if ($test$plusargs("bus"))
					$display("BUSW addr=%h be=%b data=%h pc=%h",
					         bus_addr, bus_be, bus_wdata, pc_out);
				if (is_lo) begin
					if (bus_be[0]) lo[lo_idx][7:0]   <= bus_wdata[7:0];
					if (bus_be[1]) lo[lo_idx][15:8]  <= bus_wdata[15:8];
					if (bus_be[2]) lo[lo_idx][23:16] <= bus_wdata[23:16];
					if (bus_be[3]) lo[lo_idx][31:24] <= bus_wdata[31:24];
				end
				if (is_ram) begin
					if (bus_be[0]) ram[ram_idx][7:0]   <= bus_wdata[7:0];
					if (bus_be[1]) ram[ram_idx][15:8]  <= bus_wdata[15:8];
					if (bus_be[2]) ram[ram_idx][23:16] <= bus_wdata[23:16];
					if (bus_be[3]) ram[ram_idx][31:24] <= bus_wdata[31:24];
				end
			end
		end else wait_cnt <= wait_cnt + 2'd1;
	end else wait_cnt <= 2'd0;
end

//------------------------------------------------------------------
// device
//------------------------------------------------------------------
arm7_core #(.FETCH_BUF(FETCH_BUF)) dut (
	// .ce is tied high here: this bench checks what the core *does*, at full
	// rate. The DS's 2:1 clock ratio and the enable-aware bus path are what
	// tb_cpu_clk covers.
	.clk(clk), .reset(reset), .ce(1'b1),
	.boot_pc(32'h0200_0000), .boot_sp(32'h0380_FD80),
	.bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_be(bus_be),
	.bus_rd(bus_rd), .bus_wr(bus_wr),
	.bus_rdata(bus_rdata), .bus_ready(bus_ready),
	.irq(irq), .fiq(fiq), .halt(halt),
	.halted(halted), .thumb_state(thumb_state), .pc_out(pc_out)
);

//------------------------------------------------------------------
// checks
//------------------------------------------------------------------
task check_reg(input [3:0] n, input [31:0] want, input [8*40-1:0] what);
	begin
		checks = checks + 1;
		if (dut.regs[n] !== want) begin
			errors = errors + 1;
			$display("  FAIL %0s: r%0d = %h, expected %h",
			         what, n, dut.regs[n], want);
		end
	end
endtask	task check_lo(input [13:0] idx, input [31:0] want, input [8*40-1:0] what);
	begin
		checks = checks + 1;
		if (lo[idx] !== want) begin
			errors = errors + 1;
			$display("  FAIL %0s: lo[%0d] = %h, expected %h",
			         what, idx, lo[idx], want);
		end
	end
endtask

task check_mem(input [15:0] idx, input [31:0] want, input [8*40-1:0] what);
	begin
		checks = checks + 1;
		if (ram[idx] !== want) begin
			errors = errors + 1;
			$display("  FAIL %0s: ram[%0d] = %h, expected %h",
			         what, idx, ram[idx], want);
		end
	end
endtask

//------------------------------------------------------------------
// second program: the families the first one does not reach
//
//   LDM/STM writeback round trip, LDRH/STRH, LDRSB/LDRSH sign extension,
//   SWP read and write halves, and a Thumb PUSH/POP pair on a stack the
//   program places in modelled memory.
//------------------------------------------------------------------
// bus traffic, for comparing the fetch buffer on and off
integer bus_reads = 0;
always @(posedge clk)
	if (bus_rd && bus_ready) bus_reads = bus_reads + 1;

integer li;
task load_b;
	begin
		for (li = 0; li < 65536; li = li + 1) ram[li] = 32'h0000_0000;

		ram[18'd0]  = 32'hE3A00A02;  // 0x00 MOV r0,#0x2000
		ram[18'd1]  = 32'hE3A01011;  //      MOV r1,#0x11
		ram[18'd2]  = 32'hE3A02022;  //      MOV r2,#0x22
		ram[18'd3]  = 32'hE3A03033;  //      MOV r3,#0x33
		ram[18'd4]  = 32'hE8A0000E;  // 0x10 STMIA r0!,{r1,r2,r3}
		ram[18'd5]  = 32'hE240000C;  //      SUB r0,r0,#12
		ram[18'd6]  = 32'hE3A04000;  //      MOV r4,#0
		ram[18'd7]  = 32'hE3A05000;  //      MOV r5,#0
		ram[18'd8]  = 32'hE3A06000;  //      MOV r6,#0
		ram[18'd9]  = 32'hE8900070;  // 0x24 LDMIA r0,{r4,r5,r6}
		ram[18'd10] = 32'hE3A07901;  // 0x28 MOV r7,#0x4000
		ram[18'd11] = 32'hE1C710B0;  //      STRH r1,[r7]
		ram[18'd12] = 32'hE1D780B0;  //      LDRH r8,[r7]
		ram[18'd13] = 32'hE3A09080;  //      MOV r9,#0x80
		ram[18'd14] = 32'hE5C79002;  //      STRB r9,[r7,#2]
		ram[18'd15] = 32'hE1D7A0D2;  // 0x3C LDRSB r10,[r7,#2]
		ram[18'd16] = 32'hE3A09902;  //      MOV r9,#0x8000
		ram[18'd17] = 32'hE1C790B4;  //      STRH r9,[r7,#4]
		ram[18'd18] = 32'hE1D7B0F4;  // 0x48 LDRSH r11,[r7,#4]
		ram[18'd19] = 32'hE3A0C099;  //      MOV r12,#0x99
		ram[18'd20] = 32'hE107909C;  // 0x50 SWP r9,r12,[r7]
		ram[18'd21] = 32'hE5970000;  //      LDR r0,[r7]
		ram[18'd22] = 32'hE3A0DC21;  //      MOV r13,#0x2100
		ram[18'd23] = 32'hE3A0C402;  //      MOV r12,#0x02000000
		ram[18'd24] = 32'hE28CCC01;  //      ADD r12,r12,#0x100
		ram[18'd25] = 32'hE28CC001;  //      ADD r12,r12,#1   (odd = Thumb)
		ram[18'd26] = 32'hE12FFF1C;  // 0x68 BX r12 -> Thumb
		ram[18'd27] = 32'hE1A0_0000;  // 0x6C NOP (pc passes here on the way)
		ram[18'd28] = 32'hEAFF_FFFE;  // 0x70 B .  (marker)

		//   0x100 MOVS r7,#4        loop count
		//   0x102 PUSH {r2,r3}      save the pair
		//   0x104 MOVS r0,#0        wipe it
		//   0x106 MOVS r1,#0
		//   0x108 POP  {r0,r1}      and take it back
		//   0x10A SUBS r7,#1
		//   0x10C BNE  0x102        four passes: enough Thumb fetches to measure
		//   0x10E LDR  r3,[pc,#4]
		//   0x110 BX   r3           back to the ARM marker
		ram[18'd64] = 32'hB40C_2704;  // MOVS r7,#4 ; PUSH {r2,r3}
		ram[18'd65] = 32'h2100_2000;  // MOVS r0,#0 ; MOVS r1,#0
		ram[18'd66] = 32'h3F01_BC03;  // POP {r0,r1} ; SUBS r7,#1
		ram[18'd67] = 32'h4B01_D1F9;  // BNE 0x102 ; LDR r3,[pc,#4]
		ram[18'd68] = 32'h46C0_4718;  // BX r3 ; NOP
		ram[18'd69] = 32'h0200_0070;  // 0x114 literal: back to the marker
	end
endtask

integer i;
reg irq_seen = 0;
reg woke = 0;
// The Z the SUB sets is gone by the end of the program: the SWI return
// restores CPSR from SPSR, which is what the architecture requires. Sample it
// while the next instruction (the MUL, which leaves the flags alone) runs.
reg z_sub = 0;
always @(posedge clk)
	if (dut.state == 4'd3 && pc_out == 32'h0200_0028) z_sub <= dut.z;
integer guard;

// write log: every architectural register change, with the PC that made it
// (enable with +regs)
reg  [31:0] shadow [0:15];
integer sj;
initial for (sj = 0; sj < 16; sj = sj + 1) shadow[sj] = 32'h0;
always @(posedge clk) begin
	if ($test$plusargs("regs")) begin
		for (sj = 0; sj < 16; sj = sj + 1) begin
			if (dut.regs[sj] !== shadow[sj]) begin
				$display("W r%0d <= %h   (after insn at pc=%h)",
				         sj, dut.regs[sj], pc_out);
				shadow[sj] <= dut.regs[sj];
			end
		end
	end
end

initial begin
	for (i = 0; i < 16384; i = i + 1) lo[i] = 32'h0000_0000;
	for (i = 0; i < 65536; i = i + 1) ram[i] = 32'h0000_0000;

	// exception vectors: SWI at 0x08 and IRQ at 0x18 both return from the
	// exception with the S-bit form of MOV pc,lr (CPSR <- SPSR)
	lo[16'h0008 >> 2] = 32'hE1B0_F00E;
	lo[16'h0018 >> 2] = 32'hE1B0_F00E;

	// ARM entry point
	ram[18'h0] = 32'hE3A0_0005;   // MOV  r0,#5
	ram[18'h1] = 32'hE3A0_1007;   // MOV  r1,#7
	ram[18'h2] = 32'hE080_2001;   // ADD  r2,r0,r1
	ram[18'h3] = 32'hE352_000C;   // CMP  r2,#12
	ram[18'h4] = 32'h03A0_3001;   // MOVEQ r3,#1
	ram[18'h5] = 32'hE3A0_5A02;   // MOV  r5,#0x2000
	ram[18'h6] = 32'hE585_2000;   // STR  r2,[r5]
	ram[18'h7] = 32'hE595_4000;   // LDR  r4,[r5]
	ram[18'h8] = 32'hE082_6102;   // ADD  r6,r2,r2,LSL #2
	ram[18'h9] = 32'hE256_703C;   // SUBS r7,r6,#60 -> 0, Z set
	ram[18'hA] = 32'hE008_0190;   // MUL  r8,r0,r1
	ram[18'hB] = 32'hE28F_A0CD;   // ADD  r10,pc,#0xCD  -> 0x02000101
	ram[18'hC] = 32'hE12F_FF1A;   // BX   r10
	ram[18'hD] = 32'hEAFF_FFFE;   // (not reached)

	// ARM continuation after the Thumb excursion
	ram[18'h10] = 32'hE3A0_B001;  // MOV r11,#1
	ram[18'h11] = 32'hEF00_0000;  // SWI #0
	ram[18'h12] = 32'hE3A0_C002;  // MOV r12,#2
	// the SWI return restored SPSR, which has I set, so clear it before the
	// IRQ test: MRS / BIC / MSR CPSR_c
	ram[18'h13] = 32'hE10F_9000;  // MRS r9, CPSR
	ram[18'h14] = 32'hE3C9_9080;  // BIC r9,r9,#0x80
	ram[18'h15] = 32'hE129_F009;  // MSR CPSR_c, r9
	ram[18'h16] = 32'hEB00_0001;  // BL  0x02000064 (LR = 0x0200005C)
	ram[18'h17] = 32'hEAFF_FFFE;  // B .  (end marker at 0x0200005C)
	ram[18'h19] = 32'hE1A0_F00E;  // MOV pc,lr — the subroutine's return

	// Thumb block at 0x02000100 = word 64
	//   0x100 MOVS r0,#3
	//   0x102 ADDS r0,#4        r0 = 7, Z clear//   0x104 BNE  +2           taken, skips the next two halfwords
//   0x106 MOVS r0,#0x55     (skipped)
//   0x108 NOP               (skipped)
//   0x10A LDR  r3,[pc,#4]   literal at 0x110
//   0x10C BX   r3
	ram[18'd64] = 32'h3004_2003;  // MOVS r0,#3 ; ADDS r0,#4
	ram[18'd65] = 32'h2055_D101;  // BNE +2 ; (skipped) MOVS r0,#0x55
	ram[18'd66] = 32'h4B01_46C0;  // NOP ; LDR r3,[pc,#4]
	ram[18'd67] = 32'h46C0_4718;  // BX r3 ; NOP
	ram[18'd68] = 32'h0200_0040;  // 0x110 literal: 0x02000040

	reset = 1;
	repeat (4) @(posedge clk);
	reset = 0;

	if ($test$plusargs("trace")) begin
		for (i = 0; i < 400; i = i + 1) begin
			@(posedge clk);
			$display("t=%0t pc=%h state=%0d rd=%b wr=%b addr=%h rdy=%b rdata=%h irq=%b",
			         $time, pc_out, dut.state, bus_rd, bus_wr, bus_addr,
			         bus_ready, bus_rdata, irq);
		end
		$display("after trace: pc=%h mode=%h r0=%h r1=%h r2=%h",
		         pc_out, dut.mode, dut.regs[0], dut.regs[1], dut.regs[2]);
	end

	// run to the end marker at 0x0200005C
	guard = 0;
	while (pc_out !== 32'h0200_005C && guard < 20000) begin
		@(posedge clk);
		guard = guard + 1;
	end
	// let the instruction at the marker commit before reading the register file
	repeat (8) @(posedge clk);
	checks = checks + 1;
	if (pc_out !== 32'h0200_005C) begin
		errors = errors + 1;
		$display("  FAIL program did not reach the end marker (pc = %h, stopped=%0d)",
		         pc_out, halted);
	end

	// ---- results of the ARM half ----
	check_reg(0,  32'd7,          "MOV/MUL source");
	check_reg(1,  32'd7,          "second source");
	check_reg(2,  32'd12,         "ADD r2,r0,r1");
	check_reg(3,  32'h0200_0040,  "Thumb literal load");
	check_reg(4,  32'd12,         "LDR round trip");
	check_reg(5,  32'h0000_2000,  "base register");
	check_reg(6,  32'd60,         "barrel shifter LSL #2");
	check_reg(7,  32'd0,          "SUB to zero");
	check_reg(8,  32'd35,         "MUL");
	check_reg(11, 32'd1,          "resumed in ARM after BX");
	check_reg(12, 32'd2,          "returned from SWI");
	check_reg(14, 32'h0200_005C,  "BL link register");

	// ---- flags: SUBS set Z (sampled at retire), the SWI return restored CPSR ----
	checks = checks + 1;
	if (z_sub !== 1'b1) begin
		errors = errors + 1;
		$display("  FAIL Z flag after SUBS r7,r6,#60");
	end
	checks = checks + 1;
	if (dut.mode !== 5'h13) begin
		errors = errors + 1;
		$display("  FAIL mode after the SWI return: %h", dut.mode);
	end
	check_lo(14'h800, 32'd12, "STR r2,[r5] reached the bus");

	// ---- IRQ: vector 0x18, the handler returns with MOVS pc,lr ----
	irq = 1;
	for (i = 0; i < 400; i = i + 1) begin
		@(posedge clk);
		if (dut.mode == 5'h12) irq_seen = 1;
	end
	irq = 0;
	repeat (40) @(posedge clk);
	checks = checks + 1;
	if (!irq_seen) begin
		errors = errors + 1;
		$display("  FAIL IRQ never entered IRQ mode");
	end
	checks = checks + 1;
	if (dut.mode !== 5'h13) begin
		errors = errors + 1;
		$display("  FAIL IRQ return left mode %h", dut.mode);
	end

	// ---- HALTCNT: stop until an interrupt ----
	halt = 1;
	repeat (20) @(posedge clk);
	checks = checks + 1;
	if (!halted) begin
		errors = errors + 1;
		$display("  FAIL halt did not stop the core");
	end
	irq = 1;
	woke = 0;
	for (i = 0; i < 100; i = i + 1) begin
		@(posedge clk);
		if (!halted) woke = 1;
	end
	checks = checks + 1;
	if (!woke) begin
		errors = errors + 1;
		$display("  FAIL interrupt did not wake the core");
	end
	irq = 0;
	halt = 0;

	// ---- phase 2: the wider instruction set ----
	load_b();
	reset = 1;
	repeat (4) @(posedge clk);
	reset = 0;

	guard = 0;
	while (pc_out !== 32'h0200_0070 && guard < 40000) begin
		@(posedge clk);
		guard = guard + 1;
	end
	repeat (8) @(posedge clk);
	checks = checks + 1;
	if (pc_out !== 32'h0200_0070) begin
		errors = errors + 1;
		$display("  FAIL second program did not reach its marker (pc = %h)", pc_out);
	end

	check_reg(4,  32'h0000_0011,  "LDMIA first word");
	check_reg(5,  32'h0000_0022,  "LDMIA second word");
	check_reg(6,  32'h0000_0033,  "LDMIA third word");
	check_reg(8,  32'h0000_0011,  "LDRH");
	check_reg(10, 32'hFFFF_FF80,  "LDRSB sign extension");
	check_reg(11, 32'hFFFF_8000,  "LDRSH sign extension");
	check_reg(9,  32'h0080_0011,  "SWP read half");
	check_lo(14'h1000, 32'h0000_0099, "SWP reached memory");
	check_reg(0,  32'h0000_0022,  "Thumb POP first word");
	check_reg(1,  32'h0000_0033,  "Thumb POP second word");

	$display("  fetch buffer %0s: %0d bus reads", FETCH_BUF ? "on " : "off", bus_reads);
	$display("  %0d checks, %0d failure(s)", checks, errors);
	if (errors == 0) $display("TB ARM7 PASS");
	else             $display("TB ARM7 FAIL");
	$finish;
end

endmodule
