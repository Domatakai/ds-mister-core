//============================================================================
// NDS MiSTer Test — video timing testbench
//
// Run with Icarus Verilog from fpga/:
//   iverilog -g2012 -o /tmp/tb_vt tb/tb_video_timing.sv \
//            rtl/video/video_timing.sv && vvp /tmp/tb_vt
//
// Checks that the 256x384 frame lands on the DS's native refresh rate
// and that active/blank counts match the parameters.
//============================================================================
`timescale 1ns / 1ps

module tb_video_timing;

localparam H_ACTIVE = 256, H_TOTAL = 320;
localparam V_ACTIVE = 384, V_TOTAL = 653;

reg clk = 0;
always #10 clk = ~clk; // 50 MHz

reg reset = 1;
wire pixel_ce;
wire [8:0] x, y;
wire de, hs, vs, frame_start;

video_timing dut (
	.clk(clk),
	.ce(1'b1),
	.pixel_ce(pixel_ce),
	.reset(reset),
	.x(x), .y(y),
	.de(de), .hs(hs), .vs(vs),
	.frame_start(frame_start)
);

reg measure = 0;
integer de_count = 0;
real    t0, t1, rate;

// count active pixels while measuring; de is registered so gate on CE
always @(posedge clk) begin
	if (measure && de && pixel_ce) de_count = de_count + 1;
end

initial begin
	repeat (20) @(posedge clk);
	reset = 0;

	// let one frame pass, then measure exactly one frame period
	@(posedge frame_start);
	@(posedge frame_start);
	de_count = 0;
	measure  = 1;
	t0 = $realtime;
	@(posedge frame_start);
	t1 = $realtime;
	measure  = 0;

	rate = 1.0e9 / (t1 - t0);
	$display("tb_video_timing: frame = %0.0f ns (%0d x %0d active pixels)",
		t1 - t0, H_ACTIVE, V_ACTIVE);
	$display("tb_video_timing: refresh = %0.4f Hz", rate);
	$display("tb_video_timing: active pixels/frame = %0d (expect %0d)",
		de_count, H_ACTIVE * V_ACTIVE);

	if (de_count != H_ACTIVE * V_ACTIVE)
		$display("tb_video_timing: FAIL — active pixel count wrong");
	else if (rate < 59.7 || rate > 60.0)
		$display("tb_video_timing: FAIL — refresh out of range");
	else
		$display("tb_video_timing: PASS");

	$finish;
end

initial begin
	#50_000_000;
	$display("tb_video_timing: FAIL — timeout");
	$finish;
end

endmodule
