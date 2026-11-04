//============================================================================
// NDS MiSTer Test — screen composer testbench
//
//   iverilog -g2012 -o /tmp/tb_sc tb/tb_composer.sv \
//            rtl/video/screen_composer.sv && vvp /tmp/tb_sc
//
// Drives the composer directly and checks stacked/swap/side-by-side/
// rotation placement, the lid's blackout, against per-engine pattern
// fixtures. The fixtures
// replicate the M1 engine boot patterns locally: engine_a/engine_b are
// now real line-buffer renderers (tb_renderer_2d covers them), and the
// composer's placement logic needs deterministic per-pixel answers.
//============================================================================
`timescale 1ns / 1ps

module tb_composer;

reg clk = 0;
always #10 clk = ~clk;

reg  [8:0] x = 0, y = 0;
reg        de = 1;
reg  [1:0] vmode = 0;
reg  [2:0] layout = 0;
reg  [1:0] rotation = 0;
reg        swap = 0;
reg  [2:0] brightness = 5;
reg        dark = 0;

wire [7:0] na_x, na_y, nb_x, nb_y;
wire       na_on, nb_on;
wire [15:0] pix_top, pix_bot, rgb555;

screen_composer dut (
	.clk(clk), .ce(1'b1), .x(x), .y(y), .de(de),
	.vmode(vmode), .layout(layout), .rotation(rotation), .swap(swap),
	.brightness(brightness), .dark(dark),
	.na_x(na_x), .na_y(na_y), .na_on(na_on), .pix_top(pix_top),
	.nb_x(nb_x), .nb_y(nb_y), .nb_on(nb_on), .pix_bot(pix_bot),
	.rgb555(rgb555)
);

engine_a_pat ea (.clk(clk), .x(na_x), .y(na_y), .on(na_on), .rgb555(pix_top));
engine_b_pat eb (.clk(clk), .x(nb_x), .y(nb_y), .on(nb_on), .rgb555(pix_bot));

localparam HEADER_A = 16'h739C; // engine A header band {28,28,28}
localparam BORDER_B = 16'h294C; // engine B border      {10,10,12}
localparam BACKDROP_B = 16'h1086; // engine B backdrop   {4,4,6}

// The composer holds its pixel decision for one CE while the engines answer
// (their line buffers are block RAM, so their read is registered), so a sample
// taken in the same cycle as a stimulus change would see the previous pixel.
// Every check below lets that edge pass first.
task settle;
	begin
		@(posedge clk);
		#1;
	end
endtask

integer errors = 0;

task check;
	input [8*24:1] name;
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

initial begin
	#20;

	// stacked: bottom screen starts at y=192; (2,200) is engine B border
	x = 9'd2; y = 9'd200; settle;
	check("stacked bottom", rgb555, BORDER_B);

	// swap screens: the same slot now shows the top screen (header band)
	swap = 1; settle;
	check("swap screens", rgb555, HEADER_A);
	swap = 0;

	// side by side: left half decimates x; (10,100) -> engine A (5,4)
	layout = 3'd1; x = 9'd10; y = 9'd100; settle;
	check("side left decimated", rgb555, HEADER_A);

	// right half is the bottom screen; (200,100) -> engine B (100,4)
	x = 9'd200; settle;
	check("side right bottom", rgb555, BACKDROP_B);

	// rotation 90 inside the bottom box maps (0,300) -> engine B (108,255)
	layout = 3'd0; rotation = 2'd1; x = 9'd0; y = 9'd300; settle;
	check("rot90 bottom", rgb555, BORDER_B);

	// rotated-out-of-range pixels read as backdrop
	x = 9'd200; y = 9'd300; settle;
	check("rot90 clip", rgb555, 16'h0000);

	// lid shut: the backlights are out, so whatever the layout says the
	// frame is black — and it comes back when the shell opens
	layout = 3'd0; rotation = 2'd0; swap = 0; x = 9'd2; y = 9'd200; settle;
	check("lid open: bottom screen border", rgb555, BORDER_B);
	dark = 1; settle;
	check("lid shut: screens dark", rgb555, 16'h0000);
	dark = 0; settle;
	check("lid open again", rgb555, BORDER_B);

	// ---- CRT modes: 240p side by side and 240p single, placement only
	vmode = 2'd1; layout = 3'd0; rotation = 2'd0; swap = 1'b0; de = 1'b1;
	x = 9'd10; y = 9'd30; settle;
	if (!(na_on === 1'b1 && na_x === 8'd10 && na_y === 8'd6 && nb_on === 1'b0)) begin
		$display("tb_composer: FAIL 240p side-by-side left half (na_on=%b %0d,%0d nb_on=%b)",
			na_on, na_x, na_y, nb_on);
		errors = errors + 1;
	end else $display("tb_composer: ok   240p side-by-side: left half is the top screen, native width");

	x = 9'd300; y = 9'd30; settle;
	if (!(nb_on === 1'b1 && nb_x === 8'd44 && na_on === 1'b0)) begin
		$display("tb_composer: FAIL 240p side-by-side right half (na_on=%b nb_on=%b nb_x=%0d)",
			na_on, nb_on, nb_x);
		errors = errors + 1;
	end else $display("tb_composer: ok   240p side-by-side: right half is the bottom screen, native width");

	x = 9'd10; y = 9'd10; settle;
	if (na_on !== 1'b0 || nb_on !== 1'b0) begin
		$display("tb_composer: FAIL 240p side-by-side top border is not blank");
		errors = errors + 1;
	end else $display("tb_composer: ok   240p side-by-side: the 24-line border is blank");

	vmode = 2'd2;
	x = 9'd100; y = 9'd24; settle;
	if (!(na_on === 1'b1 && na_x === 8'd100 && na_y === 8'd0 && nb_on === 1'b0)) begin
		$display("tb_composer: FAIL 240p single first picture line (na_on=%b %0d,%0d)",
			na_on, na_x, na_y);
		errors = errors + 1;
	end else $display("tb_composer: ok   240p single: top screen starts 24 lines down");

	layout = 3'd3;
	x = 9'd100; y = 9'd215; settle;
	if (!(nb_on === 1'b1 && nb_x === 8'd100 && nb_y === 8'd191 && na_on === 1'b0)) begin
		$display("tb_composer: FAIL 240p single Bottom only (nb_on=%b %0d,%0d)", nb_on, nb_x, nb_y);
		errors = errors + 1;
	end else $display("tb_composer: ok   240p single: Bottom only shows the bottom screen");

	vmode = 2'd0; layout = 3'd0;

	if (errors == 0) $display("tb_composer: PASS");
	else             $display("tb_composer: FAIL (%0d errors)", errors);
	$finish;
end

endmodule

//------------------------------------------------------------------
// Per-engine pattern fixtures (former M1 boot patterns)
//------------------------------------------------------------------
module engine_a_pat (
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

module engine_b_pat (
	input            clk,
	input      [7:0] x,
	input      [7:0] y,
	input            on,
	output reg [15:0] rgb555
);
always_comb begin
	if (!on) begin
		rgb555 = 16'h0000;
	end else if (x < 8'd4 || y < 8'd4 || x > 8'd251 || y > 8'd187) begin
		rgb555 = {1'b0, 5'd10, 5'd10, 5'd12};           // border
	end else if (x[3:0] == 0 && y[3:0] == 0) begin
		rgb555 = {1'b0, 5'd20, 5'd20, 5'd22};           // dot grid
	end else begin
		rgb555 = {1'b0, 5'd4, 5'd4, 5'd6};              // backdrop
	end
end
wire _unused = &{1'b0, clk};
endmodule
