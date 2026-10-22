//============================================================================
// NDS MiSTer Test — colour palette / profile
//
// Combinational colour transform on the composed RGB555 stream (sits
// between the spatial video filter and the RGB888 output):
//
//   0 Original    identity
//   1 DS LCD      handheld tint: reds/greens trimmed, blue pushed
//   2 Vivid       +50% saturation around Rec.601 luma
//   3 Warm        red +10% / blue -10%
//   4 Cool        red -10% / blue +10%
//   5 Grayscale   Rec.601 luma
//
// Gains are 8-bit fixed point (256 = 1.0) and clamp to 5-bit; luma uses
// the integer Rec.601 weights 77/150/29 (sum 256).
//============================================================================
module palette (
	input      [2:0] mode,
	input     [15:0] rgb_in,
	output reg [15:0] rgb_o
);

wire [4:0] r = rgb_in[14:10];
wire [4:0] g = rgb_in[9:5];
wire [4:0] b = rgb_in[4:0];

// Rec.601 luma, 0..31 (31 * 256 >> 8 = 31)
wire [12:0] lum13 = r * 13'd77 + g * 13'd150 + b * 13'd29;
wire  [4:0] luma  = lum13[12:8];

function [4:0] gain;                  // c * k / 256, clamped to 31
	input [4:0] c;
	input [8:0] k;
	reg  [13:0] t;
	begin
		t = (c * k) >> 8;
		gain = (t > 14'd31) ? 5'd31 : t[4:0];
	end
endfunction

function [4:0] vivid;                 // saturation boost around luma
	input [4:0] c;
	input [4:0] ly;
	reg signed [8:0] d, t;
	begin
		d = $signed({4'b0000, c}) - $signed({4'b0000, ly});
		t = $signed({4'b0000, ly}) + d + (d >>> 1); // ly + 1.5*(c-ly)
		vivid = (t < 0) ? 5'd0 : (t > 9'sd31) ? 5'd31 : t[4:0];
	end
endfunction

always @(*) begin
	case (mode)
	3'd1: rgb_o = {rgb_in[15], gain(r, 9'd240), gain(g, 9'd250), gain(b, 9'd272)};
	3'd2: rgb_o = {rgb_in[15], vivid(r, luma), vivid(g, luma), vivid(b, luma)};
	3'd3: rgb_o = {rgb_in[15], gain(r, 9'd282), g, gain(b, 9'd230)};
	3'd4: rgb_o = {rgb_in[15], gain(r, 9'd230), g, gain(b, 9'd282)};
	3'd5: rgb_o = {rgb_in[15], luma, luma, luma};
	default: rgb_o = rgb_in;           // 0 Original and reserved modes
	endcase
end

endmodule
