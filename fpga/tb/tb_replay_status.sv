//============================================================================
// NDS MiSTer Test — replay status strip testbench
//
//   iverilog -g2012 -o /tmp/tb_replay_status tb/tb_replay_status.sv \
//            rtl/video/replay_status.sv rtl/video/font5x7.sv
//   vvp /tmp/tb_replay_status
//
// The pixel path is combinational apart from one output register, so probes
// address pixels directly at glyph row 0 (y = 376). Expected ink comes from
// the glyph shapes and the layout, not from the RTL: 'R' is 11110 on its top
// row, '0' is 01110, 'M' is 10001, '/' is 00001, and the text starts at
// column 9 (x = 72) inside a bar that runs from column 8 to 23.
//
// Column map: label 9..13, digits 14..17, and for Play a slash at 18 with
// the log's length in 19..22; column 23 is the bar's last cell.
//
// Checks:
//   1. With the row Off the picture passes through, bar included.
//   2. Record draws its label and the stored-frame count as four digits;
//      a full log says FULL instead, from the same counters.
//   3. Play draws label, position, a slash and the log's length.
//   4. An ended log says END, and Play with nothing recorded says EMPTY and
//      no numbers.
//   5. The bar stops at its own columns: a pixel just outside it passes
//      through.
//============================================================================
`timescale 1ns / 1ps

module tb_replay_status;

reg clk = 0;
always #10 clk = ~clk;

reg         reset = 1;
reg  [1:0]  mode = 2'd0;
reg         recording = 0, playing = 0;
reg  [15:0] count = 16'd0, frames_bcd = 16'd0, pos_bcd = 16'd0;

reg  [8:0]  x = 0, y = 0;
reg         de = 0, hs = 0, vs = 0;
reg  [15:0] rgb_in = 0;
wire [15:0] rgb_o;
wire        de_o, hs_o, vs_o;

replay_status dut (
	.clk(clk), .ce(1'b1), .reset(reset),
	.mode(mode), .recording(recording), .playing(playing),
	.count(count), .frames_bcd(frames_bcd), .pos_bcd(pos_bcd),
	.x(x), .y(y), .de(de), .hs(hs), .vs(vs), .rgb_in(rgb_in),
	.rgb_o(rgb_o), .de_o(de_o), .hs_o(hs_o), .vs_o(vs_o)
);

localparam [15:0] W = 16'h7FFF;
localparam [15:0] B = 16'h0000;

integer errors = 0;
task check;
	input [8*52:1] name;
	input          cond;
	begin
		if (cond !== 1'b1) begin
			$display("FAIL %0s", name);
			errors = errors + 1;
		end else
			$display("ok   %0s", name);
	end
endtask

// one pixel through the pipeline at glyph row 0 of the strip's row (y = 376)
task probe;
	input [8:0]    px;
	input [15:0]   exp;
	input [8*52:1] name;
	begin
		@(negedge clk);
		x = px; y = 9'd376; de = 1; hs = 1; vs = 1;
		rgb_in = 16'h0100 + px;
		@(posedge clk);
		@(negedge clk);
		if (rgb_o !== exp || de_o !== 1'b1) begin
			$display("FAIL %0s: got %04x want %04x at x=%0d",
			         name, rgb_o, exp, px);
			errors = errors + 1;
		end else begin
			$display("ok   %0s", name);
		end
	end
endtask

initial begin
	repeat (4) @(posedge clk);
	reset = 0;
	repeat (4) @(posedge clk);

	// ------------------------------------------- 1. Off is a wire
	probe(9'd72, 16'h0148, "Off: the bar area passes through");
	probe(9'd120, 16'h0178, "Off: a digit cell passes through");
	check("Off keeps DE", de_o === 1'b1);

	// ------------------------------------------- 2. Record
	mode = 2'd1; recording = 1; frames_bcd = 16'h0012;
	repeat (2) @(posedge clk);
	probe(9'd64, B, "Record: the bar starts black at column 8");
	probe(9'd72, W, "Record: R inks its top-left");       // R = 11110
	probe(9'd75, W, "Record: R's top row reaches gx 3");
	probe(9'd80, W, "Record: E fills its top row");       // E = 11111
	probe(9'd88, B, "Record: C is bare at its top-left"); // C = 01110
	probe(9'd89, W, "Record: C inks its second pixel");
	probe(9'd96, B, "Record: the label's fifth cell is a space");
	probe(9'd104, B, "Record: the cell before the digits is blank");
	// "0012" starts at column 14 (x = 112)
	probe(9'd112, B, "Record: 0 is bare at its top-left");
	probe(9'd113, W, "Record: the 0 inks its top row");
	probe(9'd116, B, "Record: the 0 is hollow at gx 4");
	probe(9'd121, W, "Record: the second digit is another 0");
	probe(9'd130, W, "Record: the third digit is a 1 stem"); // 1 = 00100
	probe(9'd136, B, "Record: the 2 is bare at its top-left");
	probe(9'd137, W, "Record: the 2 inks its top row");
	probe(9'd184, B, "Record: the bar's padding cell is empty");
	probe(9'd191, B, "Record: the bar ends at column 23");
	probe(9'd192, 16'h01C0, "Record: column 24 passes through");

	recording = 0; frames_bcd = 16'h8192;
	repeat (2) @(posedge clk);
	probe(9'd72, W, "FULL: F inks its top-left");        // F = 11111
	probe(9'd76, W, "FULL: F fills its fifth pixel");
	probe(9'd80, W, "FULL: U inks its top-left");        // U = 10001
	probe(9'd81, B, "FULL: U is hollow beside it");
	probe(9'd88, W, "FULL: L inks its top-left");        // L = 10000
	probe(9'd92, B, "FULL: L is bare at gx 4");
	probe(9'd96, W, "FULL: the second L inks its top-left");
	probe(9'd112, B, "FULL: 8 is bare at its top-left"); // 8 = 01110
	probe(9'd113, W, "FULL: 8 inks its top row");
	probe(9'd122, W, "FULL: the 1 is a stem at gx 2");
	probe(9'd128, B, "FULL: the 9 is bare at its top-left"); // 9 = 01110
	probe(9'd129, W, "FULL: the 9 inks its top row");
	probe(9'd176, B, "FULL: the last digit cell is used by the 2");

	// ------------------------------------------- 3. Play
	mode = 2'd2; playing = 1;
	count = 16'h8192; pos_bcd = 16'h0123; frames_bcd = 16'h8192;
	repeat (2) @(posedge clk);
	probe(9'd72, W, "Play: P inks its top-left");        // P = 11110
	probe(9'd75, W, "Play: P's top row reaches gx 3");
	probe(9'd80, W, "Play: L inks its top-left");        // L = 10000
	probe(9'd84, B, "Play: L is bare at gx 4");
	probe(9'd88, B, "Play: A is bare at its top-left");  // A = 01110
	probe(9'd89, W, "Play: A inks its second pixel");
	probe(9'd96, W, "Play: Y inks its left stroke");     // Y = 10001
	probe(9'd97, B, "Play: Y is hollow beside it");
	// position "0123" at columns 14..17; the 3 is 11111 across the top
	probe(9'd112, B, "Play: the position starts with a 0");
	probe(9'd136, W, "Play: the position's last digit is a 3");
	probe(9'd140, W, "Play: the 3 reaches gx 4");
	probe(9'd144, B, "Play: the slash is bare at gx 0"); // / = 00001
	probe(9'd148, W, "Play: the slash inks gx 4");
	probe(9'd152, B, "Play: the 8 is bare at its top-left"); // 8 = 01110
	probe(9'd153, W, "Play: the 8 inks its top row");
	probe(9'd176, B, "Play: the length ends with a 2");    // 2 = 01110
	probe(9'd177, W, "Play: the 2 inks its top row");
	probe(9'd184, B, "Play: the bar's padding cell is empty");

	// ------------------------------------------- 4. END and EMPTY
	playing = 0;
	repeat (2) @(posedge clk);
	probe(9'd72, W, "END: E fills its top row");
	probe(9'd76, W, "END: E ends at gx 4");
	probe(9'd80, W, "END: N inks its left stroke");      // N = 10001
	probe(9'd81, B, "END: N is hollow beside it");
	probe(9'd88, W, "END: D inks its top-left");         // D = 11110
	probe(9'd91, W, "END: D reaches gx 3");
	probe(9'd148, W, "END: the slash is still there");

	count = 16'd0;
	repeat (2) @(posedge clk);
	probe(9'd72, W, "EMPTY: E fills its top row");
	probe(9'd80, W, "EMPTY: M inks its left stroke");    // M = 10001
	probe(9'd81, B, "EMPTY: M is hollow beside it");
	probe(9'd88, W, "EMPTY: P inks its top-left");       // P = 11110
	probe(9'd96, W, "EMPTY: T fills its top row");       // T = 11111
	probe(9'd104, W, "EMPTY: Y inks its left stroke");   // Y = 10001
	probe(9'd105, B, "EMPTY: Y is hollow beside it");
	probe(9'd112, B, "EMPTY: no position digits");
	probe(9'd144, B, "EMPTY: no slash either");
	probe(9'd152, B, "EMPTY: no length digits");

	// ------------------------------------------- 5. the bar's edges
	mode = 2'd1; recording = 1; frames_bcd = 16'h0005;
	repeat (2) @(posedge clk);
	probe(9'd56, 16'h0138, "column 7 is outside the bar");
	probe(9'd64, B, "column 8 is the first bar cell");
	probe(9'd137, W, "a five fills the count's last digit cell");
	probe(9'd192, 16'h01C0, "column 24 is outside the bar again");
	probe(9'd255, 16'h01FF, "the picture's right edge is untouched");
	probe(9'd0,   16'h0100, "the picture's left edge is untouched");

	if (errors == 0) $display("TB REPLAY STATUS PASS");
	else             $display("TB REPLAY STATUS FAIL (%0d errors)", errors);
	$finish;
end

endmodule
