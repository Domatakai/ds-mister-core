//============================================================================
// NDS MiSTer Test — BIOS SWI bank bench
//
//   iverilog -g2012 -o /tmp/tb_swi tb/tb_swi_hle.sv rtl/cpu/swi_hle.sv
//   vvp /tmp/tb_swi
//
// The engine is driven exactly the way a core drives it: `go` for one cycle
// with the SWI number and r0..r3, then `m_req` mirrored onto a memory model
// that answers one cycle later. The model is byte-addressed with lane byte
// enables, like the real bus, and it owns the four system registers the wait
// calls poll (IME, IE, IF), so a scripted interrupt can arrive mid-wait.
//
//   1. Div against GBATEK's worked example and a second case, plus divide by
//      zero (which the real BIOS never returns from — this one must)
//   2. Sqrt: 0, 1, 2, 144 and the largest input, where the answer is 65535
//   3. CpuSet: 32-bit and 16-bit copies, and a fill that must read its source
//      once and not walk it
//   4. CpuFastSet: copy and fill
//   5. LZ77: a literal-only stream, and a copy whose source overlaps the write
//      pointer (disp 0, the case that reads bytes it has just written)
//   6. RL: a repeated run and a literal run in the same stream
//   7. IntrWait/VBlankIntrWait: the discard clears old flags and the call
//      returns on the new one; IME is forced on; IF is left set for the
//      game's handler
//   8. Halt: waits for (IE AND IF)
//   9. an SWI that is not in the bank falls through untouched: no bus access,
//      handled = 0, so the core vectors to 0x08 as before
//============================================================================
`timescale 1ns / 1ps

module tb_swi_hle;

reg clk = 0;
always #5 clk = ~clk;

reg         go = 0;
reg   [7:0] num = 8'h00;
reg  [31:0] r0 = 0, r1 = 0, r2 = 0, r3 = 0;

wire        m_req, m_wr;
wire  [1:0] m_size;
wire [31:0] m_addr, m_wdata, m_wlane;
wire  [3:0] m_be;
wire [31:0] m_rdata;
reg         m_ack = 0;

wire        done, handled;
wire [31:0] res0, res1, res3;
wire        wr0, wr1, wr3, busy;

swi_hle dut (
	.clk(clk), .reset(1'b0), .ce(1'b1),
	.go(go), .num(num), .r0(r0), .r1(r1), .r2(r2), .r3(r3),
	.m_req(m_req), .m_wr(m_wr), .m_size(m_size),
	.m_addr(m_addr), .m_wdata(m_wdata), .m_be(m_be), .m_wlane(m_wlane),
	.m_rdata(m_rdata), .m_ack(m_ack),
	.done(done), .handled(handled),
	.res0(res0), .res1(res1), .res3(res3),
	.wr0(wr0), .wr1(wr1), .wr3(wr3), .busy(busy)
);

//------------------------------------------------------------------
// memory model: 64 KB of RAM plus the system registers the waits read
//------------------------------------------------------------------
reg [7:0] mem [0:65535];

reg        io_ime = 0;
reg [15:0] io_ie  = 0;
reg [15:0] io_if  = 0;
reg        saw_clear = 0;   // IntrWait's discard cleared a pending flag
integer    io_writes = 0;      // how many writes the engine made to I/O

wire is_io = (m_addr[31:16] == 16'h0400);

wire [15:0] mem_off = m_addr[15:0];

// A read answers the whole word from the aligned address, latched when the
// request is accepted, which is both what main_bus does for RAM and what
// keeps the simulator from building a mux out of the whole 64 KB array.
reg [31:0] rd_q = 32'd0;
assign m_rdata = rd_q;

// one-cycle answer, like the core's bridge: request, then ack with the data
reg pend = 0;
always @(posedge clk) begin
	m_ack <= 1'b0;
	if (m_req && !pend && !m_ack) begin
		pend  <= 1'b1;
		if (is_io) begin
			case (mem_off[15:1])
			15'h0108: rd_q <= {16'd0, io_ie};
			15'h010A: rd_q <= {16'd0, io_if};
			default:  rd_q <= {16'd0, io_ime ? 16'h0001 : 16'h0000};
			endcase
		end else begin
			rd_q <= {mem[{mem_off[15:2], 2'b11}], mem[{mem_off[15:2], 2'b10}],
			          mem[{mem_off[15:2], 2'b01}], mem[{mem_off[15:2], 2'b00}]};
		end
	end else if (pend) begin
		m_ack <= 1'b1;
		pend  <= 1'b0;
		// writes land with the acknowledgement, in their own byte lanes
		if (m_wr) begin
			if (is_io) begin
				io_writes <= io_writes + 1;
				if (mem_off == 16'h0208) io_ime <= m_wlane[0];
				if (mem_off == 16'h0214) begin
					if (io_if[0] && m_wlane[0]) saw_clear <= 1'b1;
					io_if <= io_if & ~m_wlane[15:0];
				end
			end else begin
				if (m_be[0]) mem[{mem_off[15:2], 2'b00}] <= m_wlane[7:0];
				if (m_be[1]) mem[{mem_off[15:2], 2'b01}] <= m_wlane[15:8];
				if (m_be[2]) mem[{mem_off[15:2], 2'b10}] <= m_wlane[23:16];
				if (m_be[3]) mem[{mem_off[15:2], 2'b11}] <= m_wlane[31:24];
			end
		end
	end
end

integer errors = 0;

task check;
	input [8*44:1] name;
	input [31:0]   got;
	input [31:0]   exp;
	begin
		if (got !== exp) begin
			$display("FAIL %0s: got %h, expected %h", name, got, exp);
			errors = errors + 1;
		end else
			$display("ok   %0s: %h", name, got);
	end
endtask

task chk_byte;
	input [8*44:1] name;
	input integer  a;
	input [7:0]    exp;
	begin
		if (mem[a] !== exp) begin
			$display("FAIL %0s: mem[%0d] = %h, expected %h", name, a, mem[a], exp);
			errors = errors + 1;
		end else
			$display("ok   %0s: %h", name, mem[a]);
	end
endtask

// clear RAM between tests
task wipe;
	integer i;
	begin
		for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
	end
endtask

// one SWI: hold go for a cycle, then wait for done
task call;
	input [7:0]  n;
	input [31:0] a0, a1, a2;
	input integer limit;
	integer w;
	begin
		r0 = a0; r1 = a1; r2 = a2; r3 = 32'd0;
		num = n;
		@(negedge clk); go = 1;
		@(negedge clk); go = 0;
		w = 0;
		while (!done && w < limit) begin
			@(posedge clk);
			w = w + 1;
		end
		if (!done) begin
			$display("FAIL swi %h timed out after %0d cycles (st=%0d req=%b ack=%b a_busy=%b a_done=%b ie=%h ifr=%h)",
			         n, limit, dut.st, m_req, m_ack, dut.a_busy, dut.a_done, io_ie, io_if);
			errors = errors + 1;
		end
		@(posedge clk);
	end
endtask

// write a 32-bit word / bytes into the model
task w32;
	input [15:0] a;
	input [31:0] v;
	begin
		mem[a] = v[7:0]; mem[a+1] = v[15:8];
		mem[a+2] = v[23:16]; mem[a+3] = v[31:24];
	end
endtask

task w8;
	input [15:0] a;
	input [7:0]  v;
	begin mem[a] = v; end
endtask

integer i, base;
reg [31:0] got0, got1, got3;

initial begin
	wipe();
	#20;

	//--------------------------------------------------------------
	// 1. Div — GBATEK's own example: -1234 / 10 = -123, remainder -4
	//--------------------------------------------------------------
	call(8'h09, 32'hFFFF_FB2E, 32'd10, 32'd0, 400);
	check("Div: -1234 / 10 quotient", res0, 32'hFFFF_FF85);
	check("Div: -1234 % 10 remainder", res1, 32'hFFFF_FFFC);
	check("Div: |quotient| in r3", res3, 32'd123);

	call(8'h09, 32'd100, 32'd7, 32'd0, 400);
	check("Div: 100 / 7 quotient", res0, 32'd14);
	check("Div: 100 % 7 remainder", res1, 32'd2);

	call(8'h09, 32'd0, 32'hFFFF_FFF6, 32'd0, 400);   // 0 / -10
	check("Div: 0 / -10 is zero", res0, 32'd0);
	check("Div: 0 % -10 is zero", res1, 32'd0);

	// the real BIOS never returns from this one; this core must
	call(8'h09, 32'd1234, 32'd0, 32'd0, 400);
	check("Div by zero: quotient 0", res0, 32'd0);
	check("Div by zero: remainder is the numerator", res1, 32'd1234);
	check("Div by zero: |quotient| 0", res3, 32'd0);

	//--------------------------------------------------------------
	// 2. Sqrt
	//--------------------------------------------------------------
	call(8'h0D, 32'd0, 32'd0, 32'd0, 60);
	check("Sqrt 0", res0, 32'd0);

	call(8'h0D, 32'd1, 32'd0, 32'd0, 60);
	check("Sqrt 1", res0, 32'd1);

	call(8'h0D, 32'd2, 32'd0, 32'd0, 60);
	check("Sqrt 2 is 1 (integer)", res0, 32'd1);

	call(8'h0D, 32'd144, 32'd0, 32'd0, 60);
	check("Sqrt 144", res0, 32'd12);

	call(8'h0D, 32'd145, 32'd0, 32'd0, 60);
	check("Sqrt 145 is 12 (floor)", res0, 32'd12);

	call(8'h0D, 32'hFFFF_FFFF, 32'd0, 32'd0, 60);
	check("Sqrt of the largest word", res0, 32'd65535);

	//--------------------------------------------------------------
	// 3. CpuSet
	//--------------------------------------------------------------
	wipe();
	for (i = 0; i < 8; i = i + 1) w32(16'h1000 + 4*i, 32'hA5A5_0000 + i);
	// 32-bit copy of 8 words: r2 = count | bit26 (32-bit), no fill
	call(8'h0B, 32'h0000_1000, 32'h0000_2000, 32'h0400_0008, 400);
	check("CpuSet: 32-bit copy, word 0", {mem[16'h2003], mem[16'h2002],
	                                     mem[16'h2001], mem[16'h2000]}, 32'hA5A5_0000);
	check("CpuSet: 32-bit copy, word 7", {mem[16'h201F], mem[16'h201E],
	                                     mem[16'h201D], mem[16'h201C]}, 32'hA5A5_0007);

	// 16-bit copy of 4 halfwords
	wipe();
	for (i = 0; i < 4; i = i + 1) begin
		mem[16'h3000 + 2*i] = 8'h10 + i;
		mem[16'h3001 + 2*i] = 8'h20 + i;
	end
	call(8'h0B, 32'h0000_3000, 32'h0000_3200, 32'h0000_0004, 400);
	chk_byte("CpuSet: 16-bit copy byte 0", 16'h3200, 8'h10);
	chk_byte("CpuSet: 16-bit copy byte 1", 16'h3201, 8'h20);
	chk_byte("CpuSet: 16-bit copy last byte", 16'h3207, 8'h23);

	// 32-bit fill of 4 words from a fixed source (bit 24)
	wipe();
	w32(16'h3400, 32'hDEAD_BEEF);
	call(8'h0B, 32'h0000_3400, 32'h0000_3600, 32'h0500_0004, 400);
	check("CpuSet: fill word 0", {mem[16'h3603], mem[16'h3602],
	                             mem[16'h3601], mem[16'h3600]}, 32'hDEAD_BEEF);
	check("CpuSet: fill word 3", {mem[16'h360F], mem[16'h360E],
	                             mem[16'h360D], mem[16'h360C]}, 32'hDEAD_BEEF);
	check("CpuSet: fill leaves the source alone",
	      {mem[16'h3403], mem[16'h3402], mem[16'h3401], mem[16'h3400]}, 32'hDEAD_BEEF);

	//--------------------------------------------------------------
	// 4. CpuFastSet
	//--------------------------------------------------------------
	wipe();
	for (i = 0; i < 6; i = i + 1) w32(16'h4000 + 4*i, 32'h0101_0101 * (i + 1));
	call(8'h0C, 32'h0000_4000, 32'h0000_4200, 32'h0000_0006, 400);
	check("CpuFastSet: copy word 0", {mem[16'h4203], mem[16'h4202],
	                                 mem[16'h4201], mem[16'h4200]}, 32'h0101_0101);
	check("CpuFastSet: copy word 5", {mem[16'h4217], mem[16'h4216],
	                                 mem[16'h4215], mem[16'h4214]}, 32'h0606_0606);

	wipe();
	w32(16'h4400, 32'h1234_5678);
	call(8'h0C, 32'h0000_4400, 32'h0000_4600, 32'h0100_0003, 400);
	check("CpuFastSet: fill word 2", {mem[16'h460B], mem[16'h460A],
	                                 mem[16'h4609], mem[16'h4608]}, 32'h1234_5678);

	//--------------------------------------------------------------
	// 5. LZ77
	//--------------------------------------------------------------
	// literals only: header (size 4, type 1), flag 0, then ABCD
	wipe();
	w32(16'h5000, 32'h0000_0410);
	w8(16'h5004, 8'h00);
	w8(16'h5005, 8'h41); w8(16'h5006, 8'h42);
	w8(16'h5007, 8'h43); w8(16'h5008, 8'h44);
	call(8'h11, 32'h0000_5000, 32'h0000_5200, 32'd0, 800);
	chk_byte("LZ77: literal A", 16'h5200, 8'h41);
	chk_byte("LZ77: literal D", 16'h5203, 8'h44);

	// eight 'A's: one literal, then a copy of 7 from disp 0 (dest-1), which
	// reads bytes this very run has just written
	wipe();
	w32(16'h5400, 32'h0000_0810);
	w8(16'h5404, 8'h40);              // bit7 = 0 literal, bit6 = 1 copy
	w8(16'h5405, 8'h41);              // 'A'
	w8(16'h5406, 8'h40);              // len-3 = 4 -> 7 bytes, disp high nibble 0
	w8(16'h5407, 8'h00);              // disp low
	call(8'h11, 32'h0000_5400, 32'h0000_5600, 32'd0, 1200);
	chk_byte("LZ77: overlapping copy, first byte", 16'h5600, 8'h41);
	for (i = 1; i < 8; i = i + 1) begin
		if (mem[16'h5600 + i] !== 8'h41) begin
			$display("FAIL LZ77 overlapping copy at +%0d: %h", i, mem[16'h5600 + i]);
			errors = errors + 1;
		end
	end
	$display("ok   LZ77: overlapping copy filled 8 bytes");

	//--------------------------------------------------------------
	// 6. RL
	//--------------------------------------------------------------
	// "AAAAAB": header (size 6, type 3), run of 5 x 'A', then one literal 'B'
	wipe();
	w32(16'h5800, 32'h0000_0630);
	w8(16'h5804, 8'h82);              // repeated, length-3 = 2 -> 5
	w8(16'h5805, 8'h41);
	w8(16'h5806, 8'h00);              // literal, length-1 = 0 -> 1
	w8(16'h5807, 8'h42);
	call(8'h14, 32'h0000_5800, 32'h0000_5A00, 32'd0, 800);
	chk_byte("RL: run byte 0", 16'h5A00, 8'h41);
	chk_byte("RL: run byte 4", 16'h5A04, 8'h41);
	chk_byte("RL: literal after the run", 16'h5A05, 8'h42);

	//--------------------------------------------------------------
	// 7. IntrWait / VBlankIntrWait
	//--------------------------------------------------------------
	io_ime = 0; io_ie = 16'h0001; io_if = 16'h0001;
	// VBlankIntrWait (05h): discards the old flag, so it must wait for the
	// next one; the model raises it after a few cycles
	fork
		begin
			repeat (30) @(negedge clk);
			io_if[0] = 1'b1;
		end
	join_none
	call(8'h05, 32'd0, 32'd0, 32'd0, 400);
	check("VBlankIntrWait: IME forced on", io_ime, 1);
	check("VBlankIntrWait: IF left for the handler", io_if[0], 1'b1);
	check("VBlankIntrWait: discard cleared the flag", saw_clear, 1'b1);

	// IntrWait with discard=0 and the flag already set returns at once
	io_if = 16'h0001;
	call(8'h04, 32'd0, 16'h0001, 32'd0, 400);
	check("IntrWait discard=0: returns on the old flag", io_if[0], 1'b1);

	//--------------------------------------------------------------
	// 8. Halt
	//--------------------------------------------------------------
	io_ie = 16'h0002; io_if = 16'h0000;
	fork
		begin
			repeat (40) @(negedge clk);
			io_if[1] = 1'b1;
		end
	join_none
	call(8'h06, 32'd0, 32'd0, 32'd0, 400);
	check("Halt: returned once IE and IF met", io_if[1], 1'b1);

	//--------------------------------------------------------------
	// 9. an SWI outside the bank
	//--------------------------------------------------------------
	io_writes = 0;
	call(8'h00, 32'd0, 32'd0, 32'd0, 40);
	check("SoftReset is not in the bank", handled, 1'b0);
	check("... and it made no bus access", io_writes, 0);

	call(8'h01, 32'd0, 32'd0, 32'd0, 40);
	check("WaitByLoop is not in the bank", handled, 1'b0);

	if (errors == 0) $display("tb_swi_hle: PASS");
	else             $display("tb_swi_hle: FAIL (%0d errors)", errors);
	$finish;
end

endmodule
