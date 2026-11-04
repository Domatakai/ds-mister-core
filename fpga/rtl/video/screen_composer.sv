//============================================================================
// NDS MiSTer Test — dual-screen composer
//
// Places the two native 256x192 screens into the 256x384 output frame
// according to the OSD layout/rotation/swap settings, applies the
// brightness setting, and hands the result to the video pipeline.
//
// For each output pixel the composer computes which native screen pixel
// belongs there (including the 0/90/180/270 rotation remap), then asks
// the corresponding 2D engine for its colour. The engines answer
// combinationally from their front line buffers, which a fetch FSM
// fills from VRAM through vram_arbiter (M2) — this interface never
// changed from the M1 stub contract.
//
// Layouts, named as the OSD row names them (output frame stays 256x384,
// single frame rate; `layout` keeps the engine-side numbering):
//   0 Vertical    top above bottom, native resolution — the DS's own folding
//   1 Horizontal  side by side, each screen decimated to 128x192 (x >> 1)
//   2 Top only    top screen centred, native
//   3 Bottom only bottom screen centred, native
//
// `dark` is the shell: with the lid shut a DS shows nothing (the backlights
// go out), so the composed pixel is forced to black while it is held. The
// engines keep running — only the picture changes.
//============================================================================
module screen_composer (
	input            clk,
	input            ce,        // pixel CE
	input      [8:0] x,         // 0..255
	input      [8:0] y,         // 0..383
	input            de,
	input      [1:0] vmode,     // 0 HDMI/31 kHz, 1 240p side by side, 2 240p single
	input      [2:0] layout,
	input      [1:0] rotation,
	input            swap,
	input      [2:0] brightness,
	input            dark,       // lid closed: both screens off

	// native-pixel request toward the engines (top = engine A, bottom = B)
	output     [7:0] na_x,
	output     [7:0] na_y,
	output           na_on,
	input     [15:0] pix_top,

	output     [7:0] nb_x,
	output     [7:0] nb_y,
	output           nb_on,
	input     [15:0] pix_bot,

	// composed frame pixel (RGB555, brightness applied)
	output    [15:0] rgb555
);

//------------------------------------------------------------------
// Which screen covers this output pixel, and its in-screen position
//------------------------------------------------------------------
reg [7:0] sx;        // x within the 256-wide screen box
reg [7:0] sy;        // y within the 192-tall screen box
reg       use_top;   // which screen
reg       box_hit;   // inside that screen's box

always_comb begin
	sx = 8'd0;
	sy = 8'd0;
	use_top = 1'b1;
	box_hit = 1'b0;

	if (vmode == 2'd1) begin
		// CRT 240p, both screens at native width in one 512-pixel line.
		// x[7:0] wraps at 256, so it is already the in-screen column for
		// the right-hand screen as well.
		use_top = (x < 9'd256) ^ swap;
		sx = x[7:0];
		sy = y[7:0] - 8'd24;          // 192-line picture centred in 240
		box_hit = (y >= 9'd24) && (y < 9'd216);
	end else if (vmode == 2'd2) begin
		// CRT 240p, one screen at native size, centred the same way.
		sx = x[7:0];
		sy = y[7:0] - 8'd24;
		use_top = (layout != 3'd3) ^ swap;   // Bottom only picks engine B
		box_hit = (y >= 9'd24) && (y < 9'd216);
	end else begin
	case (layout)
	3'd1: begin // side by side, decimated to 128 wide
		sy = y[7:0] - 8'd96;              // centred vertically
		sx = {1'b0, x[7:1]};              // decimate x
		use_top = (x < 9'd128) ^ swap;
		box_hit = (y >= 9'd96) && (y < 9'd288);
	end
	3'd2: begin // top only
		sx = x[7:0];
		sy = y[7:0] - 8'd96;
		use_top = ~swap;
		box_hit = (y >= 9'd96) && (y < 9'd288);
	end
	3'd3: begin // bottom only
		sx = x[7:0];
		sy = y[7:0] - 8'd96;
		use_top = swap;
		box_hit = (y >= 9'd96) && (y < 9'd288);
	end
	default: begin // stacked
		sx = x[7:0];
		// the box (upper/lower half) sets the local y; swap only
		// chooses which engine fills each box
		sy = (y < 9'd192) ? y[7:0] : (y[7:0] - 8'd192);
		use_top = (y < 9'd192) ^ swap;
		box_hit = 1'b1;
	end
	endcase
	end
end

//------------------------------------------------------------------
// Rotation remap inside the 256x192 screen box. Rotated screens are
// transposed; pixels outside the native 256x192 area read as backdrop.
//------------------------------------------------------------------
reg [7:0] nx, ny;
reg       rot_ok;
always_comb begin
	rot_ok = 1'b1;
	case (rotation)
	2'd1: begin // 90 deg CW: (x,y) -> (y, 255-x)
		nx = sy;
		ny = 8'd255 - sx;
		rot_ok = (sx < 8'd192); // rotated height = 192
	end
	2'd2: begin // 180: (x,y) -> (255-x, 191-y)
		nx = 8'd255 - sx;
		ny = 8'd191 - sy;
	end
	2'd3: begin // 270 deg CW: (x,y) -> (191-y, x)
		nx = 8'd191 - sy;
		ny = sx;
		rot_ok = (sx < 8'd192);
	end
	default: begin
		nx = sx;
		ny = sy;
	end
	endcase
end

wire in_range = box_hit & rot_ok;

assign na_on = ce & de & in_range &  use_top;
assign nb_on = ce & de & in_range & ~use_top;
assign na_x  = nx;
assign na_y  = ny;
assign nb_x  = nx;
assign nb_y  = ny;

//------------------------------------------------------------------
// Brightness: OS brightness 1..5 -> fixed-point gain
//------------------------------------------------------------------
reg [9:0] gain;
always_comb begin
	case (brightness)
	3'd1:    gain = 10'd164; // 0.64
	3'd2:    gain = 10'd192; // 0.75
	3'd3:    gain = 10'd218; // 0.85
	3'd4:    gain = 10'd240; // 0.94
	default: gain = 10'd256; // 1.00 (OS level 5)
	endcase
end

wire [15:0] pix = in_range ? (use_top ? pix_top : pix_bot) : 16'h0000;

// 8.8 fixed multiply of each 5-bit channel
function [4:0] scale555;
	input [4:0] c;
	input [9:0] g;
	reg [13:0] m;
	begin
		m = c * g;
		scale555 = m[12:8];
	end
endfunction

wire [4:0] r5 = scale555(pix[14:10], gain);
wire [4:0] g5 = scale555(pix[9:5],   gain);
wire [4:0] b5 = scale555(pix[4:0],   gain);

assign rgb555 = dark ? 16'h0000 : {1'b0, r5, g5, b5}; // BGR555, bit 15 unused

endmodule
