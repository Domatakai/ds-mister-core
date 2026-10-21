//============================================================================
// NDS MiSTer Test — input mapper
//
// Turns the MiSTer virtual gamepad into Nintendo DS controls:
//
//   MiSTer pad (from "Define joystick buttons" order):
//     0 Right  1 Left  2 Down  3 Up   4 A    5 B    6 X    7 Y
//     8 L     9 R    10 Select 11 Start  12 L2  13 R2  14 L3  15 R3
//     (constants below — one-line change if a pad exposes another order;
//      the OSD Face/Shoulder swaps cover the common variants)
//
//   DS KEYINPUT (0x04000130, GBATEK — 0=Pressed, 1=Released):
//     0 A  1 B  2 Select  3 Start  4 Right 5 Left
//     6 Down 7 Up  8 R  9 L  10 X  11 Y
//
//   Stylus (bottom screen, 256x192):
//     OSD "Stylus cursor": Off / D-pad / Left stick
//     OSD "Stylus tap":    L2 / R2 / L3 / R3  (any extra button)
//     Cursor accelerates while held; tap presses the "screen".
//     OSD "Microphone": Off / Button (hold R3) / Host device (M5)
//
// Keyboard users are covered by the framework — map the keyboard as a
// joystick in the MiSTer menu core and it arrives here as joy0.
//
// Player 2 joins in M5 with local DS-to-DS wireless play.
//============================================================================
module input_mapper (
	input            clk,
	input            reset,

	input     [31:0] joy0,
	input     [31:0] joy1,
	input     [15:0] stick0,   // hps_io joystick_l_analog_0: {Y[15:8], X[7:0]} signed

	// OSD configuration
	input      [1:0] stylus_cursor, // 0 off, 1 d-pad, 2 left stick
	input      [1:0] tap_sel,       // 0 L2, 1 R2, 2 L3, 3 R3
	input            face_swap,     // A<->B, X<->Y
	input            shoulder_swap, // L<->R
	input      [1:0] mic_source,    // 0 off, 1 button (R3), 2 host device (M5)

	// toward main_bus (KEYINPUT/TSC servicing lands with the CPUs in M1)
	output reg [11:0] keys,        // KEYINPUT image, active low
	output reg  [8:0] touch_x,     // 0..255
	output reg  [7:0] touch_y,     // 0..191
	output reg        touch_down,
	output reg        mic_pressed
);

//------------------------------------------------------------------
// MiSTer virtual gamepad bit positions
//------------------------------------------------------------------
localparam JR = 0, JL = 1, JD = 2, JU = 3;
localparam JA = 4, JB = 5, JX = 6, JY = 7;
localparam JLS = 8, JRS = 9, JSEL = 10, JST = 11;
localparam JL2 = 12, JR2 = 13, JL3 = 14, JR3 = 15;

wire btn_a = face_swap   ? joy0[JB] : joy0[JA];
wire btn_b = face_swap   ? joy0[JA] : joy0[JB];
wire btn_x = face_swap   ? joy0[JY] : joy0[JX];
wire btn_y = face_swap   ? joy0[JX] : joy0[JY];
wire btn_l = shoulder_swap ? joy0[JRS] : joy0[JLS];
wire btn_r = shoulder_swap ? joy0[JLS] : joy0[JRS];

wire joy_up = joy0[JU], joy_down = joy0[JD];
wire joy_left = joy0[JL], joy_right = joy0[JR];

wire dpad_live = (stylus_cursor != 2'd1); // d-pad mode gives dpad to the stylus

wire tap =
	(tap_sel == 2'd0) ? joy0[JL2] :
	(tap_sel == 2'd1) ? joy0[JR2] :
	(tap_sel == 2'd2) ? joy0[JL3] : joy0[JR3];

wire [11:0] pressed; // active high
assign pressed[0]  = btn_a;
assign pressed[1]  = btn_b;
assign pressed[2]  = joy0[JSEL];
assign pressed[3]  = joy0[JST];
assign pressed[4]  = dpad_live ? joy_right : 1'b0;
assign pressed[5]  = dpad_live ? joy_left  : 1'b0;
assign pressed[6]  = dpad_live ? joy_down  : 1'b0;
assign pressed[7]  = dpad_live ? joy_up    : 1'b0;
assign pressed[8]  = btn_r;
assign pressed[9]  = btn_l;
assign pressed[10] = btn_x;
assign pressed[11] = btn_y;

//------------------------------------------------------------------
// Stylus cursor: step timing with hold acceleration
//   base 4 ms/step (250 px/s), after ~1 s held: 1 ms/step (1000 px/s)
//------------------------------------------------------------------
localparam STEP_BASE = 24'd200_000; // cycles per step @50 MHz
localparam STEP_FAST = 24'd50_000;
localparam ACCEL_AFTER = 24'd1_000_000 * 50 / 10; // ~1 s hold

wire stick_right = $signed(stick0[7:0])   >  $signed(8'd40);
wire stick_left  = $signed(stick0[7:0])   < -$signed(8'd40);
wire stick_down  = $signed(stick0[15:8])  >  $signed(8'd40);
wire stick_up    = $signed(stick0[15:8])  < -$signed(8'd40);

wire use_stick = (stylus_cursor == 2'd2);
wire cur_r = use_stick ? stick_right : (stylus_cursor == 2'd1) ? joy_right : 1'b0;
wire cur_l = use_stick ? stick_left  : (stylus_cursor == 2'd1) ? joy_left  : 1'b0;
wire cur_d = use_stick ? stick_down  : (stylus_cursor == 2'd1) ? joy_down  : 1'b0;
wire cur_u = use_stick ? stick_up    : (stylus_cursor == 2'd1) ? joy_up    : 1'b0;

wire any_dir = cur_r | cur_l | cur_d | cur_u;

reg [23:0] hold_cnt = 0;
reg [23:0] step_cnt = 0;
wire [23:0] step_period = (hold_cnt > ACCEL_AFTER) ? STEP_FAST : STEP_BASE;

always @(posedge clk) begin
	if (reset) begin
		hold_cnt <= 0;
		step_cnt <= 0;
		touch_x  <= 9'd128;
		touch_y  <= 8'd96;
	end else if (any_dir) begin
		hold_cnt <= (hold_cnt == 24'hFFFFFF) ? hold_cnt : hold_cnt + 1'd1;
		if (step_cnt >= step_period - 1'd1) begin
			step_cnt <= 0;
			if (cur_r && touch_x < 9'd255) touch_x <= touch_x + 1'd1;
			if (cur_l && touch_x > 9'd0)   touch_x <= touch_x - 1'd1;
			if (cur_d && touch_y < 8'd191) touch_y <= touch_y + 1'd1;
			if (cur_u && touch_y > 8'd0)   touch_y <= touch_y - 1'd1;
		end else begin
			step_cnt <= step_cnt + 1'd1;
		end
	end else begin
		hold_cnt <= 0;
		step_cnt <= 0;
	end
end

//------------------------------------------------------------------
// KEYINPUT (active low) + touch + mic
//------------------------------------------------------------------
always @(posedge clk) begin
	if (reset) begin
		keys        <= 12'hFFF;
		touch_down  <= 1'b0;
		mic_pressed <= 1'b0;
	end else begin
		keys <= ~pressed;
		touch_down <= stylus_cursor != 2'd0 && tap;
		mic_pressed <= (mic_source == 2'd1) && joy0[JR3];
	end
end

initial begin
	touch_x = 9'd128;
	touch_y = 8'd96;
end

wire _unused = &{1'b0, joy1, 1'b0};

endmodule
