//============================================================================
// NDS MiSTer Test — input mapper testbench
//
//   iverilog -g2012 -o /tmp/tb_in tb/tb_input_mapper.sv \
//            rtl/input/input_mapper.sv && vvp /tmp/tb_in
//
// Covers: KEYINPUT order/polarity, face + shoulder swaps, stylus
// cursor (d-pad and stick), tap button, microphone hold, stylus off.
//============================================================================
`timescale 1ns / 1ps

module tb_input_mapper;

reg clk = 0;
always #10 clk = ~clk; // 50 MHz

reg reset = 1;
reg [31:0] joy0 = 0, joy1 = 0;
reg [15:0] stick0 = 0;
reg [1:0] stylus_cursor = 0;
reg [1:0] tap_sel = 0;
reg face_swap = 0, shoulder_swap = 0;
reg [1:0] mic_source = 0;

wire [11:0] keys;
wire [8:0] touch_x;
wire [7:0] touch_y;
wire touch_down, mic_pressed;

input_mapper dut (
	.clk(clk), .reset(reset),
	.joy0(joy0), .joy1(joy1), .stick0(stick0),
	.stylus_cursor(stylus_cursor), .tap_sel(tap_sel),
	.face_swap(face_swap), .shoulder_swap(shoulder_swap),
	.mic_source(mic_source),
	.keys(keys), .touch_x(touch_x), .touch_y(touch_y),
	.touch_down(touch_down), .mic_pressed(mic_pressed)
);

integer errors = 0;
task check; // `expect` is an SVA keyword under -g2012, so avoid it
	input [8*40:1] name;
	input cond;
	begin
		if (!cond) begin
			$display("FAIL %0s", name);
			errors = errors + 1;
		end else begin
			$display("ok   %0s", name);
		end
	end
endtask

initial begin
	repeat (5) @(posedge clk);
	reset = 0;
	@(posedge clk);

	// --- KEYINPUT: A pressed -> bit0 low, rest high (active low)
	joy0 = 32'h0000_0010; // bit4 = A
	repeat (3) @(posedge clk);
	check("KEYINPUT A -> bit0 low", keys[0] === 1'b0 && keys[11:1] === 11'h7FF);

	// --- Start/Select pressed -> bits 3/2 low
	joy0 = 32'h0000_0800; // bit11 = Start
	repeat (3) @(posedge clk);
	check("KEYINPUT Start -> bit3 low", keys[3] === 1'b0 && keys[0] === 1'b1);

	// --- face swap: bit4 -> DS B instead of A
	face_swap = 1;
	joy0 = 32'h0000_0010; // back to A
	repeat (3) @(posedge clk);
	check("face swap: joy A -> DS B", keys[1] === 1'b0 && keys[0] === 1'b1);
	face_swap = 0;

	// --- shoulder swap: bit8 (L) -> DS R (key bit8)
	shoulder_swap = 1;
	joy0 = 32'h0000_0100; // bit8 = L
	repeat (3) @(posedge clk);
	check("shoulder swap: joy L -> DS R", keys[8] === 1'b0 && keys[9] === 1'b1);
	shoulder_swap = 0;

	// --- stylus Off: dpad reaches KEYINPUT
	joy0 = 32'h0000_0004; // bit2 = Down
	repeat (3) @(posedge clk);
	check("stylus off: dpad Down -> key bit6", keys[6] === 1'b0);

	// --- stylus D-pad: dpad drives cursor, keys released, tap presses
	stylus_cursor = 2'd1;
	joy0 = 0;
	repeat (3) @(posedge clk);
	check("stylus d-pad: keys released", keys === 12'hFFF);
	begin : cursor_step
		reg [8:0] x0;
		x0 = touch_x;
		joy0 = 32'h0000_0001; // Right held
		repeat (250_000) @(posedge clk); // > 1 base step (4 ms)
		check("stylus d-pad: cursor moves right", touch_x > x0);
		joy0 = 32'h0000_1000; // tap = L2
		repeat (3) @(posedge clk);
		check("stylus tap L2 -> touch_down", touch_down === 1'b1);
		joy0 = 0;
		repeat (3) @(posedge clk);
		check("tap release", touch_down === 1'b0);
	end

	// --- stylus Left stick
	stylus_cursor = 2'd2;
	repeat (3) @(posedge clk);
	begin : stick_step
		reg [7:0] y0;
		y0 = touch_y;
		stick0 = {8'd100, 8'd0}; // Y down (positive)
		repeat (250_000) @(posedge clk);
		check("stylus stick: cursor moves down", touch_y > y0);
		stick0 = 0;
	end

	// --- microphone via R3
	mic_source = 2'd1;
	repeat (3) @(posedge clk);
	joy0 = 32'h0000_8000; // bit15 = R3
	repeat (3) @(posedge clk);
	check("mic R3 hold", mic_pressed === 1'b1);
	joy0 = 0;
	repeat (3) @(posedge clk);
	check("mic release", mic_pressed === 1'b0);

	if (errors == 0) $display("tb_input_mapper: PASS");
	else             $display("tb_input_mapper: FAIL (%0d errors)", errors);
	$finish;
end

endmodule
