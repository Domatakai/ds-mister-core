//============================================================================
// tb_raster_engine — triangle setup, bbox fill, strips, colour, clipping
//
// Hand-computed expectations (pixel centres at +0.5, inclusive edges):
//   * 4x4 corner triangle (0,0)(4,0)(0,4) fills 10 pixels: every (x,y)
//     with x+y <= 3 — the hypotenuse x+y=4 passes through pixel corners,
//     so the inclusive rule cannot shift the count.
//   * The 4-vertex triangle strip adds (4,0)(0,4)(4,4), which covers 10
//     more pixels (x+y >= 3 within 0..3 on both axes): 20 emissions over
//     16 distinct addresses, the 4 pixels of the shared x+y=3 edge drawn
//     twice.
//   * RGB555 expansion of 0x1B is 0x037F plus the bit-15 coverage
//     marker -> 0x837F; white is 0xFFFF.
//   * A triangle far off-screen must still clip to 0..255 x 0..191.
//============================================================================
`timescale 1ns/1ps

module tb_raster_engine;

reg         clk = 0;
reg         reset = 1;
reg         vtx_valid = 0;
reg signed [31:0] vtx_x = 0;
reg signed [31:0] vtx_y = 0;
reg   [7:0] vtx_color = 8'hFF;
reg   [1:0] vtx_poly = 2'd0;

wire        px_valid;
wire [15:0] px_addr;
wire [15:0] px_rgb555;
reg         px_ready = 0;

integer errors = 0;
integer guard;

raster_engine dut (
	.clk(clk),
	.reset(reset),
	.vtx_valid(vtx_valid),
	.vtx_x(vtx_x),
	.vtx_y(vtx_y),
	.vtx_color(vtx_color),
	.vtx_poly(vtx_poly),
	.px_valid(px_valid),
	.px_addr(px_addr),
	.px_rgb555(px_rgb555),
	.px_ready(px_ready)
);

always #5 clk = ~clk;

// back-pressure: the VRAM bus is only ready every other cycle, so every
// pixel must be held until it is accepted — exactly once
always @(posedge clk) px_ready <= ~px_ready;

//------------------------------------------------------------------ capture
localparam MAXPIX = 2048;
reg [15:0] cap_addr [0:MAXPIX-1];
reg [15:0] cap_rgb  [0:MAXPIX-1];
integer    cap_n = 0;
integer    oob = 0;          // pixels emitted outside the 256x192 screen

always @(posedge clk) begin
	if (px_valid && px_ready) begin
		if (cap_n < MAXPIX) begin
			cap_addr[cap_n] = px_addr;
			cap_rgb[cap_n]  = px_rgb555;
		end
		if (px_addr > 16'd49151) oob = oob + 1;   // y > 191
		cap_n = cap_n + 1;
	end
end

//------------------------------------------------------------------ helpers
task fail(input [8*72:1] what);
	begin
		errors = errors + 1;
		$display("FAIL %0s (time %0t)", what, $time);
	end
endtask

task check(input ok, input [8*72:1] what);
	begin
		if (!ok) fail(what);
	end
endtask

task clear_capture;
	begin
		cap_n = 0;
		oob   = 0;
	end
endtask

// one vertex in 4.12 fixed point, coordinates given in whole pixels
task vert(input integer x, input integer y, input [7:0] col, input [1:0] mode);
	begin
		@(negedge clk);
		vtx_valid = 1;
		vtx_x     = x * 4096;
		vtx_y     = y * 4096;
		vtx_color = col;
		vtx_poly  = mode;
		@(negedge clk);
		vtx_valid = 0;
	end
endtask

// wait until the engine has been idle for three consecutive cycles
task settle;
	integer quiet;
	begin
		quiet = 0;
		guard = 0;
		while (quiet < 3 && guard < 200000) begin
			@(negedge clk);
			if (dut.state == 2'd0 && !px_valid) quiet = quiet + 1;
			else quiet = 0;
			guard = guard + 1;
		end
		if (guard >= 200000) fail("settle timeout");
		@(negedge clk);
	end
endtask

// how many times an address was emitted
function integer hits(input integer addr);
	integer i;
	begin
		hits = 0;
		for (i = 0; i < cap_n && i < MAXPIX; i = i + 1)
			if (cap_addr[i] == addr) hits = hits + 1;
	end
endfunction

function integer distinct;
	integer i, j, n, dup;
	begin
		n = 0;
		for (i = 0; i < cap_n && i < MAXPIX; i = i + 1) begin
			dup = 0;
			for (j = 0; j < i; j = j + 1)
				if (cap_addr[j] == cap_addr[i]) dup = 1;
			if (!dup) n = n + 1;
		end
		distinct = n;
	end
endfunction

//------------------------------------------------------------------ checks
integer expected [0:31];
integer n_expected = 0;

task expect_pixels;
	begin
		check(distinct() == n_expected, "distinct pixel count");
		check(cap_n == n_expected, "emitted pixel count");
	end
endtask

integer i, addr;

initial begin
	repeat (3) @(negedge clk);
	reset = 0;
	@(negedge clk);

	// ---- 1: corner triangle, white -------------------------------------
	clear_capture();
	vert(0, 0, 8'hFF, 2'd0);
	vert(4, 0, 8'hFF, 2'd0);
	vert(0, 4, 8'hFF, 2'd0);
	settle();

	$display("  triangle: %0d pixels, %0d distinct", cap_n, distinct());
	n_expected = 10;
	expect_pixels();
	// every (x,y) with x+y <= 3, exactly once
	expected[0] = 0;          // (0,0)
	expected[1] = 1;          // (1,0)
	expected[2] = 2;          // (2,0)
	expected[3] = 3;          // (3,0)
	expected[4] = 256;        // (0,1)
	expected[5] = 257;        // (1,1)
	expected[6] = 258;        // (2,1)
	expected[7] = 512;        // (0,2)
	expected[8] = 513;        // (1,2)
	expected[9] = 768;        // (0,3)
	for (i = 0; i < 10; i = i + 1) begin
		addr = expected[i];
		check(hits(addr) == 1, "inside pixel present once");
	end
	// a pixel beyond the hypotenuse is not drawn
	check(hits(4) == 0, "outside pixel skipped (4,0)");
	check(hits(514) == 0, "outside pixel skipped (2,2)");
	for (i = 0; i < cap_n && i < MAXPIX; i = i + 1)
		check(cap_rgb[i] == 16'hFFFF, "white expands to 0xFFFF (bit 15 = coverage)");

	// ---- 2: 4-vertex triangle strip ------------------------------------
	clear_capture();
	vert(0, 0, 8'hFF, 2'd2);
	vert(4, 0, 8'hFF, 2'd2);
	vert(0, 4, 8'hFF, 2'd2);
	vert(4, 4, 8'hFF, 2'd2);
	settle();

	$display("  strip: %0d pixels, %0d distinct", cap_n, distinct());
	check(cap_n == 20, "strip emits two triangles (20 pixels)");
	check(distinct() == 16, "strip covers 16 distinct pixels");
	check(hits(3)   == 2, "shared edge pixel (3,0) drawn twice");
	check(hits(258) == 2, "shared edge pixel (2,1) drawn twice");
	check(hits(513) == 2, "shared edge pixel (1,2) drawn twice");
	check(hits(768) == 2, "shared edge pixel (0,3) drawn twice");
	check(hits(771) == 1, "second-triangle pixel (3,3) drawn once");

	// ---- 3: colour expansion -------------------------------------------
	clear_capture();
	vert(0, 0, 8'h1B, 2'd0);
	vert(2, 0, 8'h1B, 2'd0);
	vert(0, 2, 8'h1B, 2'd0);
	settle();

	$display("  colour: %0d pixels", cap_n);
	check(cap_n == 3, "small triangle emits three pixels");
	for (i = 0; i < cap_n && i < MAXPIX; i = i + 1)
		check(cap_rgb[i] == 16'h837F, "0x1B expands to 0x837F (bit 15 = coverage)");

	// ---- 4: clipping far off screen ------------------------------------
	clear_capture();
	vert(-10, -10, 8'hFF, 2'd0);
	vert(300, -10, 8'hFF, 2'd0);
	vert(-10, 300, 8'hFF, 2'd0);
	settle();

	check(cap_n > 0, "off-screen triangle still fills the visible part");
	check(cap_n <= 49152, "fill stays inside the screen area");
	check(oob == 0, "no pixel address outside 256x192");

	// ---- 5: degenerate triangle draws nothing --------------------------
	clear_capture();
	vert(2, 2, 8'hFF, 2'd0);
	vert(2, 2, 8'hFF, 2'd0);
	vert(2, 2, 8'hFF, 2'd0);
	settle();
	check(cap_n == 0, "zero-area triangle emits nothing");

	if (errors == 0) $display("tb_raster_engine: PASS");
	else             $display("tb_raster_engine: %0d FAILURES", errors);
	$finish;
end

initial begin
	#50_000_000;
	$display("tb_raster_engine: TIMEOUT");
	$finish;
end

endmodule
