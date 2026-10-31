//============================================================================
// NDS MiSTer Test — ARM946E-S core bench
//
//   iverilog -g2012 -I tb -o /tmp/tb_arm9 tb/tb_arm9.sv rtl/cpu/arm9_core.sv
//   vvp /tmp/tb_arm9
//
// The core runs programs out of a bus model that speaks the same protocol as
// main_bus (request held until ready, one clock of latency, byte enables on
// writes) plus the three regions the DS decodes at reset: the low vector page
// at 0x00000000, main RAM at 0x02000000 and — because the DS's ARM9 leaves the
// BIOS with CP15 V set — the high vector page at 0xFFFF0000. Nothing is poked
// into the register file: every value checked here was produced by an
// instruction the core fetched, decoded and executed.
//
// The three programs live in tb/tb_arm9_prog.svh, which tools/gen_arm9_programs.py
// emits from a real assembler (keystone) with an independent disassembler
// (capstone) reading the result back, so the decoder under test and the words
// it is fed do not come from the same head. Each program is loaded over main
// RAM and run after a reset, so it starts from a clean register file and the
// CP15 reset values.
//
//   A  integer ARM: ADD/CMP/MOVEQ, the barrel shifter, SUBS, MUL/MLA/UMULL/
//      SMULL with a negative operand, a STR/LDR round trip, BX into a Thumb
//      block and back with a Thumb LDR literal, SWI through the *high* vector,
//      the IRQ vector, and a BL subroutine
//   B  the ARMv5TE additions and the DS's memory rules: SMULxy/SMLAxy/SMULWy/
//      SMLAWy/SMLALxy, CLZ, QADD/QSUB/QDADD/QDSUB with the sticky Q flag (read
//      back through MRS twice, once before and once after MSR clears it),
//      LDRD/STRD with immediate, register and writeback forms, LDRH/LDRSB/
//      LDRSH, a misaligned LDR rotating, misaligned STR/LDRH/STRH force-
//      aligning, LDM/STM with the user-mode bank from IRQ mode, and SWP
//   C  CP15 (main ID, cache type, the post-BIOS control value, c2/c5/c9
//      round trips, c7 reading as zero, the V bit moving the vectors down),
//      SWI and BKPT through the low vector, an undefined instruction, the CPSR
//      flag fields through MSR/MRS, and Thumb PUSH/POP, BKPT and BLX
//
// Checks: the architectural registers each program leaves behind, the scratch
// block each one writes through the bus, the CPSR the program reads back, the
// exception vectors actually entered (monitored by address, so "the SWI took
// the high vector" is evidence and not an assumption), the modes, and HALTCNT
// holding the core until an interrupt arrives.
//============================================================================
`timescale 1ns / 1ps

module tb_arm9 #(
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
// memory: the low vector page (64 KB), the high vector page (V=1) and 256 KB
// of main RAM
//------------------------------------------------------------------
reg [31:0] lo  [0:16383];        // 0x00000000..0x0000FFFF
reg [31:0] hi  [0:255];          // 0xFFFF0000..0xFFFF03FF
reg [31:0] ram [0:65535];        // 0x02000000..0x0203FFFF

wire        is_lo  = (bus_addr[31:16] == 16'h0000);
wire        is_hi  = (bus_addr[31:16] == 16'hFFFF);
wire        is_ram = (bus_addr[31:24] == 8'h02);
wire [13:0] lo_idx  = bus_addr[15:2];
wire  [7:0] hi_idx  = bus_addr[9:2];
wire [15:0] ram_idx = bus_addr[17:2];

always @(*) begin
	bus_rdata = 32'h0000_0000;
	if (is_lo)  bus_rdata = lo[lo_idx];
	if (is_hi)  bus_rdata = hi[hi_idx];
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

wire        hle_go, hle_done, hle_handled, hle_wr0, hle_wr1, hle_wr3;
wire  [7:0] hle_num;
wire [31:0] hle_r0, hle_r1, hle_r2, hle_r3;
wire [31:0] hle_res0, hle_res1, hle_res3;
wire        hle_b_req, hle_b_wr, hle_b_ack;
wire [31:0] hle_b_addr, hle_b_wlane, hle_b_rdata;
wire  [3:0] hle_b_be;

//------------------------------------------------------------------
// device
//------------------------------------------------------------------
arm9_core #(.FETCH_BUF(FETCH_BUF)) dut (
	// .ce is tied high here: this bench checks what the core *does*, at full
	// rate. The DS's 2:1 clock ratio and the enable-aware bus path are what
	// tb_cpu_clk covers.
	.clk(clk), .reset(reset), .ce(1'b1),
	.boot_pc(32'h0200_0000), .boot_sp(32'h0200_0300),
	.bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_be(bus_be),
	.bus_rd(bus_rd), .bus_wr(bus_wr),
	.bus_rdata(bus_rdata), .bus_ready(bus_ready),
	.irq(irq), .fiq(fiq), .halt(halt),
	.halted(halted), .thumb_state(thumb_state), .pc_out(pc_out),
	.hle_go(hle_go), .hle_num(hle_num),
	.hle_r0(hle_r0), .hle_r1(hle_r1), .hle_r2(hle_r2), .hle_r3(hle_r3),
	.hle_done(hle_done), .hle_handled(hle_handled),
	.hle_res0(hle_res0), .hle_res1(hle_res1), .hle_res3(hle_res3),
	.hle_wr0(hle_wr0), .hle_wr1(hle_wr1), .hle_wr3(hle_wr3),
	.hle_b_req(hle_b_req), .hle_b_wr(hle_b_wr), .hle_b_be(hle_b_be),
	.hle_b_addr(hle_b_addr), .hle_b_wlane(hle_b_wlane),
	.hle_b_ack(hle_b_ack), .hle_b_rdata(hle_b_rdata)
);


//------------------------------------------------------------------
// the shared BIOS bank: one engine, this core's side of it wired
//------------------------------------------------------------------
swi_share hle (
	.clk(clk), .reset(reset), .ce9(1'b1), .ce7(1'b1),
	.c7_go(1'b0), .c7_num(8'h00),
	.c7_r0(32'd0), .c7_r1(32'd0), .c7_r2(32'd0), .c7_r3(32'd0),
	.c7_done(), .c7_handled(), .c7_res0(), .c7_res1(), .c7_res3(),
	.c7_wr0(), .c7_wr1(), .c7_wr3(),
	.c7_b_req(), .c7_b_wr(), .c7_b_be(), .c7_b_addr(), .c7_b_wlane(),
	.c7_b_ack(1'b0), .c7_b_rdata(32'd0),
	.c9_go(hle_go), .c9_num(hle_num),
	.c9_r0(hle_r0), .c9_r1(hle_r1), .c9_r2(hle_r2), .c9_r3(hle_r3),
	.c9_done(hle_done), .c9_handled(hle_handled),
	.c9_res0(hle_res0), .c9_res1(hle_res1), .c9_res3(hle_res3),
	.c9_wr0(hle_wr0), .c9_wr1(hle_wr1), .c9_wr3(hle_wr3),
	.c9_b_req(hle_b_req), .c9_b_wr(hle_b_wr), .c9_b_be(hle_b_be),
	.c9_b_addr(hle_b_addr), .c9_b_wlane(hle_b_wlane),
	.c9_b_ack(hle_b_ack), .c9_b_rdata(hle_b_rdata),
	.busy(), .owner()
);

//------------------------------------------------------------------
// checks
//------------------------------------------------------------------
task check_reg(input [3:0] n, input [31:0] want, input [8*44-1:0] what);
	begin
		checks = checks + 1;
		if (dut.regs[n] !== want) begin
			errors = errors + 1;
			$display("  FAIL %0s: r%0d = %h, expected %h",
			         what, n, dut.regs[n], want);
		end
	end
endtask

task check_masked(input [3:0] n, input [31:0] want, input [31:0] mask,
                  input [8*44-1:0] what);
	begin
		checks = checks + 1;
		if ((dut.regs[n] & mask) !== want) begin
			errors = errors + 1;
			$display("  FAIL %0s: r%0d = %h, masked %h, expected %h",
			         what, n, dut.regs[n], dut.regs[n] & mask, want);
		end
	end
endtask

task check_ram(input [15:0] idx, input [31:0] want, input [8*44-1:0] what);
	begin
		checks = checks + 1;
		if (ram[idx] !== want) begin
			errors = errors + 1;
			$display("  FAIL %0s: ram[%0d] = %h, expected %h",
			         what, idx, ram[idx], want);
		end
	end
endtask

// the scratch block every program writes through the bus starts at 0x2000,
// which on the DS is the low 64 KB region (WRAM/vector area), not main RAM
task check_scratch(input [15:0] off, input [31:0] want, input [8*44-1:0] what);
	begin
		checks = checks + 1;
		if (lo[14'h0800 + (off >> 2)] !== want) begin
			errors = errors + 1;
			$display("  FAIL %0s: 0x2000+%h = %h, expected %h",
			         what, off, lo[14'h0800 + (off >> 2)], want);
		end
	end
endtask

task check_lo(input [13:0] idx, input [31:0] want, input [8*44-1:0] what);
	begin
		checks = checks + 1;
		if (lo[idx] !== want) begin
			errors = errors + 1;
			$display("  FAIL %0s: lo[%0d] = %h, expected %h",
			         what, idx, lo[idx], want);
		end
	end
endtask

task check_val(input integer got, input integer want, input [8*44-1:0] what);
	begin
		checks = checks + 1;
		if (got !== want) begin
			errors = errors + 1;
			$display("  FAIL %0s: %0d, expected %0d", what, got, want);
		end
	end
endtask

//------------------------------------------------------------------
// monitors: which vector the core actually entered, and whether the Thumb and
// IRQ states were ever live. These are observations of the running core, not
// assumptions about it.
//------------------------------------------------------------------
reg hi_swi  = 0;                 // SWI through 0xFFFF0008 (V set)
reg hi_irq  = 0;                 // IRQ through 0xFFFF0018
reg lo_swi  = 0;                 // SWI through 0x00000008 (V cleared)
reg lo_und  = 0;                 // undefined instruction through 0x00000004
reg lo_pabt = 0;                 // prefetch abort (BKPT) through 0x0000000C
reg thumb_seen = 0;
reg und_seen   = 0;              // the core sat in undefined mode
reg abt_seen   = 0;              // ... or in abort mode

always @(posedge clk) begin
	if (pc_out == 32'hFFFF_0008) hi_swi  <= 1'b1;
	if (pc_out == 32'hFFFF_0018) hi_irq  <= 1'b1;
	if (pc_out == 32'h0000_0008) lo_swi  <= 1'b1;
	if (pc_out == 32'h0000_0004) lo_und  <= 1'b1;
	if (pc_out == 32'h0000_000C) lo_pabt <= 1'b1;
	if (thumb_state)             thumb_seen <= 1'b1;
	if (dut.mode == 5'h1B)       und_seen   <= 1'b1;
	if (dut.mode == 5'h17)       abt_seen   <= 1'b1;
end

//------------------------------------------------------------------
// the programs (generated: see tools/gen_arm9_programs.py)
//------------------------------------------------------------------
integer li;
`include "tb_arm9_prog.svh"

//------------------------------------------------------------------
// program D: BIOS calls on the HLE bank, hand-assembled here rather than
// generated -- the same two calls tb_arm7 makes, through the ARM9's own SWI
// trap, so both cores are shown to reach the engine and come back
//------------------------------------------------------------------
task load_d;
	begin
		for (li = 0; li < 65536; li = li + 1) ram[li] = 32'h0000_0000;

		ram[18'd0]  = 32'hE3A00064;  // 0x00 MOV r0,#100
		ram[18'd1]  = 32'hE3A01007;  //      MOV r1,#7
		ram[18'd2]  = 32'hEF090000;  // 0x08 SWI #0x09        Div
		ram[18'd3]  = 32'hE3A04C01;  //      MOV r4,#0x100      result block
		ram[18'd4]  = 32'hE5840000;  //      STR r0,[r4]        quotient
		ram[18'd5]  = 32'hE5841004;  //      STR r1,[r4,#4]     remainder
		ram[18'd6]  = 32'hE5843008;  //      STR r3,[r4,#8]     |quotient|
		ram[18'd7]  = 32'hE3A00040;  // 0x1C MOV r0,#0x40        CpuSet source
		ram[18'd8]  = 32'hE3A01080;  //      MOV r1,#0x80        destination
		ram[18'd9]  = 32'hE3A02002;  //      MOV r2,#2           two units
		ram[18'd10] = 32'hE3822404;  //      ORR r2,r2,#0x04000000  (32-bit units)
		ram[18'd11] = 32'hE3A05C03;  //      MOV r5,#0x300       must survive the call
		ram[18'd12] = 32'hEF0B0000;  // 0x30 SWI #0x0B        CpuSet
		ram[18'd13] = 32'hE5916000;  //      LDR r6,[r1]
		ram[18'd14] = 32'hE5917004;  //      LDR r7,[r1,#4]
		ram[18'd15] = 32'hEAFF_FFFE;  // 0x3C B .                (marker)
	end
endtask

integer i;
integer guard;
integer bus_reads = 0;
reg irq_seen = 0;
reg woke = 0;

always @(posedge clk)
	if (bus_rd && bus_ready) bus_reads = bus_reads + 1;

// run until the program's end marker (a `B .` at a known address), with a
// guard so a hung core fails instead of running forever
task run_to(input [31:0] marker, input integer limit, input [8*44-1:0] what);
	begin
		guard = 0;
		while (pc_out !== marker && guard < limit) begin
			@(posedge clk);
			guard = guard + 1;
		end
		// let the instruction at the marker commit before reading anything
		repeat (8) @(posedge clk);
		checks = checks + 1;
		if (pc_out !== marker) begin
			errors = errors + 1;
			$display("  FAIL %0s did not reach its marker (pc = %h, halted = %0d)",
			         what, pc_out, halted);
			$display("       state = %0d, insn = %h (%0s), mode = %h, bus rd=%b wr=%b addr=%h",
			         dut.state, dut.insn, dut.insn_thumb ? "thumb" : "arm",
			         dut.mode, bus_rd, bus_wr, bus_addr);
		end
	end
endtask

task reset_core;
	begin
		reset = 1;
		repeat (4) @(posedge clk);
		reset = 0;
	end
endtask

initial begin
	for (i = 0; i < 16384; i = i + 1) lo[i] = 32'h0000_0000;
	for (i = 0; i < 256;   i = i + 1) hi[i] = 32'h0000_0000;
	for (i = 0; i < 65536; i = i + 1) ram[i] = 32'h0000_0000;

	// return-from-exception (CPSR <- SPSR) at the undefined, SWI and prefetch
	// abort entries of both pages, and the IRQ entry of the high one
	load_vectors;

	//==================== program A: integer ARM ====================
	load_a;
	reset_core;
	run_to(32'h0200_007C, 20000, "program A");

	check_reg(0,  32'd7,         "ADD/Thumb ADDS");
	check_reg(1,  32'd3,         "second source");
	check_reg(2,  32'hFFFF_FFFF, "SMULL high half of -2*3");
	check_reg(3,  32'h0200_0060, "Thumb LDR literal + BX back to ARM");
	check_reg(4,  32'd12,        "STR/LDR round trip");
	check_reg(5,  32'h0000_2000, "scratch base");
	check_reg(6,  32'd60,        "barrel shifter LSL #2");
	check_reg(7,  32'd0,         "SUBS r7,r6,#60");
	check_reg(8,  32'd35,        "MUL");
	check_masked(9, 32'h0000_0053, 32'h0000_00FF,
	             "MRS after the SWI return: SVC, F set, I cleared");
	check_reg(11, 32'd1,         "resumed in ARM after BX");
	check_reg(12, 32'd2,         "returned from the SWI");
	check_reg(14, 32'h0200_007C, "BL link register (the end marker)");

	check_scratch(16'h00, 32'd12,         "STR r2,[r5] reached the bus");
	check_scratch(16'h04, 32'd47,         "MLA");
	check_scratch(16'h08, 32'd0,          "UMULL high half");
	check_scratch(16'h0C, 32'd1,          "MOVEQ: CMP set Z");
	check_scratch(16'h10, 32'hFFFF_FFFA,  "SMULL low half, sign extended");

	check_val(dut.mode, 5'h13,            "SVC after the SWI return");
	check_val(thumb_state, 1'b0,          "ARM state after the Thumb block");
	check_val(thumb_seen, 1'b1,           "the Thumb block ran");
	check_val(hi_swi, 1'b1,               "SWI took the high vector (CP15 V)");

	// ---- IRQ: the DS's post-BIOS V bit means vector 0xFFFF0018 ----
	irq = 1;
	for (i = 0; i < 400; i = i + 1) begin
		@(posedge clk);
		if (dut.mode == 5'h12) irq_seen = 1;
	end
	irq = 0;
	repeat (40) @(posedge clk);
	check_val(irq_seen, 1'b1, "IRQ entered IRQ mode");
	check_val(hi_irq,   1'b1, "IRQ took the high vector");
	check_val(dut.mode, 5'h13, "IRQ returned to SVC");

	// ---- HALTCNT: stop until an interrupt ----
	halt = 1;
	repeat (20) @(posedge clk);
	check_val(halted, 1'b1, "halt stopped the core");
	irq = 1;
	for (i = 0; i < 100; i = i + 1) begin
		@(posedge clk);
		if (!halted) woke = 1;
	end
	check_val(woke, 1'b1, "an interrupt woke the core");
	irq = 0;
	halt = 0;

	//==================== program B: ARMv5TE ====================
	load_b;
	// the data the alignment and halfword tests read: a word whose bytes are
	// all different, and a second one to misalign against (0x2200/0x2300 are
	// in the low region, as they are on the DS)
	lo[14'h0880] = 32'h89AB_CDEF;   // 0x00002200
	lo[14'h08C0] = 32'hAABB_CCDD;   // 0x00002300
	reset_core;
	run_to(32'h0200_0250, 40000, "program B");

	check_scratch(16'h00, 32'd6,        "SMULBB");
	check_scratch(16'h04, 32'd21,       "SMULBT");
	check_scratch(16'h08, 32'd10,       "SMULTB");
	check_scratch(16'h0C, 32'd35,       "SMULTT");
	check_scratch(16'h10, 32'd1006,     "SMLABB");
	check_scratch(16'h14, 32'd2,        "SMULWB");
	check_scratch(16'h18, 32'd1007,     "SMLAWT");
	check_scratch(16'h1C, 32'd0,        "SMLALBB low half");
	check_scratch(16'h20, 32'd0,        "SMLALBB high half");
	check_scratch(16'h24, 32'd1,        "CLZ(0x40000000)");
	check_scratch(16'h28, 32'd32,       "CLZ(0)");

	check_scratch(16'h2C, 32'h7FFF_FFFF, "QADD saturates high");
	check_scratch(16'h30, 32'h8000_0000, "QSUB clamps at the low bound");
	check_scratch(16'h34, 32'h7FFF_FFFF, "QDADD saturates");
	check_scratch(16'h38, 32'hFFFF_FFFF, "QDSUB 1-2");
	check_scratch(16'hA0, 32'h0800_0000, "Q is sticky after the Q family");
	check_scratch(16'h3C, 32'd20,        "QADD 10+10");
	check_scratch(16'hA4, 32'h0000_0000, "MSR CPSR_f cleared Q");

	check_scratch(16'h40, 32'h0000_0011, "LDRD first word");
	check_scratch(16'h44, 32'h0000_0022, "LDRD second word");
	check_scratch(16'h48, 32'h0000_0033, "STRD/LDRD immediate first");
	check_scratch(16'h4C, 32'h0000_0044, "STRD/LDRD immediate second");
	check_scratch(16'h50, 32'h0000_2110, "STRD writeback base");
	check_scratch(16'h54, 32'h0000_0033, "STRD/LDRD register offset first");
	check_scratch(16'h58, 32'h0000_0044, "STRD/LDRD register offset second");

	check_scratch(16'h5C, 32'h0000_CDEF, "LDRH low half");
	check_scratch(16'h60, 32'h0000_89AB, "LDRH high half");
	check_scratch(16'h64, 32'hFFFF_FF89, "LDRSB sign extension");
	check_scratch(16'h68, 32'hFFFF_89AB, "LDRSH sign extension");
	check_scratch(16'h6C, 32'h0000_89AB, "STRH then LDR");

	check_scratch(16'h70, 32'hDDAA_BBCC, "misaligned LDR rotates right by 8");
	check_scratch(16'h74, 32'h0000_CCDD, "misaligned LDRH force-aligns");
	check_scratch(16'h78, 32'h89AB_CDEF, "misaligned STR force-aligns");
	check_scratch(16'h7C, 32'h0000_CDEF, "misaligned STRH force-aligns");

	check_scratch(16'h80, 32'h0000_0077, "STMIA^ stored the user bank's SP");
	check_scratch(16'h84, 32'h0000_0088, "STMIA^ stored the user bank's LR");
	check_scratch(16'h88, 32'h0000_0099, "LDMIA^ left the IRQ SP alone");
	check_scratch(16'h8C, 32'h0000_0000, "LDMIA^ left the IRQ LR alone");
	check_scratch(16'h90, 32'h0000_00AA, "LDMIA^ loaded the user bank");
	check_scratch(16'h94, 32'h0000_00BB, "LDMIA^ loaded the user LR");

	check_scratch(16'h98, 32'h0000_00AA, "SWP read half");
	check_scratch(16'h9C, 32'h0000_00BB, "SWP wrote through the bus");

	check_val(dut.mode, 5'h13, "SVC after the mode changes");

	//==================== program C: CP15 and the low vector ====================
	load_c;
	reset_core;
	run_to(32'h0200_0114, 40000, "program C");

	check_scratch(16'h00, 32'h4105_9461, "CP15 c0 main ID (ARM946E-S)");
	check_scratch(16'h04, 32'h0F0D_2112, "CP15 c0 cache type");
	check_scratch(16'h08, 32'h0001_2078, "CP15 c1 control, post-BIOS");
	check_scratch(16'h0C, 32'h0000_1234, "CP15 c2 translation table base");
	check_scratch(16'h10, 32'h0000_5678, "CP15 c9 c1 data TCM");
	check_scratch(16'h14, 32'h0000_9ABC, "CP15 c5 access permission");
	check_scratch(16'h18, 32'h0000_0DEF, "CP15 c1 op2=1 auxiliary control");
	check_scratch(16'h1C, 32'h0000_0000, "CP15 c7 maintenance reads as zero");
	check_scratch(16'h20, 32'h0001_0078, "CP15 control with V cleared");

	check_scratch(16'h24, 32'd2, "returned from the SWI (low vector)");
	check_scratch(16'h28, 32'd3, "resumed past the ARM BKPT");
	check_scratch(16'h2C, 32'h0000_0000,
	              "a prefetch abort leaves the CP15 fault address alone");
	check_scratch(16'h48, 32'd4, "resumed past the undefined coprocessor op");

	check_scratch(16'h30, 32'hF000_00D3, "MSR CPSR_f set N,Z,C,V with Q clear");
	check_scratch(16'h34, 32'h0000_00D3, "and cleared them again");

	check_scratch(16'h38, 32'd1,         "Thumb PUSH/POP round trip");
	check_scratch(16'h3C, 32'd5,         "resumed past the Thumb BKPT");
	check_scratch(16'h40, 32'd1,         "reached in ARM state through BLX");
	check_scratch(16'h44, 32'h0200_0215, "Thumb BLX link register");

	check_val(lo_swi,  1'b1, "SWI took the low vector once V was cleared");
	check_val(lo_und,  1'b1, "the undefined instruction took vector 0x04");
	check_val(lo_pabt, 1'b1, "BKPT took the prefetch abort vector 0x0C");
	check_val(und_seen, 1'b1, "the core sat in undefined mode");
	check_val(abt_seen, 1'b1, "the core sat in abort mode");
	check_val(thumb_state, 1'b0, "ARM state at the end of the BLX trip");

	//==================== program D: the BIOS SWI bank ====================
	lo[14'h0010] = 32'hDEAD_BEEF;   // the CpuSet source words at 0x40/0x44
	lo[14'h0011] = 32'h0BAD_F00D;
	load_d;
	reset_core;
	run_to(32'h0200_003C, 20000, "program D");

	check_lo(14'h0040, 32'd14,    "HLE Div quotient");
	check_lo(14'h0041, 32'd2,     "HLE Div remainder");
	check_lo(14'h0042, 32'd14,    "HLE Div |quotient|");
	check_lo(14'h0020, 32'hDEAD_BEEF, "CpuSet wrote its destination");
	check_lo(14'h0021, 32'h0BAD_F00D, "CpuSet wrote its second word");
	check_lo(14'h0010, 32'hDEAD_BEEF, "CpuSet left the source alone");
	check_reg(6,  32'hDEAD_BEEF,  "CpuSet copy read back, first word");
	check_reg(7,  32'h0BAD_F00D,  "CpuSet copy read back, second word");
	check_reg(5,  32'h0000_0300,  "CpuSet wrote no registers");
	check_val(dut.mode, 5'h13, "SVC after the HLE call");

	$display("  fetch buffer %0s: %0d bus reads", FETCH_BUF ? "on " : "off", bus_reads);
	$display("  %0d checks, %0d failure(s)", checks, errors);
	if (errors == 0) $display("TB ARM9 PASS");
	else             $display("TB ARM9 FAIL");
	$finish;
end

endmodule
