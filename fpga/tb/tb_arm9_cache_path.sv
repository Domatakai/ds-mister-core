//============================================================================
// tb_arm9_cache_path — the data cache serving loads
//
// The tags say whether a line is here; this bench is about the word that
// comes back. A program enables c1 bit 2, loads a word it has never touched,
// loads it again, reads two more words of the same line, stores into the
// line, reads it back, reads a byte and a halfword out of the cached word,
// fills a second line into the same set, invalidates the whole cache, reads
// again, and finally turns the cache off and reads once more.
//
// The bus is watched rather than the registers alone, because a hit is a
// statement about the bus: a load the cache serves must not put a read on it
// at all. The counter adds up every completed read of the first data line's
// 32 bytes, and the program records the counter at ten points in its run, so
// the bench says exactly what each step cost:
//
//   9   the first load: its own read, then the eight-word line fill
//   9   the second load of the same word -- a hit, no bus read
//   9   a third load, of the next word of the line -- a hit
//   9   and a fourth, of the word after that -- a hit
//   9   a store into the line, then a load of it: still a hit, and the value
//       is the one just stored, which is only true if the store updated the
//       array as well as memory
//   9   a byte load out of that line -- a hit, and the byte is the one the
//       address picks out of the word, not the low byte of it
//   9   a halfword load -- the same
//   9   a second line, in the same set, fills into the next way and does not
//       disturb the first: reading the first again is still a hit and still
//       returns its own word
//   18  invalidate-all, then a load: a miss, so one read and a new fill
//   19  c1 bit 2 off, then a load: no cache, so the bus answers
//
// Values are checked too, but they cannot tell a hit from a miss on their
// own: memory holds the same words. The count can, and the count is what
// fails if the array is never read, read with the wrong way, or written with
// the wrong index.
//============================================================================
`timescale 1ns / 1ps

module tb_arm9_cache_path;

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
integer fails  = 0;

//------------------------------------------------------------------
// the fabric: 256 KB of main RAM, two cycles a beat, as tb_arm9_cp15 has it
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
	end
end

arm9_core dut (
	.clk(clk), .reset(reset), .ce(1'b1),
	.boot_pc(32'h0200_0000), .boot_sp(32'h0200_0300),
	.bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_be(bus_be),
	.bus_rd(bus_rd), .bus_wr(bus_wr),
	.bus_rdata(bus_rdata), .bus_ready(bus_ready),
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
// the counter: completed reads of the first data line, and the samples
//------------------------------------------------------------------
localparam [31:0] LINE = 32'h0200_0400;
localparam [31:0] END_PC = 32'h0200_0084;

integer line_reads = 0;
reg [31:0] at [0:9];
integer i;

always @(posedge clk) begin
	if (bus_rd && bus_ready && bus_addr[31:5] == LINE[31:5])
		line_reads <= line_reads + 1;
	if (bus_wr && bus_ready && is_ram) begin
		case (bus_addr)
		32'h0200_0440: at[0] <= line_reads;
		32'h0200_0444: at[1] <= line_reads;
		32'h0200_0448: at[2] <= line_reads;
		32'h0200_044C: at[3] <= line_reads;
		32'h0200_0458: at[4] <= line_reads;
		32'h0200_045C: at[5] <= line_reads;
		32'h0200_0460: at[6] <= line_reads;
		32'h0200_0464: at[7] <= line_reads;
		32'h0200_0450: at[8] <= line_reads;
		32'h0200_0454: at[9] <= line_reads;
		endcase
	end
end

task check (input [8*56:1] what, input cond);
	begin
		checks = checks + 1;
		if (cond !== 1'b1) begin
			fails = fails + 1;
			$display("FAIL %0s", what);
		end else
			$display("ok   %0s", what);
	end
endtask

task check_val (input [31:0] got, input [31:0] want, input [8*56:1] what);
	begin
		checks = checks + 1;
		if (got !== want) begin
			fails = fails + 1;
			$display("FAIL %0s: got %h, wanted %h", what, got, want);
		end else
			$display("ok   %0s", what);
	end
endtask

initial begin
	$dumpfile("tb_arm9_cache_path.vcd");
	$dumpvars(0, tb_arm9_cache_path);

	// the program, hand-assembled; the comments are the source
	ram[16'd0]  = 32'hE3A08402;  // 02000000  mov r8, #0x02000000
	ram[16'd1]  = 32'hE3888B01;  // 02000004  orr r8, r8, #0x400
	ram[16'd2]  = 32'hEE119F10;  // 02000008  mrc p15,0,r9,c1,c0,0
	ram[16'd3]  = 32'hE3899004;  // 0200000c  orr r9, r9, #4      (data cache)
	ram[16'd4]  = 32'hEE019F10;  // 02000010  mcr p15,0,r9,c1,c0,0
	ram[16'd5]  = 32'hE5981000;  // 02000014  ldr r1,[r8]         miss + fill
	ram[16'd6]  = 32'hE5982000;  // 02000018  ldr r2,[r8]         hit
	ram[16'd7]  = 32'hE5882040;  // 0200001c  str r2,[r8,#0x40]   sample 0
	ram[16'd8]  = 32'hE5983004;  // 02000020  ldr r3,[r8,#4]      hit, next word
	ram[16'd9]  = 32'hE5883044;  // 02000024  str r3,[r8,#0x44]   sample 1
	ram[16'd10] = 32'hE5984008;  // 02000028  ldr r4,[r8,#8]      hit, word 2
	ram[16'd11] = 32'hE5884048;  // 0200002c  str r4,[r8,#0x48]   sample 2
	ram[16'd12] = 32'hE3A00055;  // 02000030  mov r0, #0x55
	ram[16'd13] = 32'hE3800C55;  // 02000034  orr r0, r0, #0x5500   r0 = 0x5555
	ram[16'd14] = 32'hE5880008;  // 02000038  str r0,[r8,#8]      store into the line
	ram[16'd15] = 32'hE5985008;  // 0200003c  ldr r5,[r8,#8]      hit, the stored value
	ram[16'd16] = 32'hE588504C;  // 02000040  str r5,[r8,#0x4c]   sample 3
	ram[16'd17] = 32'hE5D80005;  // 02000044  ldrb r0,[r8,#5]      hit, byte 1 of word 1
	ram[16'd18] = 32'hE5880058;  // 02000048  str r0,[r8,#0x58]   sample 4
	ram[16'd19] = 32'hE1D810B6;  // 0200004c  ldrh r1,[r8,#6]      hit, halfword 1 of word 1
	ram[16'd20] = 32'hE588105C;  // 02000050  str r1,[r8,#0x5c]   sample 5
	ram[16'd21] = 32'hE5984400;  // 02000054  ldr r4,[r8,#0x400]   second line, same set
	ram[16'd22] = 32'hE5884060;  // 02000058  str r4,[r8,#0x60]   sample 6
	ram[16'd23] = 32'hE5985000;  // 0200005c  ldr r5,[r8]         the first line again
	ram[16'd24] = 32'hE5885064;  // 02000060  str r5,[r8,#0x64]   sample 7
	ram[16'd25] = 32'hEE070F16;  // 02000064  mcr p15,0,r0,c7,c6,0  invalidate all
	ram[16'd26] = 32'hE5986008;  // 02000068  ldr r6,[r8,#8]      miss again
	ram[16'd27] = 32'hE5886050;  // 0200006c  str r6,[r8,#0x50]   sample 8
	ram[16'd28] = 32'hE3C09004;  // 02000070  bic r9, r9, #4      cache off
	ram[16'd29] = 32'hEE019F10;  // 02000074  mcr p15,0,r9,c1,c0,0
	ram[16'd30] = 32'hE5987000;  // 02000078  ldr r7,[r8]         the bus again
	ram[16'd31] = 32'hE5887054;  // 0200007c  str r7,[r8,#0x54]   sample 9
	ram[16'd32] = 32'hEAFFFFFE;  // 02000080  b .

	// the words the program loads
	ram[16'h0100] = 32'h1111_1111;     // 02000400
	ram[16'h0101] = 32'h2233_4455;     // 02000404, four different bytes
	ram[16'h0102] = 32'h3333_3333;     // 02000408
	ram[16'h0200] = 32'h4444_4444;     // 02000800, the same set

	for (i = 0; i < 10; i = i + 1) at[i] = 32'hDEAD_DEAD;

	repeat (4) @(posedge clk);
	reset = 0;

	// run to the branch-to-self, with a cap so a hang is a failure not a wait
	i = 0;
	while (pc_out !== END_PC && i < 20000) begin
		@(posedge clk);
		i = i + 1;
	end
	check("the program reached its end", pc_out === END_PC);
	repeat (8) @(posedge clk);

	//--------------------------------------------------------------
	// what each step cost on the bus
	//--------------------------------------------------------------
	check_val(at[0], 32'd9,  "first load: one read and an eight-word fill");
	check_val(at[1], 32'd9,  "second load of the word: a hit, no read");
	check_val(at[2], 32'd9,  "next word of the line: a hit, no read");
	check_val(at[3], 32'd9,  "store into the line, load it: still a hit");
	check_val(at[4], 32'd9,  "a byte out of the cached word: a hit");
	check_val(at[5], 32'd9,  "a halfword out of it: a hit");
	check_val(at[6], 32'd9,  "a second line fills without reading the first");
	check_val(at[7], 32'd9,  "and the first line is still a hit");
	check_val(at[8], 32'd18, "invalidate, then load: a miss and a new fill");
	check_val(at[9], 32'd19, "cache off: the bus answers, no fill");

	//--------------------------------------------------------------
	// what came back
	//--------------------------------------------------------------
	check_val(ram[16'h0110], 32'h1111_1111, "the first word read");
	check_val(ram[16'h0111], 32'h2233_4455, "the second word, from the fill");
	check_val(ram[16'h0112], 32'h3333_3333, "the third word, from the fill");
	check_val(ram[16'h0113], 32'h0000_5555, "the stored word, served by the array");
	check_val(ram[16'h0116], 32'h0000_0044, "the byte lane, not the low byte");
	check_val(ram[16'h0117], 32'h0000_2233, "the halfword lane, not the low half");
	check_val(ram[16'h0118], 32'h4444_4444, "the second line's word");
	check_val(ram[16'h0119], 32'h1111_1111, "the first line survived it");
	check_val(ram[16'h0114], 32'h0000_5555, "and again after the invalidate");
	check_val(ram[16'h0115], 32'h1111_1111, "and with the cache off");
	check_val(ram[16'h0102], 32'h0000_5555, "the store reached memory too");

	$display("  %0d checks", checks);
	if (fails == 0) $display("TB ARM9 CACHE PATH PASS");
	else            $display("TB ARM9 CACHE PATH FAIL: %0d error(s)", fails);
	$finish;
end

endmodule
