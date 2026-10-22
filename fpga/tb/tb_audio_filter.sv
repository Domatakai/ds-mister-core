//============================================================================
// NDS MiSTer Test — audio filter testbench
//
//   iverilog -g2012 -o /tmp/tb_af tb/tb_audio_filter.sv \
//            rtl/audio/audio_filter.sv && vvp /tmp/tb_af
//
// Checks:
//   1. EQ Off + width Off is an exact sample-through (incl. extremes).
//   2. Mid-only signal (L==R) is unchanged by any width setting.
//   3. Side-only signal (L==-R) gains 1.25x / 1.5x with correct phase.
//   4. Strong width saturates instead of wrapping.
//   5. Warm EQ settles at DC - 7 (one-pole floor freezes the gap at 7).
//   6. Bright EQ overshoots on a step edge (x + (x - lp)), then settles.
//   7. Output holds between strobes.
//============================================================================
`timescale 1ns / 1ps

module tb_audio_filter;

reg clk = 0;
always #10 clk = ~clk; // 50 MHz

reg        reset = 1;
reg        strobe = 0;
reg  [1:0] mode = 0;
reg  [1:0] width = 0;
reg [15:0] in_l = 0, in_r = 0;
wire [15:0] out_l, out_r;

audio_filter dut (
	.clk(clk), .reset(reset), .strobe(strobe),
	.mode(mode), .width(width),
	.in_l(in_l), .in_r(in_r),
	.out_l(out_l), .out_r(out_r)
);

integer errors = 0;
task check2;
	input [8*48:1] name;
	input [15:0] gl, wl, gr, wr;
	begin
		if (gl !== wl || gr !== wr) begin
			$display("FAIL %0s: L got %h want %h | R got %h want %h",
			         name, gl, wl, gr, wr);
			errors = errors + 1;
		end else
			$display("ok   %0s", name);
	end
endtask

// apply one sample with a strobe and settle
task samp;
	input [15:0] l, r;
	begin
		@(negedge clk);
		in_l = l; in_r = r; strobe = 1;
		@(negedge clk);
		strobe = 0;
		#1;
	end
endtask

task tick;   // clock with no strobe
	begin
		@(negedge clk);
		#1;
	end
endtask

task do_reset;
	begin
		@(negedge clk); reset = 1;
		@(negedge clk); reset = 0;
		#1;
	end
endtask

integer i;
reg [15:0] held_l, held_r;

initial begin
	repeat (3) @(negedge clk);
	reset = 0;

	// ------------------------------------------ 1. exact pass-through
	mode = 2'd0; width = 2'd0;
	samp(16'h1234, 16'hEDCC);
	check2("pass-through ordinary", out_l, 16'h1234, out_r, 16'hEDCC);
	samp(16'h8001, 16'h7FFF);   // extremes
	check2("pass-through extremes", out_l, 16'h8001, out_r, 16'h7FFF);

	// ------------------------------------------ 2. mid-only vs width
	// L==R: side = 0, every width must leave the signal untouched
	for (i = 0; i <= 2; i = i + 1) begin
		width = i[1:0];
		samp(16'h2000, 16'h2000);
		check2("mid-only unchanged by width 0/1/2", out_l, 16'h2000, out_r, 16'h2000);
	end
	width = 2'd0;

	// ------------------------------------------ 3. side-only, Strong
	// L = -R = 1000: mid = 0, side = 1000 -> 1.5x = 1500, r = -1500
	mode = 2'd0; width = 2'd2;
	samp(16'd1000, -16'd1000);
	check2("side-only strong 1.5x", out_l, 16'd1500, out_r, -16'd1500);

	// Soft: 1000 * 1.25 = 1250 ... on 800: 1000/-1000? no: 800*1.25 = 1000
	width = 2'd1;
	samp(16'd800, -16'd800);
	check2("side-only soft 1.25x", out_l, 16'd1000, out_r, -16'd1000);

	// ------------------------------------------ 4. saturation
	width = 2'd2;
	samp(16'd30000, -16'd30000);   // side 30000 -> 45000 -> clamp
	check2("strong width saturates", out_l, 16'h7FFF, out_r, 16'h8000);

	// ------------------------------------------ 5. Warm EQ settles on DC
	// one-pole from anywhere toward 8000 freezes with gap 7 -> out 7993
	mode = 2'd1; width = 2'd0;
	for (i = 0; i < 96; i = i + 1) samp(16'd8000, 16'd8000);
	check2("warm EQ settles at DC-7", out_l, 16'd7993, out_r, 16'd7993);

	// ------------------------------------------ 6. Bright EQ step edge
	// reset so lp = 0; first sample of 0 -> 8000 step:
	// nl = 8000/8 = 1000, el = 8000 + (8000 - 1000) = 15000
	do_reset;
	mode = 2'd2; width = 2'd0;
	samp(16'd0, 16'd0);
	samp(16'd8000, 16'd8000);
	check2("bright EQ step edge overshoot", out_l, 16'd15000, out_r, 16'd15000);
	// settles: lp -> 7993, el = 8000 + 7 = 8007
	for (i = 0; i < 96; i = i + 1) samp(16'd8000, 16'd8000);
	check2("bright EQ settles near DC", out_l, 16'd8007, out_r, 16'd8007);

	// ------------------------------------------ 7. holds between strobes
	mode = 2'd0; width = 2'd0;
	samp(16'h0F0F, 16'hF0F0);
	held_l = out_l; held_r = out_r;
	in_l = 16'hFFFF; in_r = 16'h0001;   // change input, no strobe
	tick; tick; tick;
	check2("output holds without strobe", out_l, held_l, out_r, held_r);

	if (errors == 0) $display("TB AUDIO FILTER PASS");
	else             $display("TB AUDIO FILTER FAIL (%0d errors)", errors);
	$finish;
end

endmodule
