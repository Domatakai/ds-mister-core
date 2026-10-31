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
//   - 3D layer: opaque frame pixels merge over the BG, sprites still win
//     a priority tie with it, and a clear coverage bit stays transparent
//   - burst fetch: a 64-wide 8bpp map row arrives as two 32-entry bursts,
//     a tile row is four halfwords, and a pixel in the upper map half comes
//     from the second burst's entry
//   - OAM scan: a sprite in entry 1 is found (entries are four halfwords
//     apart) and both hits draw, in OAM order
//   - cost: one line's clocks are counted per phase and its VRAM grants and
//     beats are counted too, so a BG line is measured against the line
//     period rather than assumed to fit, and the OBJ pass is held to the
//     budget the pipelined scan gives it
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

// ---- VRAM model: one stored halfword per two address units (what the
// arbiter's decode does), a burst of v_len beats back to back, then ready
wire        v_req;
wire [19:0] v_addr;
wire  [7:0] v_len;
reg         v_ready = 0;
reg         v_bs_valid = 0;
reg  [15:0] v_bs_data = 0;
reg  [15:0] vram [0:131071]; // 256K halfwords (window halfwords)

localparam M_IDLE = 2'd0, M_LAT = 2'd1, M_BURST = 2'd2, M_DROP = 2'd3;

// traffic counters, so a line's fetch cost can be reported as grants and
// beats rather than guessed at
integer vram_bursts = 0;
integer vram_beats  = 0;
reg [1:0]  mstate = M_IDLE;
reg [1:0]  m_lat = 0;
reg [17:0] m_idx = 0;
reg  [7:0] m_left = 0;
reg [19:0] m_req = 0;

always @(posedge clk) begin
	v_ready    <= 1'b0;
	v_bs_valid <= 1'b0;
	case (mstate)
	M_IDLE: if (v_req) begin
		vram_bursts <= vram_bursts + 1;
		m_req   <= v_addr;
		m_idx   <= {1'b0, v_addr[17:1]};
		m_left  <= (v_len == 8'd0) ? 8'd1 : v_len;
		m_lat   <= 2'd3;
		mstate  <= M_BURST;
	end
	M_BURST: begin
		if (m_lat != 2'd0) m_lat <= m_lat - 2'd1;
		else if (m_left != 8'd0) begin
			v_bs_valid <= 1'b1;
			vram_beats <= vram_beats + 1;
			v_bs_data  <= vram[m_idx];
			m_idx      <= m_idx + 1'd1;
			m_left     <= m_left - 8'd1;
		end else begin
			v_ready <= 1'b1;
			mstate  <= M_DROP;
		end
	end
	// a new request may already be up with a different address (the
	// renderer prefetches at the end of a composite); that is not a
	// duplicate of the burst just served
	M_DROP: if (!v_req || v_addr != m_req) mstate <= M_IDLE;
	default: mstate <= M_IDLE;
	endcase
	if (reset) begin
		mstate <= M_IDLE;
		v_ready <= 1'b0;
		v_bs_valid <= 1'b0;
	end
end

// ---- 3D frame model: the burst side of the memory chain. A request at
// halfword offset a streams d3_len halfwords from frame[a..] on
// d3_bs_valid, one per cycle after three clocks of latency, then pulses
// d3_ready. That is the cadence sdram_ctrl + mem_arbiter + vram_arbiter
// deliver, so the merge pass is exercised at the rate it will see.
wire        d3_req;
wire [16:0] d3_addr;
wire  [7:0] d3_len;
reg         d3_ready = 0;
reg         d3_bs_valid = 0;
reg  [15:0] d3_bs_data = 0;
reg  [15:0] frame [0:65535];
reg         d3_busy = 0;
reg  [1:0]  d3_lat = 0;
reg  [7:0]  d3_left = 0;
reg [16:0]  d3_ptr = 0;
// like vram_arbiter, a completed grant is not re-latched while the master
// still holds its request up (d3_req falls a cycle after d3_ready)
reg         d3_cool = 0;

always @(posedge clk) begin
	d3_ready    <= 1'b0;
	d3_bs_valid <= 1'b0;
	if (!d3_req) d3_cool <= 1'b0;
	if (!d3_busy) begin
		if (d3_req && !d3_cool) begin
			d3_busy <= 1'b1;
			d3_lat  <= 2'd3;
			d3_left <= d3_len;
			d3_ptr  <= d3_addr;
		end
	end else if (d3_lat != 2'd0) begin
		d3_lat <= d3_lat - 2'd1;
	end else if (d3_left != 8'd0) begin
		d3_bs_valid <= 1'b1;
		d3_bs_data  <= frame[d3_ptr[16:1]];
		d3_ptr      <= d3_ptr + 17'd2;   // two halfwords per pixel
		d3_left     <= d3_left - 8'd1;
	end else begin
		d3_ready <= 1'b1;
		d3_busy  <= 1'b0;
		d3_cool  <= 1'b1;
	end
	if (reset) begin
		d3_busy     <= 1'b0;
		d3_ready    <= 1'b0;
		d3_bs_valid <= 1'b0;
		d3_cool     <= 1'b0;
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
	.v_len(v_len),
	.v_ready(v_ready),
	.v_bs_valid(v_bs_valid),
	.v_bs_data(v_bs_data),
	.d3_req(d3_req),
	.d3_addr(d3_addr),
	.d3_len(d3_len),
	.d3_ready(d3_ready),
	.d3_bs_valid(d3_bs_valid),
	.d3_bs_data(d3_bs_data),
	.d3_present(1'b1),
	.obj_base(20'h1_0000)
);

//------------------------------------------------------------------
// Line-fetch cost: from the cycle the fetch FSM leaves S_IDLE to start a
// line (S_BD_REQ) until that line is valid in the back bank. That is one
// full 256-pixel BG layer plus the OBJ pass and the 3D merge when they are
// enabled, i.e. the whole per-line budget the fetches have to fit in.
//------------------------------------------------------------------
integer line_clk = -1;     // clocks for the last completed line fetch
integer bg_clk = -1;       // clocks from line start to the last BG column
integer obj_clk = -1;      // clocks the OBJ pass (OAM scan + sprite rows) took
integer merge_clk = -1;    // clocks the 3D merge took
integer line_bursts = 0;   // VRAM grants it took
integer line_beats = 0;    // halfwords it moved
integer cyc = 0;
integer t0 = 0, b0 = 0, k0 = 0, t_bg = 0, t_obj = 0;
reg [4:0] f_prev = 5'd0;
reg [7:0] bl_prev = 8'hFF;
reg       bg_prev = 1'b0;

integer st_cnt [0:31];
integer si;
initial for (si = 0; si < 32; si = si + 1) st_cnt[si] = 0;

always @(posedge clk) begin
	cyc = cyc + 1;
	if (dut.fstate != 5'd0) st_cnt[dut.fstate] = st_cnt[dut.fstate] + 1;
	if (dut.fstate == 5'd1 && f_prev != 5'd1) begin   // S_BD_REQ: line start
		t0 = cyc;  b0 = vram_bursts;  k0 = vram_beats;
		for (si = 0; si < 32; si = si + 1) st_cnt[si] = 0;
	end
	// the BG walk is done when the fetch side leaves the BG phase for the
	// OBJ pass (or straight for the merge)
	if (bg_prev && !dut.phase_bg) begin bg_clk = cyc - t0;  t_bg = cyc; end
	if (dut.fstate == 5'd23 && f_prev != 5'd23) begin   // S_DONE
		obj_clk = cyc - t_bg;  t_obj = cyc;
	end
	if (dut.back_line != 8'hFF && bl_prev == 8'hFF) begin
		merge_clk   = cyc - t_obj;
		line_clk    = cyc - t0;
		line_bursts = vram_bursts - b0;
		line_beats  = vram_beats - k0;
		if ($test$plusargs("states")) begin
			$display("   states line %0d: total %0d", dut.tgt, line_clk);
			for (si = 0; si < 32; si = si + 1)
				if (st_cnt[si] != 0)
					$display("     S%-2d = %0d", si, st_cnt[si]);
		end
	end
	f_prev  = dut.fstate;
	bl_prev = dut.back_line;
	bg_prev = dut.phase_bg;
end

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
task check_true;
	input [8*64:1] name;
	input cond;
	begin
		if (!cond) begin
			$display("FAIL %0s", name);
			errors = errors + 1;
		end else $display("ok   %0s", name);
	end
endtask

task check;
	input [8*48:1] name;
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
	pal[515] = 16'h7C1F; // OBJ colour 3 (512 + 3): magenta

	// ---- OAM: entries 0 and 1 normal, everything else affine (skipped).
	// Entry 1 is also the address check: OAM entries are four halfwords
	// apart, so a stride error would land it on entry 0's ATTR3.
	for (k = 0; k < 1024; k = k + 1) oam[k] = 16'h4000;
	oam[0] = 16'h0000;   // ATTR0: y=0, square, normal mode
	oam[1] = 16'h0064;   // ATTR1: x=100, size 0 (8x8)
	oam[2] = 16'h0000;   // ATTR2: tile 0, prio 0, pal bank 0
	oam[4] = 16'h0000;   // entry 1 ATTR0: y=0, square, normal mode
	oam[5] = 16'h00C8;   // ATTR1: x=200, size 0 (8x8)
	oam[6] = 16'h0001;   // ATTR2: tile 1, prio 0, pal bank 0
	// entry 2 is a perfectly normal 8x8 sprite, but 64 lines below the top:
	// the y test has to keep it off line 0
	oam[8]  = 16'h0040;
	oam[9]  = 16'h00A0;  // x=160
	oam[10] = 16'h0001;  // tile 1

	// ---- 3D frame: row 0 has an opaque pixel at x=50, an opaque pixel
	// under the sprite at x=100, and x=51 stays clear (bit 15 = 0)
	for (k = 0; k < 65536; k = k + 1) frame[k] = 16'h0000;
	frame[50]  = 16'hFC1F;   // opaque, magenta (0x7C1F once bit 15 goes)
	frame[100] = 16'hFFFF;   // opaque, white: loses to the sprite on the tie
	frame[51]  = 16'h7C1F;   // same colour, coverage bit clear
	// the second lane of a pair on its own: adjacent columns share a line
	// buffer word, so this catches a lost odd column
	frame[53]  = 16'hE3E0;   // opaque, 0x63E0 after the coverage bit goes
	// a pixel in the merge's third 64-pixel chunk: the chunk addresses have
	// to stay on the line, not walk off its end
	frame[140] = 16'hE7E0;   // opaque, 0x67E0 after the coverage bit goes

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
	// OBJ tile row: obj_base 0x10000 -> halfword idx 0x8000; tile 1 (the
	// second sprite) is 32 bytes later, at halfword 0x8010
	vram[16'h8000] = 16'h2222;     // sprite row0 hw0: all idx 2
	vram[16'h8001] = 16'h2222;     // sprite row0 hw1: all idx 2
	vram[16'h8010] = 16'h3333;     // sprite 1 row0: all idx 3
	vram[16'h8011] = 16'h3333;
	// sprite row1 stays 0 (transparent)

	repeat (4) @(posedge clk);
	reset = 1'b0;
	repeat (4) @(posedge clk);

	// ---- program the engine
	wr_reg(7'h00, 16'h1100); // DISPCNT: mode 0, BG0 + OBJ enable
	wr_reg(7'h08, 16'h0004); // BG0CNT: char base = 16 KB, 32x32, 4bpp
	wr_reg(7'h48, 16'h0000); // BG0HOFS
	wr_reg(7'h4A, 16'h0000); // BG0VOFS
	wr_reg(7'h60, 16'h0001); // DISP3DCNT: 3D layer on (priority = BG0CNT)

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
	sample(8'd50, 8'd0, v);
	check("L0 x50 3D pixel over backdrop", v, 16'h7C1F);
	sample(8'd51, 8'd0, v);
	check("L0 x51 clear coverage -> backdrop", v, 16'h001F);
	sample(8'd53, 8'd0, v);
	check("L0 x53 odd column of a line draws", v, 16'h63E0);
	sample(8'd100, 8'd0, v);
	check("L0 x100 sprite wins 3D tie", v, 16'h03E0);
	// the second sprite lives in OAM entry 1: found by the same scan pass,
	// drawn from its own tile in the same palette bank
	sample(8'd200, 8'd0, v);
	check("L0 x200 second OAM entry draws", v, 16'h7C1F);
	sample(8'd207, 8'd0, v);
	check("L0 x207 second sprite, last pixel", v, 16'h7C1F);
	sample(8'd210, 8'd0, v);
	check("L0 x210 past both sprites, BG transparent", v, 16'h001F);
	sample(8'd160, 8'd0, v);
	check("L0 x160 sprite at y=64 stays off this line, BG shows", v, 16'h7C00);
	sample(8'd162, 8'd0, v);
	check("L0 x162 still BG, no magenta but its own tile", v, 16'h001F);
	sample(8'd140, 8'd0, v);
	check("L0 x140 3D pixel from the third merge chunk", v, 16'h67E0);
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

	// ---- what one line costs now that both fetches are bursts ----------
	// 32 tile columns, one map burst, one sprite row and the 3D merge, all
	// charged at the model's grant latency and one clock per beat
	$display("   line fetch: %0d clocks (BG %0d, OBJ %0d, merge %0d), %0d VRAM grants, %0d beats",
	         line_clk, bg_clk, obj_clk, merge_clk, line_bursts, line_beats);
	check_true("a 256-pixel 4bpp BG line fits its 1280-clock line period",
	           (bg_clk > 0) && (bg_clk < 1280));
	// the per-halfword fetch this replaced took about one grant per halfword
	// (32 map reads + 64 tile reads + 2 sprite reads = ~98 for this line)
	check_true("the line is fetched as bursts, not one request per halfword",
	           (line_bursts > 0) && (line_bursts < 50));
	// the OBJ pass is the OAM walk (258 clocks for all 128 entries) plus the
	// sprites it found; a per-entry handshake would show up as >800 here
	check_true("the OAM scan keeps the OBJ pass inside the line budget",
	           (obj_clk > 0) && (obj_clk < 450));
	check_true("a sprite line still fits its line period", line_clk < 1280);

	//------------------------------------------------------------------
	// 64-wide 8bpp map: the map row needs both 32-entry bursts and a tile
	// row is four halfwords. hofs = 224 puts screen columns 4..31 in the
	// map's upper half, where the entries point at tile 1, so a lost second
	// map burst shows tile 0's colours instead.
	//------------------------------------------------------------------
	px = 8'hFF;
	py = 8'hFF;
	wr_reg(7'h00, 16'h0100); // mode 0, BG0 only: no OBJ, no 3D merge
	wr_reg(7'h08, 16'h4084); // BG0: 64x32, 8bpp, char base 16 KB, screen base 0
	wr_reg(7'h48, 16'h00E0); // BG0HOFS = 224 (28 tiles)
	wr_reg(7'h4A, 16'h0000); // BG0VOFS
	wr_reg(7'h60, 16'h0000); // DISP3DCNT: layer off
	pal[2] = 16'h03E0;       // 8bpp BG index 2: green
	// tile 0 (char base 16 KB -> halfword 0x2000, 4 halfwords per row)
	vram[16'h2000] = 16'h0101; // x0=1, x1=1
	vram[16'h2001] = 16'h0201; // x2=1, x3=2
	vram[16'h2002] = 16'h0202; // x4=2, x5=2
	vram[16'h2003] = 16'h0102; // x6=2, x7=1
	// tile 1 (halfword 0x2020): every pixel index 2 (green)
	for (k = 0; k < 4; k = k + 1) vram[16'h2020 + k] = 16'h0202;
	// map rows 0 and 1 (line 8 is map row 8>>3 = 1): left half (columns
	// 0..31) stays tile 0, right half (32..63) points at tile 1. The right
	// block is 2 KB above the left one (halfword 0x400), 64 bytes per row.
	for (k = 0; k < 32; k = k + 1) vram[16'h0400 + k] = 16'h0001; // row 0
	for (k = 0; k < 32; k = k + 1) vram[16'h0420 + k] = 16'h0001; // row 1

	// fetch line 8 (line start at py 7), then display it: py 8 has
	// tgt[2:0] = 0, so it reads tile row 0. Drive py/on off the falling
	// edge so the line-start event is not raced with the clock edge.
	@(negedge clk);
	py = 8'd7;  on = 1'b1;
	@(posedge clk);
	@(negedge clk);
	on = 1'b0;
	repeat (12000) @(posedge clk);
	@(negedge clk);
	py = 8'd8;  on = 1'b1;
	@(posedge clk);
	$display("   line fetch (8bpp 64-wide BG): %0d clocks, %0d VRAM grants, %0d beats",
	         line_clk, line_bursts, line_beats);
	check_true("the 64-wide map row came in as two bursts",
	           (line_bursts > 0) && (line_bursts < 50));
	sample(8'd0, 8'd8, v);
	check("8bpp 64-wide x0 index 1", v, 16'h7C00);
	sample(8'd3, 8'd8, v);
	check("8bpp x3 is the second half of halfword 1", v, 16'h03E0);
	sample(8'd7, 8'd8, v);
	check("8bpp x7 is the fourth tile-row halfword", v, 16'h7C00);
	sample(8'd40, 8'd8, v);
	check("upper map half: column 5 shows tile 1", v, 16'h03E0);
	sample(8'd47, 8'd8, v);
	check("upper map half, end of the tile row", v, 16'h03E0);
	py = 8'd8;  on = 1'b0;

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
