//============================================================================
// NDS MiSTer Test — input recorder and replayer
//
//   iverilog -g2012 -o /tmp/tb_replay tb/tb_input_replay.sv \
//            rtl/input/input_replay.sv
//   vvp /tmp/tb_replay
//
// The module carries the whole input image in one word per frame. This bench
// drives the frame pulse by hand, records words with all 48 bits in use,
// and checks:
//
//   * with mode Off the output is the live input (a one-cycle pipe)
//   * Record stores one word per frame, counts them, and does not advance
//     on a frame pulse that arrives with no new frame
//   * Play returns exactly the recorded words, first one first, one per
//     frame, and then hands the live input back
//   * a full log stops recording at its depth and replays completely
//   * the log survives the core reset: recording, asserting reset, and
//     playing still replays what was recorded (that is how a run from boot
//     is reproduced)
//   * selecting Record again starts a new log at index 0
//============================================================================
`timescale 1ns / 1ps

module tb_input_replay;

reg clk = 0;
always #10 clk = ~clk;

reg        reset = 1;
reg        frame = 0;
reg  [1:0] mode  = 0;
reg [47:0] live  = 0;

wire [47:0] out;
wire        recording, playing;
wire [15:0] count, pos;

integer checks = 0;
integer errors = 0;

input_replay #(.DEPTH(8)) dut (
	.clk(clk), .reset(reset), .frame(frame), .mode(mode),
	.live(live), .out(out),
	.recording(recording), .playing(playing),
	.count(count), .pos(pos)
);

task tick;
	begin
		@(posedge clk);
		#1;
	end
endtask

// one frame: the word is presented at the edge the pulse is high
task do_frame(input [47:0] word);
	begin
		live  = word;
		frame = 1'b1;
		tick;
		frame = 1'b0;
		tick;
	end
endtask

// a mode change takes effect on the next edge, and play primes its read
// one cycle later; two ticks cover both
task set_mode(input [1:0] m);
	begin
		mode = m;
		tick;
		tick;
	end
endtask

task check_out(input [47:0] want, input [8*44-1:0] what);
	begin
		checks = checks + 1;
		if (out !== want) begin
			errors = errors + 1;
			$display("  FAIL %0s: out = %h, expected %h",
			         what, out, want);
		end
	end
endtask

task check_val(input [31:0] got, input [31:0] want, input [8*44-1:0] what);
	begin
		checks = checks + 1;
		if (got !== want) begin
			errors = errors + 1;
			$display("  FAIL %0s: %0d, expected %0d", what, got, want);
		end
	end
endtask

// the words this bench records; the top five bits are set on one of them so
// a truncated store shows up, even though the core leaves those bits zero
reg [47:0] w0, w1, w2, w3, w4;

integer i;
initial begin
	w0 = 48'h0000_0000_0001;
	w1 = 48'h0000_0000_0002;
	w2 = 48'hF000_0000_0003;
	w3 = 48'h0000_0123_4567;
	w4 = 48'h0000_0FED_CBA9;

	reset = 1;
	repeat (3) tick;
	reset = 0;
	tick;

	// ---- Off is a wire ----
	live = 48'h0000_0000_00A5;
	tick;
	check_out(48'h0000_0000_00A5, "Off passes the live input");
	check_val(recording, 0, "not recording when Off");
	check_val(playing,   0, "not playing when Off");

	// ---- record five frames ----
	set_mode(1);
	check_val(recording, 1, "Record starts");
	do_frame(w0);
	do_frame(w1);
	do_frame(w2);
	do_frame(w3);
	do_frame(w4);
	check_val(count, 5, "five frames recorded");
	check_out(w4, "recording still passes the live input");

	// ---- Off, then play it back ----
	set_mode(0);
	check_val(recording, 0, "Record stops when the row is Off");
	check_out(w4, "Off returns to the live input");

	set_mode(2);
	check_val(playing, 1, "Play starts");
	do_frame(48'h0);
	check_out(w0, "first replayed frame is the first recorded one");
	check_val(pos, 1, "one frame replayed");
	do_frame(48'h0);
	check_out(w1, "second replayed frame");
	do_frame(48'h0);
	check_out(w2, "the high bits survived the log");
	do_frame(48'h0);
	check_out(w3, "fourth replayed frame");
	do_frame(48'h0);
	check_val(pos, 5, "five frames replayed");
	check_val(playing, 0, "play stops at the end of the log");
	check_out(48'h0, "the live input comes back");

	// ---- the log survives a core reset ----
	reset = 1;
	repeat (2) tick;
	reset = 0;
	tick;
	check_val(count, 5, "the log length survives the core reset");
	set_mode(2);
	do_frame(48'h0);
	check_out(w0, "a replay can start again after the reset");
	do_frame(48'h0);
	check_out(w1, "and continues in order");
	set_mode(0);

	// ---- a full log ----
	set_mode(1);
	for (i = 0; i < 8; i = i + 1)
		do_frame(48'h0000_0000_0100 + i);
	check_val(count, 8, "a full log holds its depth");
	check_val(recording, 0, "recording stops when the log is full");
	// the last frame pulse after the full one must not write past the end
	frame = 1'b1;
	tick;
	frame = 1'b0;
	tick;
	check_val(count, 8, "no write past the end");

	set_mode(0);
	set_mode(2);
	do_frame(48'h0);
	check_out(48'h0000_0000_0100, "a full log replays from its first word");
	for (i = 1; i < 8; i = i + 1)
		do_frame(48'h0);
	check_val(pos, 8, "every frame of the full log replayed");
	check_val(playing, 0, "the full log's replay ends");

	// ---- Record again clears the log ----
	set_mode(0);
	set_mode(1);
	check_val(count, 0, "Record clears the previous log");
	do_frame(w3);
	do_frame(w4);
	check_val(count, 2, "the new log counts only its own frames");
	set_mode(0);
	set_mode(2);
	do_frame(48'h0);
	check_out(w3, "the new log replays from its first word");
	// the last frame is the one where playing drops, so sample it at its
	// own edge before the live input takes the output back
	live  = 48'h0;
	frame = 1'b1;
	tick;
	frame = 1'b0;
	check_out(w4, "and its second");
	tick;

	$display("  %0d checks", checks);
	if (errors == 0) $display("TB INPUT REPLAY PASS");
	else             $display("TB INPUT REPLAY FAIL: %0d error(s)", errors);
	$finish;
end

endmodule
