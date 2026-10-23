//============================================================================
// NDS MiSTer Test — 2D engine B (bottom screen) (milestone M2)
//
// Engine B drives the touch screen: same text-mode renderer as engine
// A with engine B's own register set (0x1000..0x107F), palette bank
// and OAM — the main_bus exposes separate second BRAM ports for it.
// B differs from A only by lacking the capture unit (M3) and by the
// VRAM banks mapped to MST 3; the renderer itself is shared.
//
// Interface toward the composer is unchanged from M1: the composer
// asks for pixel (x, y) while `on` is high and gets an RGB555 answer
// combinationally from the front line buffer.
//============================================================================
module engine_b (
	input            clk,
	input            reset,
	input      [7:0] x,
	input      [7:0] y,
	input            on,
	output    [15:0] rgb555,

	// register writes from main_bus (byte offset within 0x1000..0x107F)
	input            reg_we,
	input      [6:0] reg_addr,
	input     [15:0] reg_data,

	// palette / OAM second read ports (2-cycle latency)
	output     [9:0] pal_addr,
	input     [15:0] pal_data,
	output     [9:0] oam_addr,
	input     [15:0] oam_data,

	// VRAM fetch port toward vram_arbiter (engine B master)
	output           v_req,
	output    [19:0] v_addr,
	input            v_ready,
	input     [15:0] v_rdata
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
	.v_ready(v_ready),
	.v_rdata(v_rdata),
	.obj_base(20'h1_0000)   // OBJ tiles start at +64 KB (DS B engine)
);

endmodule
