//============================================================================
// tb_arm9_coherence — a write from another master drops the line it lands on
//
// The caches are write-through, so memory is authoritative and a line is
// only ever a copy. That makes the coherence question narrow: when a master
// that is not the ARM9 writes a word, both caches' copies of the line
// holding it are wrong, and the fix is to drop them. This bench drives the
// core's snoop port the way `main_bus` does -- one cycle, one word -- and
// checks what the core then does.
//
// The program enables both caches, fills a data line and a code line, and
// stops at three markers. At the first the bench writes a new word into
// main RAM behind the cache's back and snoops that address; at the second it
// snoops the address of a subroutine whose line is already cached; at the
// third it snoops an address nothing is holding.
//
//   * the load after the snoop misses and returns the new word: 16 reads of
//     the line rather than 8, and the value is the one written behind the
//     cache only because the line was dropped
//   * the same for code: the subroutine's line is fetched twice, 16 reads
//     rather than 8, because the second call comes after its snoop
//   * a snoop of an address nothing holds costs nothing -- the line beside
//     it, in the same set, is read once and serves its second load out of
//     the array: the drop is the line's, not the set's
//   * and the data line, in another set, is still at 16
//
// A cache that ignored the snoop port returns the old word and 8 reads,
// which is what this bench was written to be able to see.
//============================================================================
`timescale 1ns / 1ps

module tb_arm9_coherence;

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

// the other master, as the bench plays it
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
// the markers, the snoops they raise, and the read counters
//------------------------------------------------------------------
localparam [31:0] END_PC = 32'h0200_0054;

integer a_reads = 0;        // 0200_0400..1F, the data line
integer b_reads = 0;        // 0200_0420..3F, the line beside it
integer sub_reads = 0;      // 0200_0060..7F, the subroutine's line
integer i;

always @(posedge clk) begin
	snoop_wr <= 1'b0;
	if (bus_rd && bus_ready) begin
		if (bus_addr[31:5] == 25'h0100_020)  a_reads   <= a_reads + 1;
		if (bus_addr[31:5] == 25'h0100_021)  b_reads   <= b_reads + 1;
		if (bus_addr[31:5] == 25'h0100_003)  sub_reads <= sub_reads + 1;
	end
	if (bus_wr && bus_ready && is_ram) begin
		case (bus_addr)
		// another master writes word 0 of the data line, then the cache is
		// told about it, exactly as main_bus does it
		32'h0200_0440: begin
			ram[16'h0100] <= 32'hAAAA_5555;
			snoop_wr   <= 1'b1;
			snoop_addr <= 32'h0200_0400;
		end
		// the subroutine's line, which the fetch path is holding
		32'h0200_0448: begin
			snoop_wr   <= 1'b1;
			snoop_addr <= 32'h0200_0060;
		end
		// an address nothing has cached, in the set the line beside it is in
		32'h0200_044C: begin
			snoop_wr   <= 1'b1;
			snoop_addr <= 32'h0200_3020;
		end
		endcase
	end
end

task check (input [8*58:1] what, input cond);
	begin
		checks = checks + 1;
		if (cond !== 1'b1) begin
			fails = fails + 1;
			$display("FAIL %0s", what);
		end else
			$display("ok   %0s", what);
	end
endtask

task check_val (input [31:0] got, input [31:0] want, input [8*58:1] what);
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
	$dumpfile("tb_arm9_coherence.vcd");
	$dumpvars(0, tb_arm9_coherence);

	// line 0
	ram[16'd0]  = 32'hEE119F10;  // 02000000  mrc p15,0,r9,c1,c0,0
	ram[16'd1]  = 32'hE3A08402;  // 02000004  mov r8,#0x02000000
	ram[16'd2]  = 32'hE3888B01;  // 02000008  orr r8,r8,#0x400
	ram[16'd3]  = 32'hE3899004;  // 0200000c  orr r9,r9,#4   (data cache)
	ram[16'd4]  = 32'hE3899A01;  // 02000010  orr r9,r9,#0x1000
	ram[16'd5]  = 32'hEE019F10;  // 02000014  mcr p15,0,r9,c1,c0,0
	ram[16'd6]  = 32'hEB000010;  // 02000018  bl 02000060
	ram[16'd7]  = 32'hE5981000;  // 0200001c  ldr r1,[r8]      miss + fill
	// line 1
	ram[16'd8]  = 32'hE5982000;  // 02000020  ldr r2,[r8]      hit
	ram[16'd9]  = 32'hE5882040;  // 02000024  str r2,[r8,#0x40] marker 1
	ram[16'd10] = 32'hE5983000;  // 02000028  ldr r3,[r8]      snooped: new word
	ram[16'd11] = 32'hE5883044;  // 0200002c  str r3,[r8,#0x44] sample 1
	ram[16'd12] = 32'hE5984000;  // 02000030  ldr r4,[r8]      hit
	ram[16'd13] = 32'hE5884048;  // 02000034  str r4,[r8,#0x48] marker 2
	ram[16'd14] = 32'hEB000008;  // 02000038  bl 02000060
	ram[16'd15] = 32'hEB000007;  // 0200003c  bl 02000060     after the snoop
	// line 2
	ram[16'd16] = 32'hE5985020;  // 02000040  ldr r5,[r8,#0x20] line B
	ram[16'd17] = 32'hE588504C;  // 02000044  str r5,[r8,#0x4c] marker 3
	ram[16'd18] = 32'hE5987020;  // 02000048  ldr r7,[r8,#0x20] must hit
	ram[16'd19] = 32'hE5887050;  // 0200004c  str r7,[r8,#0x50] sample 2
	ram[16'd20] = 32'hEAFFFFFE;  // 02000050  b .
	// line 3: the subroutine
	ram[16'd24] = 32'hE3A07001;  // 02000060  mov r7,#1
	ram[16'd25] = 32'hE12FFF1E;  // 02000064  bx lr

	// the words the program loads
	ram[16'h0100] = 32'h1111_1111;   // 02000400, the word the snoop rewrites
	ram[16'h0101] = 32'h2222_2222;   // 02000404
	ram[16'h0108] = 32'h3333_3333;   // 02000420, the line beside it
	ram[16'h0C00] = 32'h4444_4444;   // 02003000, the address nothing holds

	repeat (4) @(posedge clk);
	reset = 0;

	i = 0;
	while (pc_out !== END_PC && i < 20000) begin
		@(posedge clk);
		i = i + 1;
	end
	check("the program reached its end", pc_out === END_PC);
	repeat (8) @(posedge clk);

	//--------------------------------------------------------------
	// the data line
	//--------------------------------------------------------------
	check_val(ram[16'h0111], 32'hAAAA_5555,
	          "the load after the snoop returned the new word");
	check_val(a_reads, 32'd16,
	          "and paid for the line again: 16 reads, not 8");
	check_val(ram[16'h0114], 32'h3333_3333,
	          "the line beside it still serves its own word");
	check_val(b_reads, 32'd8,
	          "and was read once: a snoop elsewhere dropped nothing");

	//--------------------------------------------------------------
	// the code line
	//--------------------------------------------------------------
	check_val(sub_reads, 32'd16,
	          "the subroutine's line was fetched again after its snoop");
	check_val(ram[16'h0112], 32'hAAAA_5555,
	          "the data line kept the new word after both snoops");

	$display("  %0d checks", checks);
	if (fails == 0) $display("TB ARM9 COHERENCE PASS");
	else            $display("TB ARM9 COHERENCE FAIL: %0d error(s)", fails);
	$finish;
end

endmodule
