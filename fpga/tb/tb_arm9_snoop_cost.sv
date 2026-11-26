//============================================================================
// tb_arm9_snoop_cost — what a set-granular drop costs over a line-precise one
//
// The coherence hook drops the whole set a snooped write lands in, not only
// the line holding the word (rtl/cpu/arm9_cache_tag.sv says why: the tag
// compare would be a second asynchronous read of every tag array). This
// bench measures what that costs, in bus reads, at both ends of the range:
//
//   * four lines of one set resident and one of them snooped: the three
//     nothing wrote are dropped as well and each pays a fill to come back.
//     That is 32 bus reads to get back to where the set was, against 8 for
//     a line-precise drop -- 4x the work, and the number that says what the
//     wider drop buys and costs.
//   * a snoop into a set holding nothing, which is what a DMA writing a
//     buffer in address order does (consecutive lines are different sets):
//     nothing is dropped, nothing refills, no extra reads at all.
//
// The four lines are 0x02000400, 0x02000800, 0x02000C00 and 0x02001000:
// tags a[21:10] = 1..4, one set (a[9:5] = 0), which is the shape a four-way
// set has when it is full. The program fills all four, snoops the first,
// reads all four again, then snoops an address in set 1 and reads again.
//============================================================================
`timescale 1ns / 1ps

module tb_arm9_snoop_cost;

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

reg         snoop_wr = 0;
reg  [31:0] snoop_addr = 0;

integer checks = 0;
integer fails  = 0;

//------------------------------------------------------------------
// the fabric: 256 KB of main RAM, two cycles a beat
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
	.snoop_wr(snoop_wr), .snoop_addr(snoop_addr),
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
// the four lines, their read counters, and the markers
//------------------------------------------------------------------
localparam [31:0] END_PC = 32'h0200_0050;

// bus_addr[31:5] for the first word of each line, the whole line being one
// key because only its top bits matter here
wire l1 = (bus_addr[31:5] == 27'h0100_020);   // 0200_0400, tag 1, set 0
wire l2 = (bus_addr[31:5] == 27'h0100_040);   // 0200_0800, tag 2, set 0
wire l3 = (bus_addr[31:5] == 27'h0100_060);   // 0200_0C00, tag 3, set 0
wire l4 = (bus_addr[31:5] == 27'h0100_080);   // 0200_1000, tag 4, set 0

integer l1_reads = 0;
integer l2_reads = 0;
integer l3_reads = 0;
integer l4_reads = 0;
integer rows_seen = 0;      // reads of any of the four, for the summary
integer i;

always @(posedge clk) begin
	snoop_wr <= 1'b0;
	if (bus_rd && bus_ready) begin
		if (l1) l1_reads <= l1_reads + 1;
		if (l2) l2_reads <= l2_reads + 1;
		if (l3) l3_reads <= l3_reads + 1;
		if (l4) l4_reads <= l4_reads + 1;
		if (l1 || l2 || l3 || l4) rows_seen <= rows_seen + 1;
	end
	if (bus_wr && bus_ready && is_ram) begin
		case (bus_addr)
		// another master writes word 0 of the first line, then the cache
		// is told about it, exactly as main_bus does it
		32'h0200_1040: begin
			ram[16'h0100] <= 32'hAAAA_5555;
			snoop_wr   <= 1'b1;
			snoop_addr <= 32'h0200_0400;
		end
		// a write into set 1 (a[9:5] = 1), where nothing is resident
		32'h0200_1044: begin
			snoop_wr   <= 1'b1;
			snoop_addr <= 32'h0200_2020;
		end
		endcase
	end
end

task check_val (input [31:0] got, input [31:0] want, input [8*58:1] what);
	begin
		checks = checks + 1;
		if (got !== want) begin
			fails = fails + 1;
			$display("FAIL %0s: got %0d, wanted %0d", what, got, want);
		end else
			$display("ok   %0s", what);
	end
endtask

initial begin
	$dumpfile("tb_arm9_snoop_cost.vcd");
	$dumpvars(0, tb_arm9_snoop_cost);

	// the data cache only: the instruction cache would put code reads on
	// the same bus and there is nothing here to measure in them
	ram[16'd0]  = 32'hEE119F10;  // 02000000  mrc p15,0,r9,c1,c0,0
	ram[16'd1]  = 32'hE3A08402;  // 02000004  mov r8,#0x02000000
	ram[16'd2]  = 32'hE3899004;  // 02000008  orr r9,r9,#4   (data cache)
	ram[16'd3]  = 32'hEE019F10;  // 0200000c  mcr p15,0,r9,c1,c0,0
	// fill all four ways of set 0, one line each
	ram[16'd4]  = 32'hE5980400;  // 02000010  ldr r0,[r8,#0x400]  tag 1
	ram[16'd5]  = 32'hE3887A01;  // 02000014  orr r7,r8,#0x1000   r7 = 02001000
	ram[16'd6]  = 32'hE5980800;  // 02000018  ldr r0,[r8,#0x800]  tag 2
	ram[16'd7]  = 32'hE5980C00;  // 0200001c  ldr r0,[r8,#0xC00]  tag 3
	// line 1
	ram[16'd8]  = 32'hE5970000;  // 02000020  ldr r0,[r7]         tag 4
	ram[16'd9]  = 32'hE5870040;  // 02000024  str r0,[r7,#0x40]   marker 1
	// the snoop of tag 1 has fired by the time these retire
	ram[16'd10] = 32'hE5980400;  // 02000028  ldr r0,[r8,#0x400]
	ram[16'd11] = 32'hE5870048;  // 0200002c  str r0,[r7,#0x48]   sample
	ram[16'd12] = 32'hE5980800;  // 02000030  ldr r0,[r8,#0x800]
	ram[16'd13] = 32'hE5980C00;  // 02000034  ldr r0,[r8,#0xC00]
	ram[16'd14] = 32'hE5970000;  // 02000038  ldr r0,[r7]
	ram[16'd15] = 32'hE5870044;  // 0200003c  str r0,[r7,#0x44]   marker 2
	// line 2: the snoop into set 1, then four loads that must all hit
	ram[16'd16] = 32'hE5980400;  // 02000040  ldr r0,[r8,#0x400]
	ram[16'd17] = 32'hE5980800;  // 02000044  ldr r0,[r8,#0x800]
	ram[16'd18] = 32'hE5980C00;  // 02000048  ldr r0,[r8,#0xC00]
	ram[16'd19] = 32'hE5970000;  // 0200004c  ldr r0,[r7]
	ram[16'd20] = 32'hEAFFFFFE;  // 02000050  b .

	// the words the program loads
	ram[16'h0100] = 32'h1111_1111;   // 02000400, the word the snoop rewrites
	ram[16'h0101] = 32'h1111_1111;
	ram[16'h0200] = 32'h2222_2222;   // 02000800
	ram[16'h0300] = 32'h3333_3333;   // 02000C00
	ram[16'h0400] = 32'h4444_4444;   // 02001000

	repeat (4) @(posedge clk);
	reset = 0;

	i = 0;
	while (pc_out !== END_PC && i < 20000) begin
		@(posedge clk);
		i = i + 1;
	end
	check_val(pc_out, END_PC, "the program reached its end");
	repeat (8) @(posedge clk);

	//--------------------------------------------------------------
	// what one set-granular snoop cost four resident lines
	//--------------------------------------------------------------
	$display("  set 0: tag1 %0d reads, tag2 %0d, tag3 %0d, tag4 %0d, all four %0d",
	         l1_reads, l2_reads, l3_reads, l4_reads, rows_seen);
	check_val(l1_reads, 32'd16, "the snooped line filled, then filled again");
	check_val(l2_reads, 32'd16, "a way nothing wrote filled again too");
	check_val(l3_reads, 32'd16, "and the third");
	check_val(l4_reads, 32'd16, "and the fourth: one snoop, four fills");
	check_val(ram[16'h0412], 32'hAAAA_5555,
	          "the load after the snoop returned the new word");
	// 32 reads for the refill of the set against 8 for the line alone
	$display("  over-drop: %0d reads to refill the set, 8 for the line alone",
	         rows_seen - rows_seen / 2);
	check_val(rows_seen, 32'd64, "eight reads a line, four fills, twice");

	$display("  %0d checks", checks);
	if (fails == 0) $display("TB ARM9 SNOOP COST PASS");
	else            $display("TB ARM9 SNOOP COST FAIL: %0d error(s)", fails);
	$finish;
end

endmodule
