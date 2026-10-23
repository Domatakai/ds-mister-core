//============================================================================
// NDS MiSTer Test — shared 2D renderer testbench
//
//   iverilog -g2012 -o /tmp/tb_rd tb/tb_renderer_2d.sv \
//            rtl/video/renderer_2d.sv && vvp /tmp/tb_rd
//
// Drives the renderer's composer port through two displayed scanlines
// with behavioural models for the palette, OAM and VRAM ports, and
// checks:
//   - blanking prefetch renders line 0 (backdrop colour 0 as base)
//   - text BG: 4bpp tiles, palette-bank cache, hflip, transparent 0
//   - OBJ: 8x8 sprite over the BG (priority tie -> sprite wins)
//   - per-line double buffering: line 1 shows row 1 data after swap
//   - OAM scan: entries with mode != 0 are skipped (affine -> M3)
//============================================================================
`timescale 1ns / 1ps

module tb_renderer_2d;

reg clk = 0;
always #10 clk = ~clk; // 50 MHz

reg reset = 1;

reg  [7:0] px = 8'hFF, py = 8'hFF;
reg        on = 0;
wire [15:0] rgb555;

reg         reg_we = 0;
reg  [6:0]  reg_addr = 0;
reg  [15:0] reg_data = 0;

// ---- palette model (2-cycle: registered address, registered data)
wire [9:0] pal_addr;
reg [15:0] pal_q = 0;
reg [15:0] pal [0:1023];
always @(posedge clk) pal_q <= pal[pal_addr];

// ---- OAM model (same timing)
wire [9:0] oam_addr;
reg [15:0] oam_q = 0;
reg [15:0] oam [0:1023];
always @(posedge clk) oam_q <= oam[oam_addr];

// ---- VRAM model: 2-cycle latency, hold-until-ready protocol
wire        v_req;
wire [19:0] v_addr;
reg         v_ready = 0;
reg  [15:0] v_rdata = 0;
reg  [15:0] vram [0:131071]; // 256K halfwords (window halfwords)

localparam M_IDLE = 2'd0, M_LAT = 2'd1, M_DROP = 2'd2;
reg [1:0]  mstate = M_IDLE;
reg [1:0]  mcnt = 0;
reg [19:0] m_addr = 0;

always @(posedge clk) begin
	v_ready <= 1'b0;
	case (mstate)
	M_IDLE: if (v_req) begin
		m_addr  <= v_addr;
		mcnt    <= 2'd2;
		mstate  <= M_LAT;
	end
	M_LAT: begin
		if (mcnt == 2'd0) begin
			v_rdata <= vram[m_addr[17:1]];
			v_ready <= 1'b1;
			mstate  <= M_DROP;
		end else mcnt <= mcnt - 2'd1;
	end
	M_DROP: if (!v_req) mstate <= M_IDLE;
	default: mstate <= M_IDLE;
	endcase
	if (reset) begin
		mstate <= M_IDLE;
		v_ready <= 1'b0;
	end
end

renderer_2d dut (
	.clk(clk),
	.reset(reset),
	.pixel_ce(1'b1),
	.px(px),
	.py(py),
	.on(on),
	.rgb555(rgb555),
	.reg_we(reg_we),
	.reg_addr(reg_addr),
	.reg_data(reg_data),
	.pal_addr(pal_addr),
	.pal_data(pal_q),
	.oam_addr(oam_addr),
	.oam_data(oam_q),
	.v_req(v_req),
	.v_addr(v_addr),
	.v_ready(v_ready),
	.v_rdata(v_rdata),
	.obj_base(20'h1_0000)
);

//------------------------------------------------------------------
// helpers
//------------------------------------------------------------------
task wr_reg;
	input [6:0]  a;
	input [15:0] d;
	begin
		@(posedge clk);
		reg_we   <= 1'b1;
		reg_addr <= a;
		reg_data <= d;
		@(posedge clk);
		reg_we   <= 1'b0;
	end
endtask

integer errors = 0;
task check;
	input [8*32:1] name;
	input [15:0] got;
	input [15:0] exp;
	begin
		if (got !== exp) begin
			$display("FAIL %0s: got %h expected %h", name, got, exp);
			errors = errors + 1;
		end else begin
			$display("ok   %0s: %h", name, got);
		end
	end
endtask

// display one line for a few clocks at (px pos) and sample
task sample;
	input [7:0] x;
	input [7:0] y;
	output [15:0] v;
	begin
		py = y;
		px = x;
		on = 1'b1;
		@(posedge clk);   // line-start detection happens here
		#1 v = rgb555;    // combinational read of the front bank
	end
endtask

reg [15:0] v;

integer k;
initial begin
	// ---- palette: backdrop + BG bank 0 + OBJ palette
	for (k = 0; k < 1024; k = k + 1) pal[k] = 16'h0000;
	pal[0]   = 16'h001F; // backdrop: blue
	pal[1]   = 16'h7C00; // BG colour 1: red
	pal[514] = 16'h03E0; // OBJ colour 2 (512 + 2): green

	// ---- OAM: sprite 0 normal, everything else affine (skipped)
	for (k = 0; k < 1024; k = k + 1) oam[k] = 16'h4000;
	oam[0] = 16'h0000;   // ATTR0: y=0, square, normal mode
	oam[1] = 16'h0064;   // ATTR1: x=100, size 0 (8x8)
	oam[2] = 16'h0000;   // ATTR2: tile 0, prio 0, pal bank 0

	// ---- VRAM
	for (k = 0; k < 131072; k = k + 1) vram[k] = 16'h0000;
	// BG0 map (screen base 0): all 32 entries -> tile 0; col 0 flips.
	// BG0 char base is 16 KB (BGxCNT[3:2]=1) so tile data at byte
	// 0x4000 does not collide with the map at byte 0.
	for (k = 0; k < 32; k = k + 1) vram[k] = 16'h0000;
	vram[0] = 16'h0400;            // map col 0: tile 0 + hflip
	// tile 0 rows (byte 0x4000 + row*4 -> halfword idx 0x2000 + row*2)
	vram[16'h2000] = 16'h0011;     // row0 hw0: pixels 1,1,0,0
	vram[16'h2001] = 16'h0000;     // row0 hw1: pixels 0,0,0,0
	vram[16'h2002] = 16'h1111;     // row1 hw0: all four = 1
	vram[16'h2003] = 16'h1111;     // row1 hw1: all four = 1
	// OBJ tile row: obj_base 0x10000 -> halfword idx 0x8000
	vram[16'h8000] = 16'h2222;     // sprite row0 hw0: all idx 2
	vram[16'h8001] = 16'h2222;     // sprite row0 hw1: all idx 2
	// sprite row1 stays 0 (transparent)

	repeat (4) @(posedge clk);
	reset = 1'b0;
	repeat (4) @(posedge clk);

	// ---- program the engine
	wr_reg(7'h00, 16'h1100); // DISPCNT: mode 0, BG0 + OBJ enable
	wr_reg(7'h08, 16'h0004); // BG0CNT: char base = 16 KB, 32x32, 4bpp
	wr_reg(7'h48, 16'h0000); // BG0HOFS
	wr_reg(7'h4A, 16'h0000); // BG0VOFS

	// ---- deep blanking: prefetch starts once blank_cnt saturates
	// (~4100 cycles after reset) and takes ~2500 to render line 0
	on = 1'b0;
	repeat (9000) @(posedge clk);

	// ---- display line 0
	sample(8'd0, 8'd0, v);
	check("L0 x0 hflip -> 0", v, 16'h001F);
	sample(8'd6, 8'd0, v);
	check("L0 x6 hflip -> colour1", v, 16'h7C00);
	sample(8'd8, 8'd0, v);
	check("L0 x8 colour1", v, 16'h7C00);
	sample(8'd10, 8'd0, v);
	check("L0 x10 transparent -> backdrop", v, 16'h001F);
	sample(8'd100, 8'd0, v);
	check("L0 x100 sprite beats BG", v, 16'h03E0);
	sample(8'd108, 8'd0, v);
	check("L0 x108 outside sprite", v, 16'h001F);
	on = 1'b0;
	px = 8'hFF;

	// ---- let line 1 fetch complete
	repeat (5000) @(posedge clk);

	// ---- display line 1 (row 1 of tile/sprite differs)
	sample(8'd5, 8'd1, v);
	check("L1 x5 row1 colour1", v, 16'h7C00);
	sample(8'd100, 8'd1, v);
	check("L1 x100 sprite row1 transparent", v, 16'h7C00);
	on = 1'b0;

	if (errors == 0) $display("tb_renderer_2d: PASS");
	else             $display("tb_renderer_2d: FAIL (%0d errors)", errors);
	$finish;
end

initial begin
	#10_000_000;
	$display("tb_renderer_2d: FAIL (timeout)");
	$finish;
end

endmodule
