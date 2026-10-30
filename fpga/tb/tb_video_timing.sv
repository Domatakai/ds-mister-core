//============================================================================
// NDS MiSTer Test — video timing testbench
//
// Run with Icarus Verilog from fpga/:
//   iverilog -g2012 -o /tmp/tb_vt tb/tb_video_timing.sv \
//            rtl/video/video_timing.sv && vvp /tmp/tb_vt
//
// Verifies all three OSD refresh modes: active pixel count must be
// exactly 256x384 in every mode, the frame must be exactly h_total*v_total
// pixel periods long, and the rate that falls out of it must land within
// 500 ppm of each target. The clock is the core's real one — the DS's
// 67.0274 MHz — because the pixel CE is clk/5 now, not the old 50/4.
//
// The frame length is *counted in clocks*, not timed with $realtime: Icarus
// rounds a real delay to its time precision, so a 7.4599275 ns half period
// comes out a few tens of ppm fast and every printed rate would inherit
// that error. Counting is exact, and the counted length is what the rate is
// then worked out from against the nominal clock.
//============================================================================
`timescale 1ns / 1ps

module tb_video_timing;

localparam real F_CLK = 67.0274e6; // the PLL's output, and clk_sys

reg clk = 0;
always #7.45992 clk = ~clk; // 67.0274 MHz (the PLL's output)

reg reset = 1;
reg [8:0] h_total = 9'd330;
reg [9:0] v_total = 10'd679;

wire pixel_ce;
wire [8:0] x, y;
wire de, hs, vs, frame_start;

video_timing dut (
	.clk(clk),
	.ce(1'b1),
	.pixel_ce(pixel_ce),
	.reset(reset),
	.h_total(h_total),
	.v_total(v_total),
	.x(x), .y(y),
	.de(de), .hs(hs), .vs(vs),
	.frame_start(frame_start)
);

integer de_frame = 0;     // active pixels so far in this frame
integer de_count = 0;     // ...and the completed frame's total
integer fclk     = 0;     // clocks so far in this frame
integer frame_clocks = 0; // ...and the completed frame's length
real    rate;
integer errors = 0;

// One frame is h_total*v_total pixel periods, 5 clocks each. Capturing both
// counters at frame_start keeps the two measurements in the same window, and
// doing it all in one edge keeps the split between frames unambiguous.
always @(posedge clk) begin
	fclk <= fclk + 1;
	if (pixel_ce) begin
		if (de) de_frame <= de_frame + 1;
		if (frame_start) begin
			de_count     <= de_frame;
			frame_clocks <= fclk + 1; // this edge is the frame's first clock
			de_frame     <= 0;
			fclk         <= 0;
		end
	end
end

task check_mode;
	input [8*12:1] name;
	input [8:0] ht;
	input [9:0] vt;
	input real target;
	begin
		h_total = ht;
		v_total = vt;
		// settle one frame, then read the one after it
		@(posedge frame_start);
		@(posedge frame_start);
		@(posedge frame_start);
		rate = F_CLK / frame_clocks;

		$display("tb_video_timing: %-8s %0dx%0d -> %0.4f Hz, %0d active px, %0d clocks",
			name, ht, vt, rate, de_count, frame_clocks);

		if (de_count != 256 * 384) begin
			$display("tb_video_timing: FAIL %0s — active pixel count", name);
			errors = errors + 1;
		end else if (frame_clocks != 5 * ht * vt) begin
			$display("tb_video_timing: FAIL %0s — frame is %0d clocks, expected %0d",
				name, frame_clocks, 5 * ht * vt);
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

	check_mode("native",  9'd330, 10'd679, 59.8261); // DS-native target
	check_mode("59.95",   9'd344, 10'd650, 59.9500);
	check_mode("60.00",   9'd331, 10'd675, 60.0000);

	if (errors == 0) $display("tb_video_timing: PASS");
	else             $display("tb_video_timing: FAIL (%0d errors)", errors);
	$finish;
end

initial begin
	#200_000_000;
	$display("tb_video_timing: FAIL — timeout");
	$finish;
end

endmodule
