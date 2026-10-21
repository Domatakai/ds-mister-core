//============================================================================
// NDS MiSTer Test — 3D rasterizer — STUB
//
// Milestone M3. Triangle setup + scanline fill at the DS's 15-cycle
// budget per polygon, with toon shading, edge marking, fog and alpha
// test; output lands in VRAM bank C or D through vram_arbiter so
// engine A/B can composite it over the 2D layers.
//============================================================================
module raster_engine (
	input            clk,
	input            reset,

	input            vtx_valid,
	input     [15:0] vtx_x,
	input     [15:0] vtx_y,
	input      [7:0] vtx_color,
	input      [1:0] vtx_poly,

	// pixel request toward VRAM
	output           px_valid,
	output    [15:0] px_addr,
	output    [15:0] px_rgb555
);

assign px_valid = 1'b0;
assign px_addr  = 0;
assign px_rgb555 = 0;

wire _unused = &{1'b0, clk, reset, vtx_valid, vtx_x, vtx_y, vtx_color, vtx_poly};

endmodule
