//============================================================================
// NDS MiSTer Test — 2D engine A (top screen) (milestone M2)
//
// Engine A is the shared text-mode renderer with engine A's register
// set: DISPCNT/BGxCNT/BGxHOFS/VOFS land through the main_bus engine
// write port, palette and OAM are read through the second BRAM ports
// in main_bus, and tile/map data streams out of VRAM through
// vram_arbiter. Interface toward the composer is unchanged from M1:
// the composer asks for pixel (x, y) while `on` is high and gets an
// RGB555 answer combinationally from the front line buffer.
//
// Affine BGs, OBJ windows, mosaic and blending are M3; bitmap modes
// currently render backdrop + OBJ (BG layers are text-only in M2).
//============================================================================
module engine_a (
	input            clk,
	input            reset,
	input      [7:0] x,
	input      [7:0] y,
	input            on,
	output    [15:0] rgb555,

	// register writes from main_bus (byte offset within 0x000..0x07F)
	input            reg_we,
	input      [6:0] reg_addr,
	input     [15:0] reg_data,

	// palette / OAM second read ports (2-cycle latency)
	output     [9:0] pal_addr,
	input     [15:0] pal_data,
	output     [9:0] oam_addr,
	input     [15:0] oam_data,

	// VRAM fetch port toward vram_arbiter (engine A master): a burst of
	// v_len halfwords streamed back one per cycle
	output           v_req,
	output    [19:0] v_addr,
	output     [7:0] v_len,
	input            v_ready,
	input            v_bs_valid,
	input     [15:0] v_bs_data,

	// 3D frame read port (engine A composites the 3D layer, M3): a burst of
	// d3_len halfwords streamed back one per cycle
	output           d3_req,
	output    [16:0] d3_addr,
	output     [7:0] d3_len,
	input            d3_ready,
	input            d3_bs_valid,
	input     [15:0] d3_bs_data
);

renderer_2d renderer (
	.clk(clk),
	.reset(reset),
	.pixel_ce(1'b1),
	.px(x),
	.py(y),
	.on(on),
	.rgb555(rgb555),
	.reg_we(reg_we),
	.reg_addr(reg_addr),
	.reg_data(reg_data),
	.pal_addr(pal_addr),
	.pal_data(pal_data),
	.oam_addr(oam_addr),
	.oam_data(oam_data),
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
`ifdef NDS_NO_3D
	.d3_present(1'b0),      // 3D pipeline compiled out (NDS_NO_3D)
`else
	.d3_present(1'b1),
`endif
	.obj_base(20'h1_0000)   // OBJ tiles start at +64 KB (DS A engine)
);

endmodule
