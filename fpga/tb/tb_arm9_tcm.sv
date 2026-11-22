//============================================================================
// NDS MiSTer Test — the TCM through the core
//
//   iverilog -g2012 -o /tmp/tb_arm9_tcm tb/tb_arm9_tcm.sv \
//            rtl/cpu/arm9_core.sv rtl/cpu/arm9_tcm.sv
//   vvp /tmp/tb_arm9_tcm
//
// tb_tcm drives the TCM stage on its own; this bench puts it where NDS.sv
// puts it — between arm9_core and the fabric — and makes the core itself
// program it. The program is assembled by keystone and read back by
// capstone (tools/gen_tcm_program.py), loaded over main RAM at 0x02000000
// and run after a reset, so every CP15 write and every access here is an
// instruction the core decoded and executed.
//
// The program does what a game's crt0 does: writes the data TCM's region
// register (c9 opcode_2 0: base 0x027C0000, 16 KB) and sets c1 bit 16,
// stores and reads a word there and patches two of its byte lanes; writes
// the instruction TCM's region register (c9 opcode_2 1: base 0, the 32 MB
// area the DS firmware programs) and sets c1 bit 18; reads both registers
// back; then copies two instructions into the ITCM at 0x01000000 and
// branches to them, so the fetch that runs comes from the TCM.
//
// Checks: the values the program left in its registers and in its results
// block, both c9 registers read back through MRC (which is what the core's
// c9 split is for — one register for both opcodes clobbered the other), the
// core's CP15 outputs as the stage sees them, that the fabric model served
// no access in either TCM window, that a TCM access is answered on the
// cycle the core samples the request while a fabric access is not, and
// that the fabric did serve the program itself.
//============================================================================
`timescale 1ns / 1ps

module tb_arm9_tcm;

reg clk = 0;
always #10 clk = ~clk;

reg reset = 1;

// core -> TCM -> fabric
wire [31:0] c_addr, c_wdata;
wire  [3:0] c_be;
wire        c_rd, c_wr;
wire [31:0] c_rdata;
wire        c_ready;

wire [31:0] f_addr, f_wdata;
wire  [3:0] f_be;
wire        f_rd, f_wr;
reg  [31:0] f_rdata;
reg         f_ready = 0;

wire        halted, thumb_state;
wire [31:0] pc_out;
wire [31:0] cp15_ctrl, cp15_c9d, cp15_c9i;

integer errors = 0;
integer checks = 0;

//------------------------------------------------------------------
// the fabric: the low vector page, the high one and 256 KB of main RAM,
// answering after one wait state like main_bus does
//------------------------------------------------------------------
reg [31:0] lo  [0:16383];
reg [31:0] hi  [0:255];
reg [31:0] ram [0:65535];

wire        is_lo  = (f_addr[31:16] == 16'h0000);
wire        is_hi  = (f_addr[31:16] == 16'hFFFF);
wire        is_ram = (f_addr[31:24] == 8'h02);
wire [13:0] lo_idx  = f_addr[15:2];
wire  [7:0] hi_idx  = f_addr[9:2];
wire [15:0] ram_idx = f_addr[17:2];

always @(*) begin
	f_rdata = 32'h0000_0000;
	if (is_lo)  f_rdata = lo[lo_idx];
	if (is_hi)  f_rdata = hi[hi_idx];
	if (is_ram) f_rdata = ram[ram_idx];
end

reg [1:0] wait_cnt = 0;
always @(posedge clk) begin
	f_ready <= 1'b0;
	if (f_rd || f_wr) begin
		if (wait_cnt == 2'd1) begin
			f_ready <= 1'b1;
			wait_cnt  <= 2'd0;
			if (f_wr) begin
				if (is_lo) begin
					if (f_be[0]) lo[lo_idx][7:0]   <= f_wdata[7:0];
					if (f_be[1]) lo[lo_idx][15:8]  <= f_wdata[15:8];
					if (f_be[2]) lo[lo_idx][23:16] <= f_wdata[23:16];
					if (f_be[3]) lo[lo_idx][31:24] <= f_wdata[31:24];
				end
				if (is_ram) begin
					if (f_be[0]) ram[ram_idx][7:0]   <= f_wdata[7:0];
					if (f_be[1]) ram[ram_idx][15:8]  <= f_wdata[15:8];
					if (f_be[2]) ram[ram_idx][23:16] <= f_wdata[23:16];
					if (f_be[3]) ram[ram_idx][31:24] <= f_wdata[31:24];
				end
			end
		end else wait_cnt <= wait_cnt + 2'd1;
	end else wait_cnt <= 2'd0;
end

//------------------------------------------------------------------
// what the fabric was asked for, and how long an answer took
//------------------------------------------------------------------
wire in_dtcm_win = (f_addr[31:12] == 20'h0_27C0);   // 0x027C0000..0x027C0FFF
wire in_itcm_win = (f_addr[31:24] == 8'h01);        // the 32 MB ITCM area

integer fab_served = 0, dtcm_saw = 0, itcm_saw = 0;
always @(posedge clk) begin
	if ((f_rd || f_wr) && f_ready) begin
		fab_served = fab_served + 1;
		if (in_dtcm_win) dtcm_saw = dtcm_saw + 1;
		if (in_itcm_win) itcm_saw = itcm_saw + 1;
	end
end

// a request is answered on the cycle the core samples it when the TCM has
// it (cyc == 0 here); a fabric access, one wait state, is not
reg        req_q = 0;
reg [31:0] cyc = 0;
integer tcm_fast = 0, tcm_slow = 0, fab_slow = 0;
always @(posedge clk) begin
	if (c_rd || c_wr) begin
		if (!req_q) begin req_q <= 1'b1; cyc <= 32'd0; end
		else cyc <= cyc + 32'd1;
		if (c_ready) begin
			if (!f_rd && !f_wr) begin
				if (cyc == 32'd0) tcm_fast = tcm_fast + 1;
				else              tcm_slow = tcm_slow + 1;
			end else if (cyc != 32'd0) fab_slow = fab_slow + 1;
			req_q <= 1'b0;
			cyc   <= 32'd0;
		end
	end else begin
		req_q <= 1'b0;
		cyc   <= 32'd0;
	end
end

//------------------------------------------------------------------
// device: the core, then the stage, then the fabric
//------------------------------------------------------------------
arm9_core dut (
	.clk(clk), .reset(reset), .ce(1'b1),
	.boot_pc(32'h0200_0000), .boot_sp(32'h0200_0300),
	.bus_addr(c_addr), .bus_wdata(c_wdata), .bus_be(c_be),
	.bus_rd(c_rd), .bus_wr(c_wr),
	.bus_rdata(c_rdata), .bus_ready(c_ready),
	.irq(1'b0), .fiq(1'b0), .halt(1'b0),
	.halted(halted), .thumb_state(thumb_state), .pc_out(pc_out),
	.cp15_ctrl(cp15_ctrl), .cp15_c9d(cp15_c9d), .cp15_c9i(cp15_c9i),
	.hle_go(), .hle_num(),
	.hle_r0(), .hle_r1(), .hle_r2(), .hle_r3(),
	.hle_done(1'b0), .hle_handled(1'b0),
	.hle_res0(32'd0), .hle_res1(32'd0), .hle_res3(32'd0),
	.hle_wr0(1'b0), .hle_wr1(1'b0), .hle_wr3(1'b0),
	.hle_b_req(1'b0), .hle_b_wr(1'b0),
	.hle_b_be(4'd0), .hle_b_addr(32'd0), .hle_b_wlane(32'd0)
);

arm9_tcm tcm9 (
	.clk(clk),
	.c1_ctrl(cp15_ctrl), .c9_dtcm(cp15_c9d), .c9_itcm(cp15_c9i),
	.c_addr(c_addr), .c_wdata(c_wdata), .c_be(c_be),
	.c_rd(c_rd), .c_wr(c_wr), .c_rdata(c_rdata), .c_ready(c_ready),
	.f_addr(f_addr), .f_wdata(f_wdata), .f_be(f_be),
	.f_rd(f_rd), .f_wr(f_wr), .f_rdata(f_rdata), .f_ready(f_ready)
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

task check_val(input [31:0] got, input [31:0] want, input [8*44-1:0] what);
	begin
		checks = checks + 1;
		if (got !== want) begin
			errors = errors + 1;
			$display("  FAIL %0s: %h, expected %h", what, got, want);
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

// run until the program's end marker, with a guard so a hung core fails
// instead of running forever
integer guard;
task run_to(input [31:0] marker, input integer limit, input [8*44-1:0] what);
	begin
		guard = 0;
		while (pc_out !== marker && guard < limit) begin
			@(posedge clk);
			guard = guard + 1;
		end
		repeat (8) @(posedge clk);
		checks = checks + 1;
		if (pc_out !== marker) begin
			errors = errors + 1;
			$display("  FAIL %0s did not reach its marker (pc = %h)",
			         what, pc_out);
			$display("       halted = %0d, bus rd=%b wr=%b addr=%h ready=%b",
			         halted, c_rd, c_wr, c_addr, c_ready);
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

//------------------------------------------------------------------
// the program (tools/gen_tcm_program.py)
//------------------------------------------------------------------
// ---- tb/tb_arm9_tcm.sv, generated by tools/gen_tcm_program.py ----
task load_tcm_prog;
	begin
		ram[18'd0] = 32'hE3A0079F;  // 02000000  mov r0, #0x027C0000   (mov r0, #0x27c0000); DTCM base 0x027C0000
		ram[18'd1] = 32'hE380000A;  // 02000004  orr r0, r0, #0xA   (orr r0, r0, #0xa); size field b00101: 16 KB
		ram[18'd2] = 32'hEE090F11;  // 02000008  mcr p15, 0, r0, c9, c1, 0   (mcr p15, #0, r0, c9, c1, #0); c9 opcode_2 0: the data TCM region
		ram[18'd3] = 32'hEE111F10;  // 0200000c  mrc p15, 0, r1, c1, c0, 0   (mrc p15, #0, r1, c1, c0, #0); c1
		ram[18'd4] = 32'hE3811801;  // 02000010  orr r1, r1, #0x10000; bit 16: data TCM enable
		ram[18'd5] = 32'hEE011F10;  // 02000014  mcr p15, 0, r1, c1, c0, 0   (mcr p15, #0, r1, c1, c0, #0)
		ram[18'd6] = 32'hE3A0279F;  // 02000018  mov r2, #0x027C0000   (mov r2, #0x27c0000); the data TCM itself
		ram[18'd7] = 32'hE3A03CBE;  // 0200001c  mov r3, #0xBE00   (mov r3, #0xbe00)
		ram[18'd8] = 32'hE38330EF;  // 02000020  orr r3, r3, #0xEF   (orr r3, r3, #0xef); 0x0000BEEF
		ram[18'd9] = 32'hE5823000;  // 02000024  str r3, [r2]; a store the fabric must not see
		ram[18'd10] = 32'hE5924000;  // 02000028  ldr r4, [r2]; read it back
		ram[18'd11] = 32'hE3A050AA;  // 0200002c  mov r5, #0xAA   (mov r5, #0xaa)
		ram[18'd12] = 32'hE5C25000;  // 02000030  strb r5, [r2]; byte lane 0
		ram[18'd13] = 32'hE5926000;  // 02000034  ldr r6, [r2]; 0x0000BEAA
		ram[18'd14] = 32'hE3A05011;  // 02000038  mov r5, #0x11
		ram[18'd15] = 32'hE5C25001;  // 0200003c  strb r5, [r2, #1]; byte lane 1
		ram[18'd16] = 32'hE5920000;  // 02000040  ldr r0, [r2]; 0x000011AA
		ram[18'd17] = 32'hE3A00020;  // 02000044  mov r0, #0x20; ITCM region: base 0, b10000 = 32 MB
		ram[18'd18] = 32'hEE090F31;  // 02000048  mcr p15, 0, r0, c9, c1, 1   (mcr p15, #0, r0, c9, c1, #1); c9 opcode_2 1: the instruction TCM
		ram[18'd19] = 32'hEE111F10;  // 0200004c  mrc p15, 0, r1, c1, c0, 0   (mrc p15, #0, r1, c1, c0, #0); c1
		ram[18'd20] = 32'hE3811701;  // 02000050  orr r1, r1, #0x40000; bit 18: instruction TCM enable
		ram[18'd21] = 32'hEE011F10;  // 02000054  mcr p15, 0, r1, c1, c0, 0   (mcr p15, #0, r1, c1, c0, #0)
		ram[18'd22] = 32'hEE19AF11;  // 02000058  mrc p15, 0, r10, c9, c1, 0   (mrc p15, #0, sl, c9, c1, #0); the data TCM region, still there
		ram[18'd23] = 32'hEE19BF31;  // 0200005c  mrc p15, 0, r11, c9, c1, 1   (mrc p15, #0, fp, c9, c1, #1); and the instruction TCM's
		ram[18'd24] = 32'hE3A07401;  // 02000060  mov r7, #0x01000000   (mov r7, #0x1000000); where libnds and blocksds run from
		ram[18'd25] = 32'hE3A08402;  // 02000064  mov r8, #0x02000000   (mov r8, #0x2000000)
		ram[18'd26] = 32'hE3888C05;  // 02000068  orr r8, r8, #0x500; the two instructions at 0x02000500
		ram[18'd27] = 32'hE5989000;  // 0200006c  ldr r9, [r8]   (ldr sb, [r8])
		ram[18'd28] = 32'hE5879000;  // 02000070  str r9, [r7]   (str sb, [r7]); mov r0, #0x5A into the ITCM
		ram[18'd29] = 32'hE5989004;  // 02000074  ldr r9, [r8, #4]   (ldr sb, [r8, #4])
		ram[18'd30] = 32'hE5879004;  // 02000078  str r9, [r7, #4]   (str sb, [r7, #4]); bx lr into the ITCM
		ram[18'd31] = 32'hE1A00000;  // 0200007c  mov r0, r0; let the store settle
		ram[18'd32] = 32'hE1A00000;  // 02000080  mov r0, r0
		ram[18'd33] = 32'hE1A0E00F;  // 02000084  mov lr, pc
		ram[18'd34] = 32'hE12FFF17;  // 02000088  bx r7; execute from 0x01000000
		ram[18'd35] = 32'hE1A0C000;  // 0200008c  mov r12, r0   (mov ip, r0); the return value: 0x5A
		ram[18'd36] = 32'hE3A00402;  // 02000090  mov r0, #0x02000000   (mov r0, #0x2000000)
		ram[18'd37] = 32'hE3800B01;  // 02000094  orr r0, r0, #0x400; scratch at 0x02000400
		ram[18'd38] = 32'hE5804000;  // 02000098  str r4, [r0]; the data TCM round trip
		ram[18'd39] = 32'hE5806004;  // 0200009c  str r6, [r0, #4]; after the byte write
		ram[18'd40] = 32'hE580C008;  // 020000a0  str r12, [r0, #8]   (str ip, [r0, #8]); what ran from the instruction TCM
		ram[18'd41] = 32'hE580A00C;  // 020000a4  str r10, [r0, #12]   (str sl, [r0, #0xc]); c9 opcode_2 0 read back
		ram[18'd42] = 32'hE580B010;  // 020000a8  str r11, [r0, #16]   (str fp, [r0, #0x10]); c9 opcode_2 1 read back
		ram[18'd43] = 32'hEAFFFFFE;  // 020000ac  b .   (b #0x20000ac); the end marker
		// the two instructions the program copies into the ITCM
		ram[18'd320] = 32'hE3A0005A;  // 02000500  mov r0, #0x5a
		ram[18'd321] = 32'hE12FFF1E;  // 02000504  bx lr
	end
endtask
// the program ends at 0x020000b0; the data block holding the two words
// sits at 0x02000500, and the results at 0x02000400

integer i;
initial begin
	for (i = 0; i < 16384; i = i + 1) lo[i]  = 32'h0000_0000;
	for (i = 0; i < 256;   i = i + 1) hi[i]  = 32'h0000_0000;
	for (i = 0; i < 65536; i = i + 1) ram[i] = 32'h0000_0000;

	load_tcm_prog;
	reset_core;
	run_to(32'h0200_00AC, 20000, "the TCM program");

	// ---- the data TCM: what the program stored and read back ----
	check_reg(4,  32'h0000_BEEF, "DTCM word round trip");
	check_reg(6,  32'h0000_BEAA, "DTCM byte lane 0");
	check_reg(12, 32'h0000_005A, "the ITCM routine's return value");
	check_reg(10, 32'h027C_000A, "c9 opcode_2 0 read back through MRC");
	check_reg(11, 32'h0000_0020, "c9 opcode_2 1 read back through MRC");

	// ---- the results block the program wrote over the fabric ----
	check_ram(16'h0100, 32'h0000_BEEF, "results: DTCM word");
	check_ram(16'h0101, 32'h0000_BEAA, "results: DTCM byte lane 0");
	check_ram(16'h0102, 32'h0000_005A, "results: ran from the ITCM");
	check_ram(16'h0103, 32'h027C_000A, "results: DTCM region");
	check_ram(16'h0104, 32'h0000_0020, "results: ITCM region");

	// ---- what the stage decodes from the core's CP15 outputs ----
	check_val(cp15_c9d, 32'h027C_000A, "the stage sees the DTCM region");
	check_val(cp15_c9i, 32'h0000_0020, "the stage sees the ITCM region");
	check_val(cp15_ctrl & 32'h0005_0000, 32'h0005_0000,
	          "both TCM enables are set in c1");

	// ---- the fabric never saw either window ----
	check_val(dtcm_saw, 32'd0, "no data-TCM access reached the fabric");
	check_val(itcm_saw, 32'd0, "no instruction-TCM access reached the fabric");
	// ...and it did serve the program and its results block
	checks = checks + 1;
	if (fab_served == 0) begin
		errors = errors + 1;
		$display("  FAIL the fabric served nothing at all");
	end

	// ---- a TCM hit answers on the cycle the core samples the request ----
	check_val(tcm_slow, 32'd0, "every TCM access answered in its one clock");
	checks = checks + 1;
	if (tcm_fast == 0) begin
		errors = errors + 1;
		$display("  FAIL no access was answered by the TCM");
	end
	checks = checks + 1;
	if (fab_slow == 0) begin
		errors = errors + 1;
		$display("  FAIL no fabric access took a wait state");
	end

	$display("  %0d TCM accesses in one clock, %0d fabric accesses served",
	         tcm_fast, fab_served);
	$display("  %0d checks", checks);
	if (errors == 0) $display("TB ARM9 TCM PASS");
	else             $display("TB ARM9 TCM FAIL: %0d error(s)", errors);
	$finish;
end

endmodule
