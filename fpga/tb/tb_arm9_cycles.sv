//============================================================================
// tb_arm9_cycles — what the caches are worth, in cycles
//
// The other cache benches count bus accesses, which says what the cache does
// and not what it buys. This one runs the same loop twice at each of the two
// cache bits and counts clocks, so the answer is a number per iteration.
//
//   0x02000000  fetch loop, c1 bit 12 clear: 64 iterations of
//               `subs; bne` fetched from the bus every time
//   0x02000020  the same loop with the instruction cache on: one line fill,
//               then the loop runs out of the array
//   0x02000040  load loop, c1 bit 2 clear: 64 iterations of `ldr; subs; bne`
//               with a bus read per load (the fetch path is already cached)
//   0x02000060  the same with the data cache on: one fill, then every load
//               is served from the line
//
// A store to a marker address ends each phase, and the bench records its own
// cycle counter there; the marker store is in the interval it ends, which is
// the same few cycles in every phase, so the difference between an on phase
// and its off phase is the caches' and nothing else.
//
// The checks are both the relationship and the figure: an on phase has to be
// cheaper than its off phase, and the per-iteration cost has to be the one
// the run measured. A cache that stopped serving, or a bus that got faster,
// fails the second kind.
//============================================================================
`timescale 1ns / 1ps

module tb_arm9_cycles;

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
// the fabric: 256 KB of main RAM, eight cycles a beat
//
// Deliberately slow. Against a two-cycle bus a cache hit costs exactly what
// the miss it replaces costs -- the probe and the array's registered read
// are two cycles themselves -- so a bench with a fast bus measures the cache
// as worth nothing and is right to. Eight cycles is the shape of the real
// path: rtl/bus/main_bus.sv answers a 32-bit main-RAM read as two halfword
// beats around the SDRAM arbiter, which is ten-plus cycles, not two.
//------------------------------------------------------------------
reg [31:0] ram [0:65535];

wire        is_ram = (bus_addr[31:24] == 8'h02);
wire [15:0] ram_idx = bus_addr[17:2];

always @(*)
	bus_rdata = is_ram ? ram[ram_idx] : 32'h0000_0000;

reg  [3:0] wait_cnt = 0;
reg        ready_r  = 0;
assign bus_ready = ready_r;

always @(posedge clk) begin
	ready_r <= 1'b0;
	if (bus_rd || bus_wr) begin
		if (wait_cnt == 4'd7) begin
			ready_r  <= 1'b1;
			wait_cnt <= 4'd0;
			if (bus_wr && is_ram) begin
				if (bus_be[0]) ram[ram_idx][7:0]   <= bus_wdata[7:0];
				if (bus_be[1]) ram[ram_idx][15:8]  <= bus_wdata[15:8];
				if (bus_be[2]) ram[ram_idx][23:16] <= bus_wdata[23:16];
				if (bus_be[3]) ram[ram_idx][31:24] <= bus_wdata[31:24];
			end
		end else wait_cnt <= wait_cnt + 4'd1;
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
// the clock counter and the eight markers
//------------------------------------------------------------------
localparam [31:0] END_PC = 32'h0200_0080;

integer cyc = 0;
integer at [0:7];
integer i;

always @(posedge clk) begin
	cyc <= cyc + 1;
	if (bus_wr && bus_ready && is_ram) begin
		case (bus_addr)
		32'h0200_0440: at[0] <= cyc;
		32'h0200_0444: at[1] <= cyc;
		32'h0200_0448: at[2] <= cyc;
		32'h0200_044C: at[3] <= cyc;
		32'h0200_0450: at[4] <= cyc;
		32'h0200_0454: at[5] <= cyc;
		32'h0200_0458: at[6] <= cyc;
		32'h0200_045C: at[7] <= cyc;
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
			$display("FAIL %0s: got %0d, wanted %0d", what, got, want);
		end else
			$display("ok   %0s", what);
	end
endtask

integer f_off, f_on, l_off, l_on;

initial begin
	$dumpfile("tb_arm9_cycles.vcd");
	$dumpvars(0, tb_arm9_cycles);

	// line 0: the fetch loop with nothing cached
	ram[16'd0]  = 32'hEE119F10;  // 02000000  mrc p15,0,r9,c1,c0,0
	ram[16'd1]  = 32'hE3A08402;  // 02000004  mov r8,#0x02000000
	ram[16'd2]  = 32'hE3888B01;  // 02000008  orr r8,r8,#0x400
	ram[16'd3]  = 32'hE3A00040;  // 0200000c  mov r0,#64
	ram[16'd4]  = 32'hE3A02000;  // 02000010  mov r2,#0
	ram[16'd5]  = 32'hE5882040;  // 02000014  str r2,[r8,#0x40] marker 0
	ram[16'd6]  = 32'hE2500001;  // 02000018  subs r0,r0,#1
	ram[16'd7]  = 32'h1AFFFFFD;  // 0200001c  bne 02000018
	// line 1: the same loop with the instruction cache on
	ram[16'd8]  = 32'hE5882044;  // 02000020  str r2,[r8,#0x44] marker 1
	ram[16'd9]  = 32'hEE119F10;  // 02000024  mrc p15,0,r9,c1,c0,0
	ram[16'd10] = 32'hE3899A01;  // 02000028  orr r9,r9,#0x1000 (i cache)
	ram[16'd11] = 32'hEE019F10;  // 0200002c  mcr p15,0,r9,c1,c0,0
	ram[16'd12] = 32'hE3A00040;  // 02000030  mov r0,#64
	ram[16'd13] = 32'hE5882048;  // 02000034  str r2,[r8,#0x48] marker 2
	ram[16'd14] = 32'hE2500001;  // 02000038  subs r0,r0,#1
	ram[16'd15] = 32'h1AFFFFFD;  // 0200003c  bne 02000038
	// line 2: the load loop with the data cache off
	ram[16'd16] = 32'hE588204C;  // 02000040  str r2,[r8,#0x4c] marker 3
	ram[16'd17] = 32'hE3A00040;  // 02000044  mov r0,#64
	ram[16'd18] = 32'hE5882050;  // 02000048  str r2,[r8,#0x50] marker 4
	ram[16'd19] = 32'hE5981100;  // 0200004c  ldr r1,[r8,#0x100]
	ram[16'd20] = 32'hE2500001;  // 02000050  subs r0,r0,#1
	ram[16'd21] = 32'h1AFFFFFC;  // 02000054  bne 0200004c
	// line 3: the same loop with the data cache on
	ram[16'd22] = 32'hE5882054;  // 02000058  str r2,[r8,#0x54] marker 5
	ram[16'd23] = 32'hEE119F10;  // 0200005c  mrc p15,0,r9,c1,c0,0
	ram[16'd24] = 32'hE3899004;  // 02000060  orr r9,r9,#4 (data cache)
	ram[16'd25] = 32'hEE019F10;  // 02000064  mcr p15,0,r9,c1,c0,0
	ram[16'd26] = 32'hE3A00040;  // 02000068  mov r0,#64
	ram[16'd27] = 32'hE5882058;  // 0200006c  str r2,[r8,#0x58] marker 6
	ram[16'd28] = 32'hE5981100;  // 02000070  ldr r1,[r8,#0x100]
	ram[16'd29] = 32'hE2500001;  // 02000074  subs r0,r0,#1
	ram[16'd30] = 32'h1AFFFFFC;  // 02000078  bne 02000070
	ram[16'd31] = 32'hE588205C;  // 0200007c  str r2,[r8,#0x5c] marker 7
	ram[16'd32] = 32'hEAFFFFFE;  // 02000080  b .

	ram[16'h0140] = 32'h5A5A_5A5A;   // 02000500, the word the load loop reads

	for (i = 0; i < 8; i = i + 1) at[i] = -1;

	repeat (4) @(posedge clk);
	reset = 0;

	// The last marker ends the program, not the last address: the fetch that
	// reaches it has not executed the store at it yet.
	i = 0;
	while (at[7] < 0 && i < 40000) begin
		@(posedge clk);
		i = i + 1;
	end
	check("the program ran to its last marker", at[7] >= 0);
	repeat (8) @(posedge clk);

	//----------------------------------------------------------------
	// per-phase cycles, and the per-iteration cost they imply
	//----------------------------------------------------------------
	f_off = at[1] - at[0];
	f_on  = at[3] - at[2];
	l_off = at[5] - at[4];
	l_on  = at[7] - at[6];

	$display("  fetch loop, cache off : %0d cycles for 64 iterations", f_off);
	$display("  fetch loop, cache on  : %0d cycles for 64 iterations", f_on);
	$display("  load loop,  cache off : %0d cycles for 64 iterations", l_off);
	$display("  load loop,  cache on  : %0d cycles for 64 iterations", l_on);

	check("every phase was measured", at[7] > 0 && at[0] >= 0);
	check("the instruction cache makes the loop cheaper", f_on < f_off);
	check("the data cache makes the load loop cheaper", l_on < l_off);
	check_val(f_off, 32'd1299, "fetch loop cycles with the cache off");
	check_val(f_on,  32'd466,  "fetch loop cycles with the cache on");
	check_val(l_off, 32'd1164, "load loop cycles with the cache off");
	check_val(l_on,  32'd786,  "load loop cycles with the cache on");
	$display("  fetch loop: %0d.%02d cycles per iteration, %0d.%02d cached",
	         f_off / 64, (f_off * 100 / 64) % 100,
	         f_on / 64, (f_on * 100 / 64) % 100);
	$display("  load loop : %0d.%02d cycles per iteration, %0d.%02d cached",
	         l_off / 64, (l_off * 100 / 64) % 100,
	         l_on / 64, (l_on * 100 / 64) % 100);

	$display("  %0d checks", checks);
	if (fails == 0) $display("TB ARM9 CYCLES PASS");
	else            $display("TB ARM9 CYCLES FAIL: %0d error(s)", fails);
	$finish;
end

endmodule
