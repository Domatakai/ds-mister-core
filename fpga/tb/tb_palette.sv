//============================================================================
// NDS MiSTer Test — palette testbench
//
//   iverilog -g2012 -o /tmp/tb_pal tb/tb_palette.sv \
//            rtl/video/palette.sv && vvp /tmp/tb_pal
//
// Checks each profile against hand-computed values:
//   0 Original  identity          (incl. bit15 passthrough)
//   1 DS LCD    gain table on white
//   2 Vivid     luma expansion on a mid colour
//   3 Warm      red up / blue down
//   4 Cool      red down / blue up
//   5 Grayscale Rec.601 luma on pure red
//   clamping    warm-mode red saturates at 31
//============================================================================
`timescale 1ns / 1ps

module tb_palette;

reg  [2:0]  mode = 0;
reg  [15:0] rgb_in = 0;
wire [15:0] rgb_o;

palette dut (.mode(mode), .rgb_in(rgb_in), .rgb_o(rgb_o));

integer errors = 0;
task check;
	input [8*48:1] name;
	input [15:0] got, want;
	begin
		if (got !== want) begin
			$display("FAIL %0s: got %h want %h", name, got, want);
			errors = errors + 1;
		end else
			$display("ok   %0s", name);
	end
endtask

task probe;
	input [2:0] m;
	input [15:0] c;
	begin
		mode = m; rgb_in = c;
		#1;
	end
endtask

initial begin
	// ---------------------------------------------- 0 Original identity
	probe(3'd0, 16'h7BAD); check("original identity",      rgb_o, 16'h7BAD);
	probe(3'd0, 16'h8000); check("original bit15",         rgb_o, 16'h8000);

	// ---------------------------------- 1 DS LCD on white (31,31,31)
	// r: 31*240>>8 = 29, g: 31*250>>8 = 30, b: 31*272>>8 = 34 -> 31
	probe(3'd1, 16'h7FFF);
	check("ds-lcd white", rgb_o, {1'b0, 5'd29, 5'd30, 5'd31});

	// ---------------------------------- 2 Vivid on (20,10,5)
	// luma = (20*77 + 10*150 + 5*29)>>8 = (1540+1500+145)>>8 = 12
	// r: 12 + 8 + 4   = 24   (d=8,  d>>1=4)
	// g: 12 - 2 - 1   =  9   (d=-2, d>>1=-1)
	// b: 12 - 7 - 4   =  1   (d=-7, d>>1=-4)
	probe(3'd2, {5'd20, 5'd10, 5'd5});
	check("vivid mid colour", rgb_o, {1'b0, 5'd24, 5'd9, 5'd1});

	// ---------------------------------- 3 Warm on white
	// r: 31*282>>8 = 34 -> 31 (clamp), b: 31*230>>8 = 27
	probe(3'd3, 16'h7FFF);
	check("warm white", rgb_o, {1'b0, 5'd31, 5'd31, 5'd27});

	// ---------------------------------- 4 Cool on white
	// r: 31*230>>8 = 27, b: 31*282>>8 = 34 -> 31 (clamp)
	probe(3'd4, 16'h7FFF);
	check("cool white", rgb_o, {1'b0, 5'd27, 5'd31, 5'd31});

	// ---------------------------------- 5 Grayscale on pure red
	// luma = 31*77>>8 = 2397>>8 = 9
	probe(3'd5, {1'b1, 5'd31, 5'd0, 5'd0});
	check("grayscale pure red", rgb_o, {1'b1, 5'd9, 5'd9, 5'd9});

	// ------------------------- 5 Grayscale on white -> white (bit15 kept)
	probe(3'd5, 16'hFFFF);
	check("grayscale white bit15", rgb_o, {1'b1, 5'd31, 5'd31, 5'd31});

	// ---------------------------------- reserved mode falls through
	probe(3'd6, 16'h2468);
	check("reserved mode identity", rgb_o, 16'h2468);

	if (errors == 0) $display("TB PALETTE PASS");
	else             $display("TB PALETTE FAIL (%0d errors)", errors);
	$finish;
end

endmodule
