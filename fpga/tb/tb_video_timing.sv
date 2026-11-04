//============================================================================
// NDS MiSTer Test — video timing testbench
//
// Run with Icarus Verilog from fpga/:
//   iverilog -g2012 -o /tmp/tb_vt tb/tb_video_timing.sv \
//            rtl/video/video_timing.sv && vvp /tmp/tb_vt
//
// Verifies every output mode: the active pixel count must be exactly the
// window the mode promises, the frame must be exactly N*h_total*v_total pixel
// periods long for that mode's CE divider N, the hsync run and the number of
// vsync lines must be the widths the mode's standard asks for, and the rate
// that falls out of it must land within 500 ppm of the target. The clock is
// the core's real one — the DS's 67.0274 MHz — because every pixel CE is a
// divider of it.
//
// The frame length is *counted in clocks*, not timed with $realtime: Icarus
// rounds a real delay to its time precision, so the 7.4599275 ns half period
// comes out a few tens of ppm fast and every printed rate would inherit that
// error. Counting is exact. The sync widths are measured the same way, from
// the pixel enables: one contiguous hsync run, and vsync's lines counted as
// (vsync pixel enables / h_total).
//============================================================================
`timescale 1ns / 1ps

module tb_video_timing;

localparam real F_CLK = 67.0274e6; // the PLL's output, and clk_sys

reg clk = 0;
always #7.45992 clk = ~clk; // 67.0274 MHz (the PLL's output)

reg reset = 1;
reg [1:0] vmode = 0;
reg [9:0] h_total = 10'd330;
reg [9:0] v_total = 10'd679;

wire pixel_ce;
wire [8:0] x, y;
wire de, hs, vs, frame_start;

video_timing dut (
	.clk(clk),
	.ce(1'b1),
	.pixel_ce(pixel_ce),
	.reset(reset),
	.vmode(vmode),
	.h_total(h_total),
	.v_total(v_total),
	.x(x), .y(y),
	.de(de), .hs(hs), .vs(vs),
	.frame_start(frame_start)
);

integer de_frame = 0;
integer de_count = 0;
integer fclk     = 0;
integer frame_clocks = 0;
integer hs_run = 0;
integer hs_max = 0;
integer vs_clks = 0;
integer hs_w    = 0;   // measured hsync width, pixel periods
integer vs_h    = 0;   // measured vsync height, lines
real    rate;
integer errors = 0;

always @(posedge clk) begin
	fclk <= fclk + 1;
	if (pixel_ce) begin
		if (de) de_frame <= de_frame + 1;
		// hsync is one contiguous run per line, so the longest run in the
		// frame is the sync width
		if (hs) begin
			hs_run <= hs_run + 1;
			if (hs_run + 1 > hs_max) hs_max <= hs_run + 1;
		end else begin
			hs_run <= 0;
		end
		if (vs) vs_clks <= vs_clks + 1;
		if (frame_start) begin
			de_count     <= de_frame;
			frame_clocks <= fclk + 1;
			hs_w         <= hs_max;
			vs_h         <= vs_clks / h_total;
			de_frame     <= 0;
			fclk         <= 0;
			hs_max       <= 0;
			hs_run       <= 0;
			vs_clks      <= 0;
		end
	end
end

task check_mode;
	input [8*12:1] name;
	input [1:0] vm;
	input [9:0] ht;
	input [9:0] vt;
	input integer div;
	input integer active;
	input integer hsync_w;
	input integer vsync_w;
	input real target;
	begin
		vmode   = vm;
		h_total = ht;
		v_total = vt;
		@(posedge frame_start);
		@(posedge frame_start);
		@(posedge frame_start);
		rate = F_CLK / frame_clocks;

		$display("tb_video_timing: %-10s mode %0d %0dx%0d /%0d -> %0.4f Hz, %0d active px, hsync %0d, vsync %0d lines",
			name, vm, ht, vt, div, rate, de_count, hs_w, vs_h);

		if (de_count != active) begin
			$display("tb_video_timing: FAIL %0s — active pixel count %0d, expected %0d",
				name, de_count, active);
			errors = errors + 1;
		end else if (frame_clocks != div * ht * vt) begin
			$display("tb_video_timing: FAIL %0s — frame is %0d clocks, expected %0d",
				name, frame_clocks, div * ht * vt);
			errors = errors + 1;
		end else if (hs_w != hsync_w) begin
			$display("tb_video_timing: FAIL %0s — hsync is %0d pixel periods, expected %0d",
				name, hs_w, hsync_w);
			errors = errors + 1;
		end else if (vs_h != vsync_w) begin
			$display("tb_video_timing: FAIL %0s — vsync is %0d lines, expected %0d",
				name, vs_h, vsync_w);
			errors = errors + 1;
		end else if ((rate - target > 0.05) || (target - rate > 0.05)) begin
			$display("tb_video_timing: FAIL %0s — rate %0.4f, expected %0.4f",
				name, rate, target);
			errors = errors + 1;
		end
	end
endtask

initial begin
	repeat (20) @(posedge clk);
	reset = 0;

	check_mode("native",    2'd0, 10'd330, 10'd679,  5, 256*384, 32, 4, 59.8261);
	check_mode("59.95",     2'd0, 10'd344, 10'd650,  5, 256*384, 32, 4, 59.9500);
	check_mode("60.00",     2'd0, 10'd331, 10'd675,  5, 256*384, 32, 4, 60.0000);
	check_mode("crt-side",  2'd1, 10'd710, 10'd263,  6, 512*240, 52, 3, 59.8261);
	check_mode("crt-single",2'd2, 10'd426, 10'd263, 10, 256*240, 32, 3, 59.8261);
	check_mode("crt-31k",   2'd3, 10'd426, 10'd526,  5, 256*384, 48, 3, 59.8261);

	if (errors == 0) $display("tb_video_timing: PASS");
	else             $display("tb_video_timing: FAIL (%0d errors)", errors);
	$finish;
end

initial begin
	#400_000_000;
	$display("tb_video_timing: FAIL — timeout");
	$finish;
end

endmodule
