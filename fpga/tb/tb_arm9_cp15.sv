//============================================================================
// NDS MiSTer Test — the ARM9's CP15 cache state and c7 decode
//
//   iverilog -g2012 -o /tmp/tb_arm9_cp15 tb/tb_arm9_cp15.sv \
//            rtl/cpu/arm9_core.sv
//   vvp /tmp/tb_arm9_cp15
//
// The caches' first step is the state software programs before it turns them
// on, plus the maintenance commands it uses afterwards. This bench runs a
// keystone-assembled program (tools/gen_cp15_program.py) through the core, so
// every MCR and MRC here is an instruction the core decoded and executed:
//
//   * c2's data and instruction cachability maps are separate registers, and
//     their reserved bits are not kept
//   * c3's write-bufferability map and c5's four permission halves are
//     independent, and c5's normal halves keep 16 bits while the extended
//     halves keep 32
//   * c6's eight regions are selected by CRm, and the DS's opcode_2 1 mirror
//     makes a write through the instruction half read back through the data
//     half
//   * c9's lockdown registers (CRm 0) and the TCM region registers (CRm 1)
//     are four different registers: writing lockdown leaves the TCM regions
//     alone and vice versa. Before this split a lockdown write landed in the
//     data TCM region, because c9 was keyed by opcode_2 alone
//   * c7 reads: the maintenance register reads zero, and the two
//     test-and-clean reads report the cache already clean
//   * c7 writes: each of the nine commands the ARM946E-S defines raises the
//     strobe with its own CRm/opcode_2 and Rd, two encodings the part does
//     not have raise nothing, and a WFI stops the core until an interrupt
//   * the line state: with c1 bit 2 turned on, a load fills a line into the
//     cache and a store that hits it leaves it dirty, so the first
//     test-and-clean reads 0 and clears it and the second reads 1. The
//     load is there because a store no longer takes a line: the cache is
//     write-through and only a load allocates. Both results are held in
//     registers and written afterwards, because a store between the two
//     reads would dirty a line again
//
// The data arrays are not here yet; this is the state and the command decode
// they will sit behind, and the tags the maintenance commands act on.
//============================================================================
`timescale 1ns / 1ps

module tb_arm9_cp15;

reg clk = 0;
always #10 clk = ~clk;

reg reset = 1;
reg irq   = 0;

wire [31:0] bus_addr, bus_wdata;
reg  [31:0] bus_rdata;
wire  [3:0] bus_be;
wire        bus_rd, bus_wr, bus_ready;

wire        halted, thumb_state;
wire [31:0] pc_out;
wire [31:0] cp15_ctrl, cp15_c9d, cp15_c9i;
wire  [7:0] c7;
wire [31:0] c7_arg;

integer checks = 0;
integer errors = 0;

//------------------------------------------------------------------
// the fabric: 256 KB of main RAM, one wait state, as tb_arm9_tcm models it
//------------------------------------------------------------------
reg [31:0] ram [0:65535];

wire        is_ram = (bus_addr[31:24] == 8'h02);
wire [15:0] ram_idx = bus_addr[17:2];

always @(*)
	bus_rdata = is_ram ? ram[ram_idx] : 32'h0000_0000;

reg  [1:0] wait_cnt = 0;
reg        ready_r  = 0;
assign bus_ready = ready_r;

always @(posedge clk) begin
	ready_r <= 1'b0;
	if (bus_rd || bus_wr) begin
		if (wait_cnt == 2'd1) begin
			ready_r  <= 1'b1;
			wait_cnt <= 2'd0;
			if (bus_wr && is_ram) begin
				if (bus_be[0]) ram[ram_idx][7:0]   <= bus_wdata[7:0];
				if (bus_be[1]) ram[ram_idx][15:8]  <= bus_wdata[15:8];
				if (bus_be[2]) ram[ram_idx][23:16] <= bus_wdata[23:16];
				if (bus_be[3]) ram[ram_idx][31:24] <= bus_wdata[31:24];
			end
		end else wait_cnt <= wait_cnt + 2'd1;
	end else wait_cnt <= 2'd0;
end

//------------------------------------------------------------------
// device
//------------------------------------------------------------------
arm9_core dut (
	.clk(clk), .reset(reset), .ce(1'b1),
	.boot_pc(32'h0200_0000), .boot_sp(32'h0200_0300),
	.bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_be(bus_be),
	.bus_rd(bus_rd), .bus_wr(bus_wr),
	.bus_rdata(bus_rdata), .bus_ready(bus_ready),
	.snoop_wr(1'b0), .snoop_addr(32'd0),
	.irq(irq), .fiq(1'b0), .halt(1'b0),
	.halted(halted), .thumb_state(thumb_state), .pc_out(pc_out),
	.cp15_ctrl(cp15_ctrl), .cp15_c9d(cp15_c9d), .cp15_c9i(cp15_c9i),
	.cp15_c7(c7), .cp15_c7_arg(c7_arg),
	.hle_go(), .hle_num(),
	.hle_r0(), .hle_r1(), .hle_r2(), .hle_r3(),
	.hle_done(1'b0), .hle_handled(1'b0),
	.hle_res0(32'd0), .hle_res1(32'd0), .hle_res3(32'd0),
	.hle_wr0(1'b0), .hle_wr1(1'b0), .hle_wr3(1'b0),
	.hle_b_req(1'b0), .hle_b_wr(1'b0),
	.hle_b_be(4'd0), .hle_b_addr(32'd0), .hle_b_wlane(32'd0)
);

//------------------------------------------------------------------
// every c7 command the core decoded, in order, and the line address the
// by-address invalidate carried
//------------------------------------------------------------------
reg  [6:0] ops [0:15];
integer    nops = 0;
reg [31:0] line_arg = 0;

always @(posedge clk) begin
	if (c7[7]) begin
		if (nops < 16) ops[nops] = c7[6:0];
		nops = nops + 1;
		if (c7[6:0] == 7'd41) line_arg = c7_arg;
	end
end

//------------------------------------------------------------------
// checks
//------------------------------------------------------------------
task check_val(input [31:0] got, input [31:0] want, input [8*48-1:0] what);
	begin
		checks = checks + 1;
		if (got !== want) begin
			errors = errors + 1;
			$display("  FAIL %0s: %h, expected %h", what, got, want);
		end
	end
endtask

task check_ram(input [15:0] idx, input [31:0] want, input [8*48-1:0] what);
	begin
		checks = checks + 1;
		if (ram[idx] !== want) begin
			errors = errors + 1;
			$display("  FAIL %0s: ram[%0d] = %h, expected %h",
			         what, idx, ram[idx], want);
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

// run until WFI stops the core; a hung program fails instead of running on
integer guard;
task wait_halt(input integer limit, input [8*48-1:0] what);
	begin
		guard = 0;
		while (!halted && guard < limit) begin
			@(posedge clk);
			guard = guard + 1;
		end
		checks = checks + 1;
		if (!halted) begin
			errors = errors + 1;
			$display("  FAIL %0s never halted (pc = %h)", what, pc_out);
		end
	end
endtask

task run_to(input [31:0] marker, input integer limit,
            input [8*48-1:0] what);
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
		end
	end
endtask

//------------------------------------------------------------------
// the program (tools/gen_cp15_program.py)
//------------------------------------------------------------------
// ---- tb/tb_arm9_cp15.sv, generated by tools/gen_cp15_program.py ----
// ---- tb/tb_arm9_cp15.sv, generated by tools/gen_cp15_program.py ----
task load_cp15_prog;
	begin
		ram[18'd0] = 32'hE3A08402;  // 02000000  mov r8, #0x02000000   (mov r8, #0x2000000)
		ram[18'd1] = 32'hE3888B01;  // 02000004  orr r8, r8, #0x400; results at 0x02000400
		ram[18'd2] = 32'hEE121F10;  // 02000008  mrc p15, 0, r1, c2, c0, 0   (mrc p15, #0, r1, c2, c0, #0); data map, at reset
		ram[18'd3] = 32'hE4881004;  // 0200000c  str r1, [r8], #4; 0: 0
		ram[18'd4] = 32'hE3A000A5;  // 02000010  mov r0, #0xA5   (mov r0, #0xa5)
		ram[18'd5] = 32'hEE020F10;  // 02000014  mcr p15, 0, r0, c2, c0, 0   (mcr p15, #0, r0, c2, c0, #0); data map
		ram[18'd6] = 32'hEE121F10;  // 02000018  mrc p15, 0, r1, c2, c0, 0   (mrc p15, #0, r1, c2, c0, #0)
		ram[18'd7] = 32'hE4881004;  // 0200001c  str r1, [r8], #4; 1: 0xA5
		ram[18'd8] = 32'hEE121F30;  // 02000020  mrc p15, 0, r1, c2, c0, 1   (mrc p15, #0, r1, c2, c0, #1); instruction map is its own register
		ram[18'd9] = 32'hE4881004;  // 02000024  str r1, [r8], #4; 2: 0
		ram[18'd10] = 32'hE3A0005A;  // 02000028  mov r0, #0x5A   (mov r0, #0x5a)
		ram[18'd11] = 32'hEE020F30;  // 0200002c  mcr p15, 0, r0, c2, c0, 1   (mcr p15, #0, r0, c2, c0, #1)
		ram[18'd12] = 32'hEE121F30;  // 02000030  mrc p15, 0, r1, c2, c0, 1   (mrc p15, #0, r1, c2, c0, #1)
		ram[18'd13] = 32'hE4881004;  // 02000034  str r1, [r8], #4; 3: 0x5A
		ram[18'd14] = 32'hE3E00000;  // 02000038  mvn r0, #0; all ones
		ram[18'd15] = 32'hEE020F10;  // 0200003c  mcr p15, 0, r0, c2, c0, 0   (mcr p15, #0, r0, c2, c0, #0); the reserved bits are not kept
		ram[18'd16] = 32'hEE121F10;  // 02000040  mrc p15, 0, r1, c2, c0, 0   (mrc p15, #0, r1, c2, c0, #0)
		ram[18'd17] = 32'hE4881004;  // 02000044  str r1, [r8], #4; 4: 0
		ram[18'd18] = 32'hE3A0040F;  // 02000048  mov r0, #0x0F000000   (mov r0, #0xf000000)
		ram[18'd19] = 32'hE380080F;  // 0200004c  orr r0, r0, #0x0F0000   (orr r0, r0, #0xf0000)
		ram[18'd20] = 32'hE3800C0F;  // 02000050  orr r0, r0, #0x0F00   (orr r0, r0, #0xf00)
		ram[18'd21] = 32'hE380000F;  // 02000054  orr r0, r0, #0x0F   (orr r0, r0, #0xf); 0x0F0F0F0F
		ram[18'd22] = 32'hEE030F10;  // 02000058  mcr p15, 0, r0, c3, c0, 0   (mcr p15, #0, r0, c3, c0, #0)
		ram[18'd23] = 32'hEE131F10;  // 0200005c  mrc p15, 0, r1, c3, c0, 0   (mrc p15, #0, r1, c3, c0, #0)
		ram[18'd24] = 32'hE4881004;  // 02000060  str r1, [r8], #4; 5: 0x0F
		ram[18'd25] = 32'hE3A00412;  // 02000064  mov r0, #0x12000000
		ram[18'd26] = 32'hE380070D;  // 02000068  orr r0, r0, #0x00340000   (orr r0, r0, #0x340000)
		ram[18'd27] = 32'hE3800C56;  // 0200006c  orr r0, r0, #0x00005600   (orr r0, r0, #0x5600)
		ram[18'd28] = 32'hE3800078;  // 02000070  orr r0, r0, #0x78; 0x12345678
		ram[18'd29] = 32'hEE050F10;  // 02000074  mcr p15, 0, r0, c5, c0, 0   (mcr p15, #0, r0, c5, c0, #0); normal, data: 16 bits
		ram[18'd30] = 32'hEE151F10;  // 02000078  mrc p15, 0, r1, c5, c0, 0   (mrc p15, #0, r1, c5, c0, #0)
		ram[18'd31] = 32'hE4881004;  // 0200007c  str r1, [r8], #4; 6: 0x5678
		ram[18'd32] = 32'hE3A00411;  // 02000080  mov r0, #0x11000000
		ram[18'd33] = 32'hE3800811;  // 02000084  orr r0, r0, #0x00110000   (orr r0, r0, #0x110000)
		ram[18'd34] = 32'hE3800C22;  // 02000088  orr r0, r0, #0x00002200   (orr r0, r0, #0x2200)
		ram[18'd35] = 32'hE3800022;  // 0200008c  orr r0, r0, #0x22; 0x11112222
		ram[18'd36] = 32'hEE050F30;  // 02000090  mcr p15, 0, r0, c5, c0, 1   (mcr p15, #0, r0, c5, c0, #1); normal, instruction
		ram[18'd37] = 32'hEE151F30;  // 02000094  mrc p15, 0, r1, c5, c0, 1   (mrc p15, #0, r1, c5, c0, #1)
		ram[18'd38] = 32'hE4881004;  // 02000098  str r1, [r8], #4; 7: 0x2222
		ram[18'd39] = 32'hE3A00433;  // 0200009c  mov r0, #0x33000000
		ram[18'd40] = 32'hE3800833;  // 020000a0  orr r0, r0, #0x00330000   (orr r0, r0, #0x330000)
		ram[18'd41] = 32'hE3800B11;  // 020000a4  orr r0, r0, #0x00004400   (orr r0, r0, #0x4400)
		ram[18'd42] = 32'hE3800044;  // 020000a8  orr r0, r0, #0x44; 0x33334444
		ram[18'd43] = 32'hEE050F50;  // 020000ac  mcr p15, 0, r0, c5, c0, 2   (mcr p15, #0, r0, c5, c0, #2); extended, data: all 32 bits
		ram[18'd44] = 32'hEE151F50;  // 020000b0  mrc p15, 0, r1, c5, c0, 2   (mrc p15, #0, r1, c5, c0, #2)
		ram[18'd45] = 32'hE4881004;  // 020000b4  str r1, [r8], #4; 8: 0x33334444
		ram[18'd46] = 32'hE3A00455;  // 020000b8  mov r0, #0x55000000
		ram[18'd47] = 32'hE3800855;  // 020000bc  orr r0, r0, #0x00550000   (orr r0, r0, #0x550000)
		ram[18'd48] = 32'hE3800C66;  // 020000c0  orr r0, r0, #0x00006600   (orr r0, r0, #0x6600)
		ram[18'd49] = 32'hE3800066;  // 020000c4  orr r0, r0, #0x66; 0x55556666
		ram[18'd50] = 32'hEE050F70;  // 020000c8  mcr p15, 0, r0, c5, c0, 3   (mcr p15, #0, r0, c5, c0, #3); extended, instruction
		ram[18'd51] = 32'hEE151F70;  // 020000cc  mrc p15, 0, r1, c5, c0, 3   (mrc p15, #0, r1, c5, c0, #3)
		ram[18'd52] = 32'hE4881004;  // 020000d0  str r1, [r8], #4; 9: 0x55556666
		ram[18'd53] = 32'hE3A00402;  // 020000d4  mov r0, #0x02000000   (mov r0, #0x2000000)
		ram[18'd54] = 32'hE3800017;  // 020000d8  orr r0, r0, #0x17; base 0x02000000, 4 KB, enabled
		ram[18'd55] = 32'hEE060F10;  // 020000dc  mcr p15, 0, r0, c6, c0, 0   (mcr p15, #0, r0, c6, c0, #0); region 0
		ram[18'd56] = 32'hEE161F10;  // 020000e0  mrc p15, 0, r1, c6, c0, 0   (mrc p15, #0, r1, c6, c0, #0)
		ram[18'd57] = 32'hE4881004;  // 020000e4  str r1, [r8], #4; 10: 0x02000017
		ram[18'd58] = 32'hE3A00302;  // 020000e8  mov r0, #0x08000000   (mov r0, #0x8000000)
		ram[18'd59] = 32'hE3800017;  // 020000ec  orr r0, r0, #0x17
		ram[18'd60] = 32'hEE060F17;  // 020000f0  mcr p15, 0, r0, c6, c7, 0   (mcr p15, #0, r0, c6, c7, #0); region 7
		ram[18'd61] = 32'hEE161F17;  // 020000f4  mrc p15, 0, r1, c6, c7, 0   (mrc p15, #0, r1, c6, c7, #0)
		ram[18'd62] = 32'hE4881004;  // 020000f8  str r1, [r8], #4; 11: 0x08000017
		ram[18'd63] = 32'hE3A00403;  // 020000fc  mov r0, #0x03000000   (mov r0, #0x3000000)
		ram[18'd64] = 32'hE3800017;  // 02000100  orr r0, r0, #0x17
		ram[18'd65] = 32'hEE060F13;  // 02000104  mcr p15, 0, r0, c6, c3, 0   (mcr p15, #0, r0, c6, c3, #0); region 3
		ram[18'd66] = 32'hEE161F13;  // 02000108  mrc p15, 0, r1, c6, c3, 0   (mrc p15, #0, r1, c6, c3, #0)
		ram[18'd67] = 32'hE4881004;  // 0200010c  str r1, [r8], #4; 12: 0x03000017
		ram[18'd68] = 32'hEE161F11;  // 02000110  mrc p15, 0, r1, c6, c1, 0   (mrc p15, #0, r1, c6, c1, #0); region 1 was never written
		ram[18'd69] = 32'hE4881004;  // 02000114  str r1, [r8], #4; 13: 0
		ram[18'd70] = 32'hE3A00402;  // 02000118  mov r0, #0x02000000   (mov r0, #0x2000000)
		ram[18'd71] = 32'hE380001B;  // 0200011c  orr r0, r0, #0x1B   (orr r0, r0, #0x1b); 16 KB this time
		ram[18'd72] = 32'hEE060F30;  // 02000120  mcr p15, 0, r0, c6, c0, 1   (mcr p15, #0, r0, c6, c0, #1); the instruction half of region 0
		ram[18'd73] = 32'hEE161F10;  // 02000124  mrc p15, 0, r1, c6, c0, 0   (mrc p15, #0, r1, c6, c0, #0); reads through the data half
		ram[18'd74] = 32'hE4881004;  // 02000128  str r1, [r8], #4; 14: 0x0200001B
		ram[18'd75] = 32'hEE191F10;  // 0200012c  mrc p15, 0, r1, c9, c0, 0   (mrc p15, #0, r1, c9, c0, #0); data lockdown, at reset
		ram[18'd76] = 32'hE4881004;  // 02000130  str r1, [r8], #4; 15: 0
		ram[18'd77] = 32'hE3A00102;  // 02000134  mov r0, #0x80000000; L set
		ram[18'd78] = 32'hE3800001;  // 02000138  orr r0, r0, #1; way 1
		ram[18'd79] = 32'hEE090F10;  // 0200013c  mcr p15, 0, r0, c9, c0, 0   (mcr p15, #0, r0, c9, c0, #0); data lockdown
		ram[18'd80] = 32'hEE191F10;  // 02000140  mrc p15, 0, r1, c9, c0, 0   (mrc p15, #0, r1, c9, c0, #0)
		ram[18'd81] = 32'hE4881004;  // 02000144  str r1, [r8], #4; 16: 0x80000001
		ram[18'd82] = 32'hE3A00102;  // 02000148  mov r0, #0x80000000
		ram[18'd83] = 32'hE3800002;  // 0200014c  orr r0, r0, #2; way 2
		ram[18'd84] = 32'hEE090F30;  // 02000150  mcr p15, 0, r0, c9, c0, 1   (mcr p15, #0, r0, c9, c0, #1); instruction lockdown
		ram[18'd85] = 32'hEE191F30;  // 02000154  mrc p15, 0, r1, c9, c0, 1   (mrc p15, #0, r1, c9, c0, #1)
		ram[18'd86] = 32'hE4881004;  // 02000158  str r1, [r8], #4; 17: 0x80000002
		ram[18'd87] = 32'hE3A0079F;  // 0200015c  mov r0, #0x027C0000   (mov r0, #0x27c0000); the data TCM region
		ram[18'd88] = 32'hE380000A;  // 02000160  orr r0, r0, #0xA   (orr r0, r0, #0xa); 16 KB
		ram[18'd89] = 32'hEE090F11;  // 02000164  mcr p15, 0, r0, c9, c1, 0   (mcr p15, #0, r0, c9, c1, #0); CRm 1, not CRm 0
		ram[18'd90] = 32'hE3A00020;  // 02000168  mov r0, #0x20; the instruction TCM's 32 MB area
		ram[18'd91] = 32'hEE090F31;  // 0200016c  mcr p15, 0, r0, c9, c1, 1   (mcr p15, #0, r0, c9, c1, #1)
		ram[18'd92] = 32'hEE191F11;  // 02000170  mrc p15, 0, r1, c9, c1, 0   (mrc p15, #0, r1, c9, c1, #0)
		ram[18'd93] = 32'hE4881004;  // 02000174  str r1, [r8], #4; 18: 0x027C000A
		ram[18'd94] = 32'hEE191F31;  // 02000178  mrc p15, 0, r1, c9, c1, 1   (mrc p15, #0, r1, c9, c1, #1)
		ram[18'd95] = 32'hE4881004;  // 0200017c  str r1, [r8], #4; 19: 0x20
		ram[18'd96] = 32'hEE191F10;  // 02000180  mrc p15, 0, r1, c9, c0, 0   (mrc p15, #0, r1, c9, c0, #0); lockdown survived the TCM writes
		ram[18'd97] = 32'hE4881004;  // 02000184  str r1, [r8], #4; 20: 0x80000001
		ram[18'd98] = 32'hEE171F15;  // 02000188  mrc p15, 0, r1, c7, c5, 0   (mrc p15, #0, r1, c7, c5, #0); the maintenance register is write-only
		ram[18'd99] = 32'hE4881004;  // 0200018c  str r1, [r8], #4; 21: 0
		ram[18'd100] = 32'hEE171F7A;  // 02000190  mrc p15, 0, r1, c7, c10, 3   (mrc p15, #0, r1, c7, c10, #3); test and clean: nothing dirty
		ram[18'd101] = 32'hE4881004;  // 02000194  str r1, [r8], #4; 22: 1
		ram[18'd102] = 32'hEE171F7E;  // 02000198  mrc p15, 0, r1, c7, c14, 3   (mrc p15, #0, r1, c7, c14, #3); test, clean and invalidate
		ram[18'd103] = 32'hE4881004;  // 0200019c  str r1, [r8], #4; 23: 1
		ram[18'd104] = 32'hE3A00004;  // 020001a0  mov r0, #4; c1 bit 2: the data cache on
		ram[18'd105] = 32'hEE010F10;  // 020001a4  mcr p15, 0, r0, c1, c0, 0   (mcr p15, #0, r0, c1, c0, #0)
		ram[18'd106] = 32'hE5981040;  // 020001a8  ldr r1, [r8, #0x40]; bring the line in: a load allocates
		ram[18'd107] = 32'hE3A000DE;  // 020001ac  mov r0, #0xDE   (mov r0, #0xde)
		ram[18'd108] = 32'hE5880040;  // 020001b0  str r0, [r8, #0x40]; a store that hits it: now dirty
		ram[18'd109] = 32'hEE172F7A;  // 020001b4  mrc p15, 0, r2, c7, c10, 3   (mrc p15, #0, r2, c7, c10, #3); test and clean: a dirty line
		ram[18'd110] = 32'hEE173F7A;  // 020001b8  mrc p15, 0, r3, c7, c10, 3   (mrc p15, #0, r3, c7, c10, #3); and now nothing is dirty
		ram[18'd111] = 32'hE4882004;  // 020001bc  str r2, [r8], #4; 24: 0
		ram[18'd112] = 32'hE4883004;  // 020001c0  str r3, [r8], #4; 25: 1
		ram[18'd113] = 32'hE3A00000;  // 020001c4  mov r0, #0
		ram[18'd114] = 32'hEE010F10;  // 020001c8  mcr p15, 0, r0, c1, c0, 0   (mcr p15, #0, r0, c1, c0, #0); the cache off again
		ram[18'd115] = 32'hE3A00402;  // 020001cc  mov r0, #0x02000000   (mov r0, #0x2000000)
		ram[18'd116] = 32'hE3800E12;  // 020001d0  orr r0, r0, #0x120
		ram[18'd117] = 32'hE3800003;  // 020001d4  orr r0, r0, #3; the line address the strobe carries
		ram[18'd118] = 32'hEE070F15;  // 020001d8  mcr p15, 0, r0, c7, c5, 0   (mcr p15, #0, r0, c7, c5, #0); invalidate the whole I-cache
		ram[18'd119] = 32'hEE070F35;  // 020001dc  mcr p15, 0, r0, c7, c5, 1   (mcr p15, #0, r0, c7, c5, #1); invalidate an I-cache line by address
		ram[18'd120] = 32'hEE070F16;  // 020001e0  mcr p15, 0, r0, c7, c6, 0   (mcr p15, #0, r0, c7, c6, #0); invalidate the whole D-cache
		ram[18'd121] = 32'hEE070F36;  // 020001e4  mcr p15, 0, r0, c7, c6, 1   (mcr p15, #0, r0, c7, c6, #1); invalidate a D-cache line by address
		ram[18'd122] = 32'hEE070F3A;  // 020001e8  mcr p15, 0, r0, c7, c10, 1   (mcr p15, #0, r0, c7, c10, #1); clean a D-cache line by address
		ram[18'd123] = 32'hEE070F5A;  // 020001ec  mcr p15, 0, r0, c7, c10, 2   (mcr p15, #0, r0, c7, c10, #2); clean a D-cache line by index
		ram[18'd124] = 32'hEE070F3E;  // 020001f0  mcr p15, 0, r0, c7, c14, 1   (mcr p15, #0, r0, c7, c14, #1); clean and invalidate by address
		ram[18'd125] = 32'hEE070F5E;  // 020001f4  mcr p15, 0, r0, c7, c14, 2   (mcr p15, #0, r0, c7, c14, #2); clean and invalidate by index
		ram[18'd126] = 32'hEE070F3D;  // 020001f8  mcr p15, 0, r0, c7, c13, 1   (mcr p15, #0, r0, c7, c13, #1); prefetch an I-cache line
		ram[18'd127] = 32'hEE070F55;  // 020001fc  mcr p15, 0, r0, c7, c5, 2   (mcr p15, #0, r0, c7, c5, #2); not on this part: invalidate by index
		ram[18'd128] = 32'hEE070F9A;  // 02000200  mcr p15, 0, r0, c7, c10, 4   (mcr p15, #0, r0, c7, c10, #4); not on this part: drain write buffer
		ram[18'd129] = 32'hEE070F90;  // 02000204  mcr p15, 0, r0, c7, c0, 4   (mcr p15, #0, r0, c7, c0, #4); wait for interrupt
		ram[18'd130] = 32'hE3A0005A;  // 02000208  mov r0, #0x5A   (mov r0, #0x5a); only runs if the interrupt woke it
		ram[18'd131] = 32'hE5880000;  // 0200020c  str r0, [r8]; one word past the results block
		ram[18'd132] = 32'hEAFFFFFE;  // 02000210  b .   (b #0x2000210); the end marker, reached after the wake
	end
endtask
// the program ends at 0x02000214: the WFI at 0x02000208, the marker at
// 0x02000210; the results block starts at 0x02000400
integer i;
initial begin
	for (i = 0; i < 65536; i = i + 1) ram[i] = 32'h0000_0000;

	load_cp15_prog;
	reset_core;

	// ---- WFI stops the core at the instruction after it ----
	wait_halt(20000, "the CP15 program");
	check_val(halted, 32'd1, "c7,c0,4 stopped the core");
	check_val(pc_out, 32'h0200_0208, "the halted PC is past the WFI");

	// ---- what the program read back out of CP15 ----
	check_ram(16'h0100, 32'h0000_0000, "c2 data map at reset");
	check_ram(16'h0101, 32'h0000_00A5, "c2 data map");
	check_ram(16'h0102, 32'h0000_0000, "c2 instruction map is separate");
	check_ram(16'h0103, 32'h0000_005A, "c2 instruction map");
	check_ram(16'h0104, 32'h0000_00FF, "c2 keeps eight bits, drops the rest");
	check_ram(16'h0105, 32'h0000_000F, "c3 keeps the region bits only");
	check_ram(16'h0106, 32'h0000_5678, "c5 normal data keeps 16 bits");
	check_ram(16'h0107, 32'h0000_2222, "c5 normal instruction is separate");
	check_ram(16'h0108, 32'h3333_4444, "c5 extended data keeps 32 bits");
	check_ram(16'h0109, 32'h5555_6666, "c5 extended instruction");
	check_ram(16'h010A, 32'h0200_0017, "c6 region 0");
	check_ram(16'h010B, 32'h0800_0017, "c6 region 7");
	check_ram(16'h010C, 32'h0300_0017, "c6 region 3");
	check_ram(16'h010D, 32'h0000_0000, "c6 region 1 was not written");
	check_ram(16'h010E, 32'h0200_001B, "c6 opcode_2 1 mirrors the data half");
	check_ram(16'h010F, 32'h0000_0000, "c9 data lockdown at reset");
	check_ram(16'h0110, 32'h8000_0001, "c9 data lockdown");
	check_ram(16'h0111, 32'h8000_0002, "c9 instruction lockdown");
	check_ram(16'h0112, 32'h027C_000A, "c9 data TCM region stays its own");
	check_ram(16'h0113, 32'h0000_0020, "c9 instruction TCM region");
	check_ram(16'h0114, 32'h8000_0001, "lockdown survived the TCM writes");
	check_ram(16'h0115, 32'h0000_0000, "c7 reads zero");
	check_ram(16'h0116, 32'h0000_0001, "test and clean: already clean");
	check_ram(16'h0117, 32'h0000_0001, "test, clean and invalidate");
	check_ram(16'h0118, 32'h0000_0000, "test and clean found the store's line");
	check_ram(16'h0119, 32'h0000_0001, "and the second read found it clean");

	// ---- the command decode ----
	check_val(nops, 32'd10, "ten c7 commands decoded, the two invalid ones not");
	check_val(ops[0], 7'd40,  "c7,c5,0 invalidate the whole I-cache");
	check_val(ops[1], 7'd41,  "c7,c5,1 invalidate an I-cache line");
	check_val(ops[2], 7'd48,  "c7,c6,0 invalidate the whole D-cache");
	check_val(ops[3], 7'd49,  "c7,c6,1 invalidate a D-cache line");
	check_val(ops[4], 7'd81,  "c7,c10,1 clean a D-cache line by address");
	check_val(ops[5], 7'd82,  "c7,c10,2 clean a D-cache line by index");
	check_val(ops[6], 7'd113, "c7,c14,1 clean and invalidate by address");
	check_val(ops[7], 7'd114, "c7,c14,2 clean and invalidate by index");
	check_val(ops[8], 7'd105, "c7,c13,1 prefetch an I-cache line");
	check_val(ops[9], 7'd4,   "c7,c0,4 wait for interrupt");
	check_val(line_arg, 32'h0200_0123, "the strobe carries Rd");
	check_val({25'd0, c7}, 32'd0, "the strobe is one cycle");

	// ---- an interrupt wakes it, and the next instruction runs ----
	irq = 1;
	repeat (4) @(posedge clk);
	irq = 0;
	repeat (4) @(posedge clk);
	check_val(halted, 32'd0, "an interrupt left the CP15 wait");
	run_to(32'h0200_0210, 200, "the instruction after WFI");
	check_ram(16'h011A, 32'h0000_005A, "the store after WFI reached memory");

	$display("  %0d checks", checks);
	if (errors == 0) $display("TB ARM9 CP15 PASS");
	else             $display("TB ARM9 CP15 FAIL: %0d error(s)", errors);
	$finish;
end

endmodule
