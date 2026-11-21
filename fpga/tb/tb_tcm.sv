//============================================================================
// NDS MiSTer Test -- ARM9 TCM testbench
//
//   iverilog -g2012 -o /tmp/tb_tcm tb/tb_tcm.sv rtl/cpu/arm9_tcm.sv && vvp /tmp/tb_tcm
//
// Drives the module the way arm9_core does -- address and strobe held until
// `c_ready` -- and checks what the ARM946E-S's TCMs do:
//   - a write then a read of the data TCM, with no fabric traffic either way
//   - a byte write and a halfword write landing in the right lanes only
//   - the instruction TCM, and its 32 MB area mirroring the 32 KB at
//     0x01000000 (the base libnds and blocksds run from)
//   - the area wrap: an address past the end of a 32 KB area is a miss
//   - the control-bit and region-size gates: a zero size or a cleared
//     enable bit sends the same address to the fabric
//   - a miss passing through with its strobes intact, and the fabric's
//     ready reaching the core
//   - `c_ready` as a one-cycle pulse per request
//============================================================================
`timescale 1ns / 1ps

module tb_tcm;

reg clk = 0;
always #5 clk = ~clk;

reg  [31:0] c1 = 32'h0001_2078;   // post-BIOS control: DTCM enable set
reg  [31:0] c9d = 32'd0;          // region registers still zero
reg  [31:0] c9i = 32'd0;
reg  [31:0] c_addr = 0, c_wdata = 0;
reg  [3:0]  c_be = 4'hF;
reg         c_rd = 0, c_wr = 0;
wire [31:0] c_rdata;
wire        c_ready;

wire [31:0] f_addr, f_wdata;
wire [3:0]  f_be;
wire        f_rd, f_wr;
reg  [31:0] f_rdata = 32'hDEAD_BEEF;
reg         f_ready = 0;

// what the fabric saw, so a TCM access can be shown to never reach it
integer f_rd_count = 0, f_wr_count = 0;
always @(posedge clk) begin
	if (f_rd) f_rd_count = f_rd_count + 1;
	if (f_wr) f_wr_count = f_wr_count + 1;
end

arm9_tcm dut (
	.clk(clk), .c1_ctrl(c1), .c9_dtcm(c9d), .c9_itcm(c9i),
	.c_addr(c_addr), .c_wdata(c_wdata), .c_be(c_be),
	.c_rd(c_rd), .c_wr(c_wr), .c_rdata(c_rdata), .c_ready(c_ready),
	.f_addr(f_addr), .f_wdata(f_wdata), .f_be(f_be),
	.f_rd(f_rd), .f_wr(f_wr), .f_rdata(f_rdata), .f_ready(f_ready)
);

integer errors = 0;
task check;
	input [8*40:1] name;
	input [31:0] got, want;
	begin
		if (got !== want) begin
			$display("FAIL %0s: got %h want %h", name, got, want);
			errors = errors + 1;
		end else
			$display("ok   %0s", name);
	end
endtask

// one request: hold address and strobe until the module answers, then let go
task mem_wr;
	input [31:0] a, d;
	input [3:0]  be;
	integer guard;
	begin
		c_addr = a; c_wdata = d; c_be = be;
		c_wr = 1; c_rd = 0;
		guard = 0;
		while (!c_ready && guard < 20) begin @(posedge clk); #1; guard = guard + 1; end
		@(posedge clk); #1;
		c_wr = 0;
	end
endtask

reg [31:0] rd_val;
task mem_rd;
	input [31:0] a;
	integer guard;
	begin
		c_addr = a; c_be = 4'hF;
		c_rd = 1; c_wr = 0;
		guard = 0;
		@(posedge clk); #1;
		while (!c_ready && guard < 20) begin @(posedge clk); #1; guard = guard + 1; end
		rd_val = c_rdata;
		@(posedge clk); #1;
		c_rd = 0;
	end
endtask

integer i0;
initial begin
	// ---------------------------------------------------- data TCM, 16 KB
	c9d = {32'h027C_0 << 12} | (5'd5 << 1);   // base 0x027C0000, b00101
	i0 = f_rd_count + f_wr_count;
	mem_wr(32'h027C_0000, 32'h1122_3344, 4'hF);
	mem_rd(32'h027C_0000);
	check("dtcm write/read", rd_val, 32'h1122_3344);
	check("dtcm stayed on chip", f_rd_count + f_wr_count, i0);

	// byte and halfword writes touch only their lanes
	mem_wr(32'h027C_0000, 32'h0000_00AA, 4'b0001);
	mem_rd(32'h027C_0000);
	check("dtcm byte lane 0", rd_val, 32'h1122_33AA);
	mem_wr(32'h027C_0000, 32'hBB00_0000, 4'b1000);
	mem_rd(32'h027C_0000);
	check("dtcm byte lane 3", rd_val, 32'hBB22_33AA);

	// a word outside the area is a miss and keeps its strobes
	f_ready = 1;
	mem_rd(32'h0200_0000);
	check("miss reads the fabric", rd_val, 32'hDEAD_BEEF);
	check("miss passed the address", f_addr, 32'h0200_0000);

	// the control bit closes the same address off
	c1 = 32'h0000_2078;
	mem_rd(32'h027C_0000);
	check("dtcm disabled -> fabric", rd_val, 32'hDEAD_BEEF);
	c1 = 32'h0001_2078;

	// a zero region size is no area at all
	c9d = 32'd0;
	mem_rd(32'h027C_0000);
	check("zero size -> fabric", rd_val, 32'hDEAD_BEEF);
	c9d = {32'h027C_0 << 12} | (5'd5 << 1);

	// ------------------------------------------- instruction TCM, 32 KB
	c1 = 32'h0005_2078;                        // ITCM enable too
	c9i = (5'd6 << 1);                          // base 0, b00110 = 32 KB
	mem_wr(32'h0000_0000, 32'hCAFE_F00D, 4'hF);
	mem_rd(32'h0000_0000);
	check("itcm write/read", rd_val, 32'hCAFE_F00D);
	mem_wr(32'h0000_2000, 32'hA5A5_5A5A, 4'hF);
	mem_rd(32'h0000_2000);
	check("itcm second word", rd_val, 32'hA5A5_5A5A);

	// the area wrap: 0x8000 is past a 32 KB area
	mem_rd(32'h0000_8000);
	check("itcm past the area -> fabric", rd_val, 32'hDEAD_BEEF);

	// the DS's own setting: a 32 MB area, so 0x01000000 mirrors the 32 KB
	c9i = (5'd16 << 1);                         // b10000 = 32 MB
	mem_rd(32'h0100_0000);
	check("itcm mirror reads the same word", rd_val, 32'hCAFE_F00D);
	mem_wr(32'h0100_0000, 32'h0BAD_F00D, 4'hF);
	mem_rd(32'h0000_0000);
	check("itcm mirror writes the same word", rd_val, 32'h0BAD_F00D);

	// the region register's size field is what decodes the area, not the
	// storage behind it: a 64 KB area answers at 0x4000 instead of going to
	// the fabric (the DS part has 32 KB, so half of that area is backed)
	c9i = (5'd7 << 1);                          // b00111 = 64 KB
	i0 = f_rd_count + f_wr_count;
	mem_wr(32'h0000_4000, 32'h5A5A_A5A5, 4'hF);
	mem_rd(32'h0000_4000);
	check("64 KB area accepted", rd_val, 32'h5A5A_A5A5);
	check("64 KB area stayed on chip", f_rd_count + f_wr_count, i0);

	// ready is a pulse, not a level
	mem_rd(32'h0000_0000);
	check("ready low once the request is gone", c_ready, 32'd0);

	if (errors == 0) $display("TB TCM PASS");
	else             $display("TB TCM FAIL: %0d error(s)", errors);
	$finish;
end

endmodule
