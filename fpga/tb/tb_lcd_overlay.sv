//============================================================================
// NDS MiSTer Test — MT-32-pi LCD overlay testbench
//
//   iverilog -g2012 -o /tmp/tb_lcd tb/tb_lcd_overlay.sv \
//            rtl/video/lcd_overlay.sv && vvp /tmp/tb_lcd
//
// Drives a destination raster and the panel stream the way sys/mt32pi.sv
// delivers them (one panel pixel per CE, panel window 8 pixels into the
// active line, restarting on the source vsync). The expected picture is
// built from the geometry knobs — size and corner — independently of the
// module, and every output pixel is compared with it, so a capture or an
// origin that is off fails rather than looking plausible.
//
// Checks:
//   1. de/hs/vs leave the module exactly two pixels later, unchanged.
//   2. 1x top-left: panel dots at their own coordinates, unlit pixels black,
//      box corners inside, picture outside untouched.
//   3. Overlay off passes the picture through inside the box too.
//   4. New panel content replaces the old one on the following frame.
//   5. 2x: both pixels and both lines of a doubled dot, the pixel past it
//      black, the box covering the full 256x128, row 128 back to the picture.
//   6. Top-right, bottom-left and bottom-right at 1x: the whole frame still
//      matches, the dot lands at the shifted position, and where the box
//      used to be the picture passes through.
//   7. 2x bottom-right: full width, bottom 128 lines, picture above it.
//============================================================================
`timescale 1ns / 1ps

module tb_lcd_overlay;

localparam integer PW = 128;   // panel width
localparam integer PH = 64;    // panel height
localparam integer FW = 256;   // composed frame
localparam integer FH = 384;
localparam integer WIN_X = 8;  // where mt32pi's window starts in the line

reg clk = 0;
always #10 clk = ~clk;

reg         reset = 1;
reg         enable = 1;
reg         scale2x = 0;
reg  [1:0]  corner = 2'd0;

// destination raster
reg  [8:0]  x = 0;
reg  [8:0]  y = 0;
reg         de = 0, hs = 0, vs = 0;
reg  [15:0] rgb_in = 16'h0000;

// panel stream
reg         src_de = 0, src_en = 0, src_pix = 0, src_vs = 0;

// panel content: two lit dots at (d1x,d1y) and (d2x,d2y)
integer d1x = 5, d1y = 2, d2x = 100, d2y = 40;

wire [15:0] rgb_o;
wire        de_o, hs_o, vs_o;

lcd_overlay #(.W(PW), .H(PH), .H_ACT(FW), .V_ACT(FH)) dut (
	.clk(clk), .ce(1'b1), .reset(reset), .enable(enable),
	.scale2x(scale2x), .corner(corner),
	.src_de(src_de), .src_en(src_en), .src_pix(src_pix), .src_vs(src_vs),
	.x(x), .y(y), .de(de), .hs(hs), .vs(vs), .rgb_in(rgb_in),
	.rgb_o(rgb_o), .de_o(de_o), .hs_o(hs_o), .vs_o(vs_o)
);

integer errors = 0;
task check;
	input [8*52:1] name;
	input          cond;
	begin
		if (!cond) begin
			$display("FAIL %0s", name);
			errors = errors + 1;
		end else
			$display("ok   %0s", name);
	end
endtask

//------------------------------------------------------------------
// expected geometry, derived from size and corner
//------------------------------------------------------------------
wire [9:0] box_w = scale2x ? 10'd256 : 10'd128;
wire [9:0] box_h = scale2x ? 10'd128 : 10'd64;

wire [9:0] org_x = (corner[0] && box_w < FW) ? (FW - box_w) : 10'd0;
wire [9:0] org_y = corner[1] ? (FH - box_h) : 10'd0;

wire [9:0] xw = {1'b0, x};
wire [9:0] yw = {1'b0, y};

wire in_box = (xw >= org_x) && (xw < org_x + box_w) &&
              (yw >= org_y) && (yw < org_y + box_h);

wire [9:0] rx = xw - org_x;
wire [9:0] ry = yw - org_y;

wire [8:0] pan_x = scale2x ? rx[8:1] : rx[7:0];
wire [8:0] pan_y = scale2x ? ry[8:1] : ry[7:0];

wire pat_bit  = (pan_x == d1x && pan_y == d1y) || (pan_x == d2x && pan_y == d2y);
wire [15:0] exp_now = (enable && de && in_box) ? (pat_bit ? 16'h7FFF : 16'h0000)
                                               : rgb_in;

// where the dots are expected on screen
wire [9:0] p1x = org_x + (scale2x ? (2 * d1x) : d1x);
wire [9:0] p1y = org_y + (scale2x ? (2 * d1y) : d1y);
wire [9:0] p2x = org_x + (scale2x ? (2 * d2x) : d2x);
wire [9:0] p2y = org_y + (scale2x ? (2 * d2y) : d2y);

// is an arbitrary point inside the box?
wire [9:0] t5x = 10'd5, t5y = 10'd2;
wire at_5_2_in_box = (t5x >= org_x) && (t5x < org_x + box_w) &&
                     (t5y >= org_y) && (t5y < org_y + box_h);

reg [15:0] e1 = 0, e0 = 0;
reg [8:0]  x1 = 0, x0 = 0;
reg [8:0]  y1 = 0, y0 = 0;
reg        de1 = 0, de0 = 0, hs1 = 0, hs0 = 0, vs1 = 0, vs0 = 0;

always @(posedge clk) begin
	e1  <= e0;   e0  <= exp_now;
	x1  <= x0;   x0  <= x;
	y1  <= y0;   y0  <= y;
	de1 <= de0;  de0 <= de;
	hs1 <= hs0;  hs0 <= hs;
	vs1 <= vs0;  vs0 <= vs;
end

// observation flags, evaluated on the settled half of the cycle
integer seen_dot1 = 0, seen_dot2 = 0, seen_black = 0, seen_out = 0;
integer seen_edge = 0, seen_off = 0, seen_pass = 0;
integer seen_2x_pair = 0, seen_2x_edge = 0, seen_2x_bottom = 0, seen_2x_above = 0;
integer timing_err = 0, value_err = 0;

always @(negedge clk) if (!reset) begin
	if (de_o !== de1 || hs_o !== hs1 || vs_o !== vs1) timing_err = timing_err + 1;
	if (de_o && rgb_o !== e1) value_err = value_err + 1;

	if (de_o && de1) begin
		// a dot, wherever the box put it
		if (x1 == p1x && y1 == p1y && rgb_o === 16'h7FFF) seen_dot1 = 1;
		if (x1 == p2x && y1 == p2y && rgb_o === 16'h7FFF) seen_dot2 = 1;

		// first pixel of the box is unlit in this pattern
		if (x1 == org_x && y1 == org_y && rgb_o === 16'h0000) seen_edge = 1;

		if (scale2x) begin
			if (x1 == p1x + 10'd1 && y1 == p1y && rgb_o === 16'h7FFF) seen_2x_pair = 1;
			if (x1 == p1x + 10'd1 && y1 == p1y + 10'd1 && rgb_o === 16'h7FFF) seen_2x_pair = 1;
			if (x1 == p1x + 10'd2 && y1 == p1y && rgb_o === 16'h0000) seen_2x_edge = 1;
			if (x1 == 10'd255 && y1 == org_y + 10'd1 && rgb_o === 16'h0000) seen_2x_bottom = 1;
			if (x1 == 10'd10 && y1 == 10'd10 && org_y != 10'd0 &&
			    rgb_o === 16'h010A) seen_2x_above = 1;
		end

		// picture where the box is not, and inside it with the option off
		if (!at_5_2_in_box && x1 == 10'd5 && y1 == 10'd2 && rgb_o === 16'h0105)
			seen_pass = 1;
		if (!enable && x1 == 10'd5 && y1 == 10'd2 && rgb_o === 16'h0105)
			seen_off = 1;

		// well away from any corner
		if (x1 == 10'd200 && y1 == 10'd10 && !in_box && rgb_o === 16'h01C8)
			seen_out = 1;
	end
end

//------------------------------------------------------------------
// drive one frame: vsync, 384 active lines, then blanking
//------------------------------------------------------------------
integer xi, yi;
task frame;
	begin
		// vsync pulse
		vs = 1; src_vs = 1;
		repeat (4) @(posedge clk);
		vs = 0; src_vs = 0;
		repeat (4) @(posedge clk);

		for (yi = 0; yi < FH; yi = yi + 1) begin
			for (xi = 0; xi < FW; xi = xi + 1) begin
				@(negedge clk);
				// x/y and everything derived from them change together
				x = xi;
				y = yi;
				de     = 1;
				src_de = 1;
				// stream window: panel pixels 0..127 at x = 8..135
				src_en  = (xi >= WIN_X) && (xi < WIN_X + PW) && (yi < PH);
				src_pix = ((xi - WIN_X) == d1x && yi == d1y) ||
				          ((xi - WIN_X) == d2x && yi == d2y);
				rgb_in  = 16'h0100 + xi;
			end
			// horizontal blanking
			for (xi = 0; xi < 24; xi = xi + 1) begin
				@(negedge clk);
				de     = 0;
				src_de = 0;
				src_en = 0;
				rgb_in = 16'h0BAD;
			end
			hs = 1;
			@(negedge clk);
			hs = 0;
			@(negedge clk);
		end

		// frame blanking
		de = 0; src_de = 0; src_en = 0; x = 0;
		repeat (16) @(negedge clk);
	end
endtask

task clear_flags;
	begin
		seen_dot1 = 0; seen_dot2 = 0; seen_black = 0; seen_out = 0;
		seen_edge = 0; seen_off = 0; seen_pass = 0;
		seen_2x_pair = 0; seen_2x_edge = 0; seen_2x_bottom = 0; seen_2x_above = 0;
		timing_err = 0; value_err = 0;
	end
endtask

initial begin
	repeat (4) @(posedge clk);
	reset = 0;
	repeat (2) @(posedge clk);

	// ------------------------------------------------ 1..2. 1x top left
	frame;               // capture frame (the row being written is the row
	                     // being read, so content shows up on the next one)
	clear_flags;
	frame;

	check("de/hs/vs delayed exactly two pixels", timing_err == 0);
	check("every pixel matches the panel/picture", value_err == 0);
	check("dot at panel (5,2) is white", seen_dot1 == 1);
	check("dot at panel (100,40) is white", seen_dot2 == 1);
	check("first pixel of the box is black", seen_edge == 1);
	check("pixels outside the box keep the picture", seen_out == 1);

	// ------------------------------------------------ 3. overlay off
	enable = 0;
	clear_flags;
	frame;
	check("overlay off passes the picture through", seen_off == 1 && value_err == 0);

	// ------------------------------------------------ 4. new content
	enable = 1;
	d1x = 60; d1y = 30;
	d2x = 50; d2y = 20;
	clear_flags;
	frame;               // capture the new dots (still shows the old frame)
	clear_flags;         // the panel lags one frame by design
	frame;
	check("new dot at (60,30) replaces the old content", seen_dot1 == 1);
	check("new dot at (50,20) is drawn", seen_dot2 == 1);
	check("new frame is otherwise consistent", value_err == 0);

	// ------------------------------------------------ 5. 2x, top left
	scale2x = 1; corner = 2'd0;
	clear_flags;
	frame;
	check("2x frame is aligned to the panel grid", value_err == 0);
	check("both pixels of a doubled dot are white", seen_2x_pair == 1);
	check("the pixel past a doubled dot is black", seen_2x_edge == 1);
	check("2x box covers the full width", seen_2x_bottom == 1);

	// ------------------------------------------------ 6. corners at 1x
	scale2x = 0;

	corner = 2'd1;                       // top right
	clear_flags;
	frame;
	check("top right: frame consistent", value_err == 0);
	check("top right: dot lands at its shifted position", seen_dot1 == 1);
	check("top right: left edge is the picture again", seen_pass == 1);

	corner = 2'd2;                       // bottom left
	clear_flags;
	frame;
	check("bottom left: frame consistent", value_err == 0);
	check("bottom left: dot lands at its shifted position", seen_dot1 == 1);
	check("bottom left: top of the frame is the picture", seen_pass == 1);

	corner = 2'd3;                       // bottom right
	clear_flags;
	frame;
	check("bottom right: frame consistent", value_err == 0);
	check("bottom right: dot lands at its shifted position", seen_dot1 == 1);
	check("bottom right: left edge is the picture again", seen_pass == 1);

	// ------------------------------------------------ 7. 2x bottom right
	scale2x = 1; corner = 2'd3;
	clear_flags;
	frame;
	check("2x bottom right: frame consistent", value_err == 0);
	check("2x bottom right: box reaches the bottom rows", seen_2x_bottom == 1);
	check("2x bottom right: picture above the box", seen_2x_above == 1);

	if (errors == 0) $display("TB LCD OVERLAY PASS");
	else             $display("TB LCD OVERLAY FAIL (%0d errors)", errors);
	$finish;
end

endmodule
