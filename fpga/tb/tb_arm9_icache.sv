//============================================================================
// tb_arm9_icache — the instruction cache serving fetches
//
// The data cache's bench watches loads; this one watches code. A program
// enables c1 bit 12 from inside the first 32-byte line of main RAM and then
// runs a loop that fits entirely in that line, so what the bus sees is
// exact: three fetches before the enable takes effect (the cache is off),
// then one miss -- its own read and the other seven words of the line --
// and after that nothing at all, however many times the loop goes round.
//
//   * the line is fetched once: eight bus reads of its 32 bytes, and the
//     loop that follows costs none
//   * the loop itself ran: r0 comes back out at 0 (it was loaded with 8 and
//     decremented once per pass), stored to a watched address
//   * invalidate-all really empties it: the instruction after the command
//     is in the line that was just filled, and it is fetched from the bus
//     again -- sixteen reads of that line instead of eight
//   * a second line fills into its own set and its five instructions are
//     served without a read
//   * Thumb fetches come out of the same line: the ARM code switches with
//     bx, and the halfword the address picks is the right one -- a wrong
//     lane would not run the loop or return 0 from it
//
// The two lanes matter more than they look: the array holds a word, the
// fetch needs half of it, and this is the only bench that takes an
// instruction out of the array with the T bit set.
//============================================================================
`timescale 1ns / 1ps

module tb_arm9_icache;

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
// the counters: completed reads of each of the three code lines
//------------------------------------------------------------------
localparam [31:0] END_PC = 32'h0200_0062;

integer l0_reads = 0;
integer l1_reads = 0;
integer l2_reads = 0;
integer l3_reads = 0;
reg [31:0] at [0:1];
integer i;

always @(posedge clk) begin
	if (bus_rd && bus_ready) begin
		case (bus_addr[11:5])
		5'd0:    l0_reads <= l0_reads + 1;   // 0200_0000..1F
		5'd1:    l1_reads <= l1_reads + 1;   // 0200_0020..3F
		5'd2:    l2_reads <= l2_reads + 1;   // 0200_0040..5F
		5'd3:    l3_reads <= l3_reads + 1;   // 0200_0060..7F
		endcase
	end
	if (bus_wr && bus_ready && is_ram) begin
		case (bus_addr)
		32'h0200_0460: at[0] <= l0_reads;
		32'h0200_0464: at[1] <= l0_reads;
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
	$dumpfile("tb_arm9_icache.vcd");
	$dumpvars(0, tb_arm9_icache);

	// line 0, 0200_0000..1F: enable c1 bit 12, then loop inside the line
	ram[16'd0]  = 32'hEE119F10;  // 02000000  mrc p15,0,r9,c1,c0,0
	ram[16'd1]  = 32'hE3899A01;  // 02000004  orr r9,r9,#0x1000  (i cache)
	ram[16'd2]  = 32'hEE019F10;  // 02000008  mcr p15,0,r9,c1,c0,0
	ram[16'd3]  = 32'hE3A00008;  // 0200000c  mov r0,#8         miss + fill
	ram[16'd4]  = 32'hE2400001;  // 02000010  sub r0,r0,#1       hits
	ram[16'd5]  = 32'hE3500000;  // 02000014  cmp r0,#0
	ram[16'd6]  = 32'h1AFFFFFC;  // 02000018  bne 02000010
	ram[16'd7]  = 32'hEAFFFFFF;  // 0200001c  b 02000020
	// line 1, 0200_0020..3F: drop the whole cache, then leave the line --
	// the fetch after the command has to pay for the fill again
	ram[16'd8]  = 32'hEE070F15;  // 02000020  mcr p15,0,r0,c7,c5,0
	ram[16'd9]  = 32'hEA000005;  // 02000024  b 02000040
	// line 2, 0200_0040..5F: ARM out of the array, then Thumb out of it
	ram[16'd16] = 32'hE3A02402;  // 02000040  mov r2,#0x02000000
	ram[16'd17] = 32'hE3822B01;  // 02000044  orr r2,r2,#0x400
	ram[16'd18] = 32'hE5820060;  // 02000048  str r0,[r2,#0x60]  sample 0
	ram[16'd19] = 32'hE28F1005;  // 0200004c  add r1,pc,#5      -> 02000059
	ram[16'd20] = 32'hE12FFF11;  // 02000050  bx r1             to Thumb
	ram[16'd21] = 32'hEAFFFFFE;  // 02000054  b .               (never run)
	ram[16'd22] = 32'h38012008;  // 02000058  mov r0,#8 / sub r0,#1
	ram[16'd23] = 32'hD1FC2800;  // 0200005c  cmp r0,#0 / bne 0200005a
	// line 3, 0200_0060..7F
	ram[16'd24] = 32'hE7FE6650;  // 02000060  str r0,[r2,#0x64] / b .
	ram[16'd25] = 32'h0000EAFF;

	for (i = 0; i < 2; i = i + 1) at[i] = 32'hDEAD_DEAD;

	repeat (4) @(posedge clk);
	reset = 0;

	// The last store is what ends the program: the fetch that reaches the
	// final address has not executed the instruction at it yet -- a miss is
	// still filling -- so the bench waits for the write, not the pc.
	i = 0;
	while (at[1] === 32'hDEAD_DEAD && i < 20000) begin
		@(posedge clk);
		i = i + 1;
	end
	check("the program ran to its last store", at[1] !== 32'hDEAD_DEAD);
	repeat (8) @(posedge clk);

	//--------------------------------------------------------------
	// what the fetches cost on the bus
	//--------------------------------------------------------------
	check_val(at[0], 32'd11,
	          "the first line: three uncached fetches, then eight reads");
	check_val(l1_reads, 32'd16,
	          "invalidate-all made the next fetch pay for the line again");
	check_val(l2_reads, 32'd8,
	          "the second line was fetched once and served its code");
	check_val(l3_reads, 32'd8,
	          "the third line, and the store in it, cost one fill");

	//--------------------------------------------------------------
	// and what ran
	//--------------------------------------------------------------
	check_val(ram[16'h0118], 32'h0, "the ARM loop ran to zero");
	check_val(ram[16'h0119], 32'h0, "the Thumb loop ran to zero");

	$display("  %0d checks", checks);
	if (fails == 0) $display("TB ARM9 ICACHE PASS");
	else            $display("TB ARM9 ICACHE FAIL: %0d error(s)", fails);
	$finish;
end

endmodule
