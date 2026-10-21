//============================================================================
// NDS MiSTer Test — 2D engine A (top screen) — STUB
//
// The real engine implements the DS's A engine: text, affine and
// extended BG modes, OBJ windowing, mosaic, alpha blending, and the
// capture unit's destination writes (milestone M2). Until then this
// answers the composer's native-pixel requests with a boot pattern so
// the whole video path can be validated on hardware.
//
// Interface is final: the composer asks for pixel (x, y) while `on` is
// high; a later revision reads from line buffers fed by VRAM through
// vram_arbiter instead of generating the pattern here.
//============================================================================
module engine_a (
	input            clk,
	input      [7:0] x,
	input      [7:0] y,
	input            on,
	output reg [15:0] rgb555
);

always_comb begin
	if (!on) begin
		rgb555 = 16'h0000;
	end else if (y < 8'd16) begin
		rgb555 = {1'b0, 5'd28, 5'd28, 5'd28};           // header band
	end else if (y[3:0] == 0 || x[3:0] == 0) begin
		rgb555 = {1'b0, 5'd8, 5'd8, 5'd10};             // hairline grid
	end else begin
		rgb555 = {1'b0, y[7:3], y[7:3], 5'd16};         // vertical ramp
	end
end

wire _unused = &{1'b0, clk};

endmodule
