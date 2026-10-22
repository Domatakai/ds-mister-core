//============================================================================
// NDS MiSTer Test — video filter testbench
//
//   iverilog -g2012 -o /tmp/tb_vf tb/tb_video_filter.sv \
//            rtl/video/video_filter.sv && vvp /tmp/tb_vf
//
// Checks:
//   1. mode 0 (Off) is a pure pass-through at constant latency K
//      (found by search; de_o must have the same K — alignment).
//   2. A uniform frame comes out uniform in every blend mode, including
//      the folded edges at x=0 / y=0.
//   3. Smooth mode at a vertical step boundary gives the exact 2x2
//      average (a+b)/2 per channel in the interior.
//   4. Sharp mode on a uniform frame is the identity (2c - c = c),
//      covered by (2).
//============================================================================
`timescale 1ns / 1ps

module tb_video_filter;

reg clk = 0;
always #10 clk = ~clk; // 50 MHz

localparam XMAX = 24;   // small frame: 24x8 active
localparam YMAX = 8;

reg  [2:0]  mode = 0;
reg  [8:0]  x = 0, y = 0;
reg         de = 0, hs = 0, vs = 0;
reg  [15:0] rgb_in = 0;
wire [15:0] rgb_o;
wire        de_o, hs_o, vs_o;

video_filter dut (
	.clk(clk), .ce(1'b1), .mode(mode),
	.x(x), .y(y), .de(de), .hs(hs), .vs(vs),
	.rgb_in(rgb_in),
	.rgb_o(rgb_o), .de_o(de_o), .hs_o(hs_o), .vs_o(vs_o)
);

integer errors = 0;
task check;
	input [8*48:1] name;
	input cond;
	begin
		if (!cond) begin
			$display("FAIL %0s", name);
			errors = errors + 1;
		end else
			$display("ok   %0s", name);
	end
endtask

// stream recording (one sample per clock, ce tied high)
localparam SMAX = 4096;
reg [15:0] in_rgb  [0:SMAX-1];
reg        in_de   [0:SMAX-1];
reg [15:0] out_rgb [0:SMAX-1];
reg        out_de  [0:SMAX-1];
integer n_s;

// drive one pixel for one clock and record both streams
task drive;
	input [8:0] px, py;
	input       d;
	input [15:0] c;
	begin
		@(negedge clk);
		x = px; y = py; de = d; rgb_in = c;
		in_rgb[n_s] = c; in_de[n_s] = d;
		@(posedge clk);
		#1;
		out_rgb[n_s] = rgb_o; out_de[n_s] = de_o;
		n_s = n_s + 1;
	end
endtask

task idle;   // blanking clock (keeps pipeline moving)
	begin
		@(negedge clk);
		x = 0; y = 0; de = 0; rgb_in = 16'h0000;
		in_rgb[n_s] = 16'h0000; in_de[n_s] = 1'b0;
		@(posedge clk);
		#1;
		out_rgb[n_s] = rgb_o; out_de[n_s] = de_o;
		n_s = n_s + 1;
	end
endtask

task frame_uniform;
	input [15:0] c;
	integer px, py;
	begin
		for (py = 0; py < YMAX; py = py + 1)
			for (px = 0; px < XMAX; px = px + 1)
				drive(px[8:0], py[8:0], 1'b1, c);
		idle; idle; idle; idle;
	end
endtask

integer i, k, best_k;
reg aligned;
integer px, py;
reg [15:0] A, B, exp_c;
integer bad;
integer phase_start, phase3_start;

initial begin
	n_s = 0;
	reset_dut;
	// ------------------------------------------------ 1. pass-through
	mode = 0;
	A = 16'h5AD3; B = 16'h1234;
	for (py = 0; py < YMAX; py = py + 1)
		for (px = 0; px < XMAX; px = px + 1)
			drive(px[8:0], py[8:0], 1'b1,
			      ((px + py) & 1) ? A : B);
	idle; idle; idle; idle; idle; idle;

	best_k = -1;
	for (k = 1; k <= 4; k = k + 1) begin
		aligned = 1;
		for (i = k; i < n_s; i = i + 1)
			if (out_de[i] !== in_de[i-k] ||
			    (in_de[i-k] && out_rgb[i] !== in_rgb[i-k]))
				aligned = 0;
		if (aligned && best_k < 0) best_k = k;
	end
	check("mode0 pass-through, rgb+de aligned at constant latency",
	      best_k > 0);
	$display("     (latency K = %0d clocks)", best_k);

	// ---------------------------------- 2. uniform frames, all modes
	for (k = 0; k <= 3; k = k + 1) begin
		mode = k[2:0];
		phase_start = n_s;
		frame_uniform(16'h4E31);   // r=19 g=9  b=17
		bad = 0;
		for (i = phase_start; i < n_s; i = i + 1)
			if (out_de[i] && out_rgb[i] !== 16'h4E31) bad = bad + 1;
		check(k == 0 ? "uniform frame, Off"   :
		      k == 1 ? "uniform frame, Soft"   :
		      k == 2 ? "uniform frame, Smooth" : "uniform frame, Sharp",
		      bad == 0);
	end

	// ----------------------------------- 3. step boundary, Smooth
	mode = 3'd2;
	phase3_start = n_s;
	A = 16'h0000;             // left : black
	B = 16'h7C1F;             // right : r=31 g=0  b=31
	for (py = 0; py < YMAX; py = py + 1)
		for (px = 0; px < XMAX; px = px + 1)
			drive(px[8:0], py[8:0], 1'b1, (px < 12) ? A : B);
	idle; idle; idle; idle; idle; idle;

	// expected Smooth value at interior column 12 (first B column),
	// row >= 2 so the vertical taps are real neighbours: (2A+2B)/4
	exp_c = {5'd15, 5'd0, 5'd15};   // (A+B)/2 per channel
	bad = 0;
	// recompute against recorded streams using the found latency
	for (i = best_k; i < n_s; i = i + 1) begin
		if (best_k >= 0 && in_de[i-best_k] && (i - best_k) >= phase3_start) begin
			px = (i - best_k) - phase3_start;  // phase-3 local drive order
			py = px / XMAX; px = px % XMAX;
			if (py >= 2 && px == 12 && out_rgb[i] !== exp_c) begin
				$display("  step: got %h want %h at (%0d,%0d)",
				         out_rgb[i], exp_c, px, py);
				bad = bad + 1;
			end
			if (py >= 2 && px == 11 && out_rgb[i] !== A) bad = bad + 1;
			if (py >= 2 && px == 13 && out_rgb[i] !== B) bad = bad + 1;
		end
	end
	check("Smooth 2x2 average at vertical step", bad == 0);

	if (errors == 0) $display("TB VIDEO_FILTER PASS");
	else             $display("TB VIDEO_FILTER FAIL (%0d errors)", errors);
	$finish;
end

// clear pipeline between phases
task reset_dut;
	integer j;
	begin
		for (j = 0; j < 8; j = j + 1) idle;
	end
endtask

endmodule
