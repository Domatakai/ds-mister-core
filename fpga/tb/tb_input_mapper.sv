//============================================================================
// NDS MiSTer Test — input mapper testbench
//
//   iverilog -g2012 -o /tmp/tb_in tb/tb_input_mapper.sv \
//            rtl/input/input_mapper.sv && vvp /tmp/tb_in
//
// Covers: KEYINPUT order/polarity, face + shoulder swaps, stylus
// cursor (d-pad and stick), tap button, microphone hold, stylus off, and
// the lid chord (which sets the hinge EXTKEYIN bit 7 reports).
//============================================================================
`timescale 1ns / 1ps

module tb_input_mapper;

reg clk = 0;
always #7.4599 clk = ~clk; // 67.0274 MHz: the core's own clock (the PLL)

reg reset = 1;
reg [31:0] joy0 = 0, joy1 = 0;
reg [15:0] stick0 = 0;
reg menu_active = 0;
reg [1:0] stylus_cursor = 0;
reg [1:0] tap_sel = 0;
reg face_swap = 0, shoulder_swap = 0;
reg [1:0] mic_source = 0;
reg [11:0] mic_adc = 12'h400;
reg [1:0] lid_sel = 0;
reg [24:0] mouse = 0;

wire [11:0] keys;
wire [8:0] touch_x;
wire [7:0] touch_y;
wire touch_down, hinge_closed;
wire [11:0] mic_lvl;

input_mapper dut (
	.clk(clk), .reset(reset),
	.joy0(joy0), .joy1(joy1), .stick0(stick0), .mouse(mouse),
	.menu_active(menu_active),
	.stylus_cursor(stylus_cursor), .tap_sel(tap_sel),
	.face_swap(face_swap), .shoulder_swap(shoulder_swap),
	.mic_source(mic_source), .mic_adc(mic_adc), .lid_sel(lid_sel),
	.keys(keys), .touch_x(touch_x), .touch_y(touch_y),
	.touch_down(touch_down), .mic_lvl(mic_lvl),
	.hinge_closed(hinge_closed)
);

integer errors = 0;
integer i;
task check; // `expect` is an SVA keyword under -g2012, so avoid it
	input [8*40:1] name;
	input cond;
	begin
		if (cond !== 1'b1) begin
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

	// --- while the boot menu has the screen the pad is swallowed whole
	menu_active = 1;
	joy0 = 32'h0000_0010; // A
	repeat (3) @(posedge clk);
	check("menu swallows the pad", keys === 12'hFFF);
	menu_active = 0;
	joy0 = 32'h0000_0000;
	repeat (3) @(posedge clk);

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
		repeat (300_000) @(posedge clk); // > 1 base step (4 ms = 268110 cycles)
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
		repeat (300_000) @(posedge clk); // > 1 base step
		check("stylus stick: cursor moves down", touch_y > y0);
		stick0 = 0;
	end

	// --- Pointer: relative mouse packets move the stylus, tip = button 0
	stylus_cursor = 2'd3;
	joy0 = 0;
	repeat (3) @(posedge clk);
	begin : pointer_step
		reg [8:0] x0;
		reg [7:0] y0, y_before;
		x0 = touch_x;
		y0 = touch_y;
		mouse = {1'b1, 8'd3, 8'd5, 8'd0};  // toggle, Y +3 (up), X +5
		repeat (3) @(posedge clk);
		check("pointer: X moves right", touch_x === x0 + 9'd5);
		check("pointer: Y moves up", touch_y === y0 - 8'd3);
		// a repeated packet without a toggle change is not a new move
		repeat (3) @(posedge clk);
		check("pointer: same toggle is not a packet", touch_x === x0 + 9'd5);
		// the left button is the pen tip
		mouse = {1'b0, 8'd0, 8'd0, 8'd1};
		repeat (3) @(posedge clk);
		check("pointer: left button presses", touch_down === 1'b1);
		mouse = {1'b1, 8'd0, 8'd0, 8'd0};
		repeat (3) @(posedge clk);
		check("pointer: release lifts the pen", touch_down === 1'b0);
		// the screen edge clamps instead of wrapping
		for (i = 0; i < 8; i = i + 1) begin
			mouse[24] = ~mouse[24];
			mouse[15:8] = 8'd127;
			repeat (2) @(posedge clk);
		end
		check("pointer: clamps at x=255", touch_x === 9'd255);
		// the boot menu owns the screen, so it owns the pointer
		y_before = touch_y;
		menu_active = 1;
		mouse[24] = ~mouse[24];
		mouse[15:8] = 8'd0;
		mouse[23:16] = 8'd127;   // straight down
		mouse[5] = 1'b1;
		repeat (3) @(posedge clk);
		check("pointer: the picker swallows the move", touch_y === y_before);
		menu_active = 0;
	end

	// --- and the pad modes ignore the pointing device
	stylus_cursor = 2'd1;
	begin : pointer_off_step
		reg [8:0] x0;
		x0 = touch_x;
		mouse[24] = ~mouse[24];
		mouse[15:8] = 8'd40;     // left, magnitude 40
		mouse[4] = 1'b1;
		repeat (3) @(posedge clk);
		check("d-pad mode: the mouse is ignored", touch_x === x0);
		check("d-pad mode: the mouse does not tap", touch_down === 1'b0);
	end
	stylus_cursor = 2'd0;
	mouse = 0;
	repeat (3) @(posedge clk);

	// --- microphone: Off / R3 button / board ADC
	mic_source = 2'd1;
	repeat (3) @(posedge clk);
	joy0 = 32'h0000_8000; // bit15 = R3
	repeat (3) @(posedge clk);
	check("mic R3 hold reads C00h", mic_lvl === 12'hC00);
	joy0 = 0;
	repeat (3) @(posedge clk);
	check("mic release reads 400h", mic_lvl === 12'h400);

	mic_source = 2'd2;
	mic_adc = 12'hF5A;
	repeat (3) @(posedge clk);
	check("host device follows the ADC", mic_lvl === 12'hF5A);
	joy0 = 32'h0000_8000;              // R3 must not matter in this mode
	repeat (3) @(posedge clk);
	check("and R3 does not override it", mic_lvl === 12'hF5A);
	joy0 = 0;

	mic_source = 2'd0;
	mic_adc = 12'hFFF;
	repeat (3) @(posedge clk);
	check("mic off holds the floor", mic_lvl === 12'h400);

	// --- lid chord: L2+R2 (bit12|bit13) closes the hinge while held
	lid_sel = 2'd1;
	joy0 = 32'h0000_3000;
	repeat (3) @(posedge clk);
	check("lid: L2+R2 closes the hinge", hinge_closed === 1'b1);
	joy0 = 32'h0000_1000;                 // L2 alone
	repeat (3) @(posedge clk);
	check("lid: one shoulder is not enough", hinge_closed === 1'b0);
	joy0 = 0;
	repeat (3) @(posedge clk);
	check("lid: opens again on release", hinge_closed === 1'b0);

	// --- the other chord, and Ignore leaving the shell alone
	lid_sel = 2'd2;
	joy0 = 32'h0000_C000;                 // L3+R3
	repeat (3) @(posedge clk);
	check("lid: L3+R3 closes the hinge", hinge_closed === 1'b1);
	lid_sel = 2'd0;
	repeat (3) @(posedge clk);
	check("lid: Ignore holds it open", hinge_closed === 1'b0);

	// --- the picker has the screen, so it has the lid too
	lid_sel = 2'd1;
	menu_active = 1;
	joy0 = 32'h0000_3000;
	repeat (3) @(posedge clk);
	check("lid: the picker swallows the chord", hinge_closed === 1'b0);
	menu_active = 0;
	lid_sel = 2'd0;
	joy0 = 0;
	repeat (3) @(posedge clk);

	if (errors == 0) $display("tb_input_mapper: PASS");
	else             $display("tb_input_mapper: FAIL (%0d errors)", errors);
	$finish;
end

endmodule
