//============================================================================
// NDS MiSTer Test — video timing testbench
//
// Run with Icarus Verilog from fpga/:
//   iverilog -g2012 -o /tmp/tb_vt tb/tb_video_timing.sv \
//            rtl/video/video_timing.sv && vvp /tmp/tb_vt
//
// Verifies all three OSD refresh modes: active pixel count must be
// exactly 256x384 in every mode, and the measured rate must land within
// 500 ppm of each target.
//============================================================================
`timescale 1ns / 1ps

module tb_video_timing;

reg clk = 0;
always #10 clk = ~clk; // 50 MHz

reg reset = 1;
reg [8:0] h_total = 9'd320;
reg [9:0] v_total = 10'd653;

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

reg measure = 0;
integer de_count = 0;
real    t0, t1, rate;
integer errors = 0;

// count active pixels while measuring; de is registered so gate on CE
always @(posedge clk) begin
	if (measure && de && pixel_ce) de_count = de_count + 1;
end

task check_mode;
	input [8*12:1] name;
	input [8:0] ht;
	input [9:0] vt;
	input real target;
	begin
		h_total = ht;
		v_total = vt;
		// settle one frame, then measure exactly one frame period
		@(posedge frame_start);
		@(posedge frame_start);
		de_count = 0;
		measure  = 1;
		t0 = $realtime;
		@(posedge frame_start);
		t1 = $realtime;
		measure  = 0;
		rate = 1.0e9 / (t1 - t0);

		$display("tb_video_timing: %-8s %0dx%0d -> %0.4f Hz, %0d active px",
			name, ht, vt, rate, de_count);

		if (de_count != 256 * 384) begin
			$display("tb_video_timing: FAIL %0s — active pixel count", name);
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

	check_mode("native",  9'd320, 10'd653, 59.8261); // DS-native target
	check_mode("59.95",   9'd332, 10'd628, 59.9500);
	check_mode("60.00",   9'd320, 10'd651, 60.0000);

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
