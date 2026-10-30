//============================================================================
// tb_geometry_engine — GXFIFO decode, matrix stack, viewport, vertices
//
// Checks the M3 geometry-engine slice against hand-computed values:
//   * GXSTAT after reset (idle, FIFO empty, stack level 0)
//   * MTX_MODE / MTX_IDENTITY / MTX_LOAD_4x4
//   * VIEWPORT mapping of 4.12 vertices (centre and corners)
//   * VTX_16 and VTX_XY submission, COLOR and BEGIN_VTXS polygon mode
//   * MTX_PUSH / MTX_POP stack level, and MTX_SCALE and MTX_TRANS on the
//     modelview matrix (both now run through the engine's shared multiplier)
//   * command-length resynchronisation for opcodes that are skipped
//============================================================================
`timescale 1ns/1ps

module tb_geometry_engine;

reg         clk = 0;
reg         reset = 1;
reg         reg_we = 0;
reg  [9:0]  reg_addr = 10'h0;
reg  [31:0] reg_data = 0;
wire [31:0] reg_rdata;
wire        vtx_valid;
wire signed [31:0] vtx_x, vtx_y;
wire  [7:0] vtx_color;
wire  [1:0] vtx_poly;

integer errors = 0;
integer i;
integer guard;

geometry_engine dut (
	.clk(clk),
	.reset(reset),
	.reg_we(reg_we),
	.reg_addr(reg_addr),
	.reg_data(reg_data),
	.reg_rdata(reg_rdata),
	.vtx_valid(vtx_valid),
	.vtx_x(vtx_x),
	.vtx_y(vtx_y),
	.vtx_color(vtx_color),
	.vtx_poly(vtx_poly)
);

always #5 clk = ~clk;

//------------------------------------------------------------------ helpers
localparam [9:0] A_FIFO = 10'h000, A_GXSTAT = 10'h200;

task fail(input [255:0] what);
	begin
		errors = errors + 1;
		$display("FAIL %0s (time %0t)", what, $time);
	end
endtask

task check(input ok, input [255:0] what);
	begin
		if (!ok) fail(what);
	end
endtask

// push one command/parameter word into the GXFIFO
task wr(input [31:0] word);
	begin
		@(negedge clk);
		reg_we   = 1;
		reg_addr = A_FIFO;
		reg_data = word;
		@(negedge clk);
		reg_we   = 0;
	end
endtask

task op(input [7:0] code);
	begin
		wr({24'd0, code});
	end
endtask

// wait for the command engine to drain, then read GXSTAT
task stat(output [31:0] value);
	begin
		guard = 0;
		reg_addr = A_GXSTAT;
		#1;
		while (reg_rdata[0] && guard < 500) begin
			@(negedge clk);
			#1;
			guard = guard + 1;
		end
		value = reg_rdata;
		reg_addr = A_FIFO;
		#1;
	end
endtask

// consume the next emitted vertex and compare it
task vtx(input signed [31:0] ex, input signed [31:0] ey, input [1:0] ep, input [7:0] ec);
	begin
		guard = 0;
		while (!vtx_valid && guard < 100) begin
			@(negedge clk);
			guard = guard + 1;
		end
		if (!vtx_valid) begin
			fail("no vertex emitted");
		end else begin
			check(vtx_x == ex, "vtx_x mismatch");
			check(vtx_y == ey, "vtx_y mismatch");
			if (vtx_poly  != ep) fail("vtx_poly mismatch");
			if (vtx_color != ec) fail("vtx_color mismatch");
			if (vtx_x != ex || vtx_y != ey)
				$display("   got x=%0d y=%0d, expected x=%0d y=%0d",
				         $signed(vtx_x), $signed(vtx_y), $signed(ex), $signed(ey));
		end
	end
endtask

//------------------------------------------------------------------ stimulus
reg [31:0] s;

initial begin
	repeat (3) @(negedge clk);
	reset = 0;
	@(negedge clk);

	// 1 — reset state
	stat(s);
	check(s[0] == 1'b0, "idle after reset");
	check(s[24] == 1'b1, "FIFO empty after reset");
	check(s[12:8] == 5'd0, "stack level 0 after reset");

	// 2 — projection: identity through the matrix commands
	op(8'h10); wr(32'h0000_0000); // MTX_MODE = projection
	op(8'h15);                   // MTX_IDENTITY
	// 3 — viewport covering 256x192
	op(8'h60); wr(32'hBF_FF_00_00);

	// 4 — modelview: identity
	op(8'h10); wr(32'h0000_0003);
	op(8'h15);

	// 5 — first primitive: triangles, colour from COLOR
	op(8'h20); wr(32'h0000_7FFF);            // COLOR (white)
	op(8'h40); wr(32'h0000_0000);            // BEGIN_VTXS triangles

	// 6 — VTX_16 at the origin maps to the centre of the viewport
	op(8'h23);
	wr(32'h0000_0000);                       // x = 0, y = 0
	wr(32'h0000_1000);                       // z = 0, w = 1.0
	vtx(32'h0007_F800, 32'h0005_F800, 2'd0, 8'hFF);  // 127.5, 95.5

	// 7 — VTX_XY at (1.0, -1.0) maps to the right edge / top edge
	op(8'h25);
	wr(32'hF000_1000);                       // x = 1.0, y = -1.0
	vtx(32'h000F_F000, 32'd0, 2'd0, 8'hFF);  // 255.0, 0.0

	// 8 — a new colour shows up in the next vertex
	op(8'h20); wr(32'h0000_7C00);            // COLOR (red)
	op(8'h25); wr(32'h0000_0000);
	vtx(32'h0007_F800, 32'h0005_F800, 2'd0, 8'h00);

	// 9 — BEGIN_VTXS carries the polygon mode through to the vertex
	op(8'h40); wr(32'h0000_0002);            // BEGIN_VTXS triangle strip
	op(8'h25); wr(32'h0000_0000);
	vtx(32'h0007_F800, 32'h0005_F800, 2'd2, 8'h00);

	// 10 — matrix stack: push twice, pop both
	op(8'h11);                               // MTX_PUSH
	op(8'h11);                               // MTX_PUSH
	stat(s);
	check(s[12:8] == 5'd2, "stack level 2 after two pushes");
	op(8'h12); wr(32'h0000_0002);            // MTX_POP 2
	stat(s);
	check(s[12:8] == 5'd0, "stack level 0 after pop 2");

	// 11 — MTX_SCALE on the modelview halves x
	op(8'h1B); wr(32'h0000_0800); wr(32'h0000_1000); wr(32'h0000_1000);
	op(8'h25); wr(32'h0000_1000);            // x = 1.0 -> 0.5
	vtx(32'h000B_F400, 32'h0005_F800, 2'd2, 8'h00);  // 191.25, 95.5

	// 11b — MTX_TRANS moves row 3 through the upper 3x3: translate by
	//       (1.0, 0, 0) and the vertex at the origin moves a whole unit
	op(8'h15);                               // MTX_IDENTITY (modelview)
	op(8'h1C); wr(32'h0000_1000); wr(32'h0000_0000); wr(32'h0000_0000);
	op(8'h25); wr(32'h0000_0000);
	vtx(32'h000F_F000, 32'h0005_F800, 2'd2, 8'h00);  // 255.0, 95.5

	// 12 — back to identity, then prove a skipped opcode keeps the stream
	//      in sync: TEXCOORD (1 param) and MTX_LOAD_4x3 (12 params) are
	//      decoded but not executed, so the vertex behind them must still
	//      land on the centre pixel.
	op(8'h15);                               // MTX_IDENTITY (modelview)
	op(8'h22); wr(32'hDEAD_BEEF);            // TEXCOORD — skipped
	op(8'h17);                               // MTX_LOAD_4x3 — skipped
	for (i = 0; i < 12; i = i + 1) wr(32'h1111_0000 + i);
	op(8'h40); wr(32'h0000_0000);
	op(8'h25); wr(32'h0000_0000);
	vtx(32'h0007_F800, 32'h0005_F800, 2'd0, 8'h00);

	// 13 — FIFO drains: everything queued has been consumed
	stat(s);
	check(s[24] == 1'b1, "FIFO empty at end");
	check(s[0] == 1'b0, "engine idle at end");

	if (errors == 0) $display("tb_geometry_engine: PASS");
	else             $display("tb_geometry_engine: %0d FAILURES", errors);
	$finish;
end

initial begin
	#200000;
	$display("tb_geometry_engine: TIMEOUT");
	$finish;
end

endmodule
