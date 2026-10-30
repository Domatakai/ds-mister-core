//============================================================================
// NDS MiSTer Test — boot menu testbench
//
//   iverilog -g2012 -o /tmp/tb_menu tb/tb_boot_menu.sv \
//            rtl/video/boot_menu.sv rtl/video/font5x7.sv && vvp /tmp/tb_menu
//
// The pixel path here is combinational apart from one output register, so
// probes can address any pixel directly instead of scanning frames. Expected
// colours come from the glyph shapes themselves ('N' is 10001 on its top row,
// '1' is 0010x, ...) and from the layout, not from the RTL: the checks would
// fail if a character moved a cell, if the highlight bar shifted, or if a
// title, a size or a save type came from the wrong slot.
//
// Column map of a row: 5 slot number, 7..16 title, 18..21 game code, 23..26
// declared size, 28..31 save type, one blank cell between fields; the bar
// runs from column 4 to the right edge.
//
// Checks:
//   1. With the menu closed the picture passes through (one cycle, DE kept).
//   2. Opening it and drawing the header, the slot number, a title letter and
//      the hint line at their documented cells.
//   3. The selected row is barred (white background, black glyph) and the
//      bar follows Down/Up, wrapping round the four slots.
//   4. A boots a valid slot (pulse + boot_sel + menu closes); an empty slot
//      does nothing.
//   5. With no games at all the menu says so instead of listing blanks.
//   6. Close hides it, and with the option disabled it cannot be opened.
//   7. Each game's declared size sits right aligned in columns 23..26 and its
//      save type in 28..31; the footer states the 64 MB a slot holds, an
//      empty slot shows neither, and an undeclared size draws nothing.
//   8. The save column is per slot: four slots carry four different records,
//      and a four-character size still leaves the gap before it blank.
//============================================================================
`timescale 1ns / 1ps

module tb_boot_menu;

reg clk = 0;
always #10 clk = ~clk;

reg         reset = 1;
reg         enable = 1;
reg         open_req = 0, close_req = 0;
reg         up = 0, down = 0, a = 0;
reg  [3:0]  slot_valid = 4'b0001;
// header byte 0x80 per slot: 8 = 32 MB, 9 = 64 MB, 10 = 128 MB, 12 = 512 MB
reg  [31:0] slot_caps = {8'd12, 8'd10, 8'd9, 8'd8};
// save type recorded per slot: 0 Auto, 3 FLASH 512K, 5 FRAM, 6 NAND
reg  [15:0] slot_save = {4'd6, 4'd3, 4'd5, 4'd1};

wire [1:0]  hdr_slot;
wire [3:0]  hdr_char;

// sixteen header bytes per slot, as the cart holds them:
// 0x00..0x0B title, 0x0C..0x0F game code
reg  [7:0]  tmem [0:63];
wire [7:0]  hdr_data = tmem[{hdr_slot, hdr_char}];

wire        active;
wire [1:0]  boot_sel;
wire        boot_pulse;

reg  [8:0]  x = 0, y = 0;
reg         de = 0, hs = 0, vs = 0;
reg  [15:0] rgb_in = 0;
wire [15:0] rgb_o;
wire        de_o, hs_o, vs_o;

boot_menu dut (
	.clk(clk), .ce(1'b1), .reset(reset),
	.enable(enable),
	.open_req(open_req), .close_req(close_req),
	.up(up), .down(down), .a(a),
	.slot_valid(slot_valid),
	.hdr_slot(hdr_slot), .hdr_char(hdr_char), .hdr_data(hdr_data),
	.slot_caps(slot_caps), .slot_save(slot_save),
	.active(active), .boot_sel(boot_sel), .boot_pulse(boot_pulse),
	.x(x), .y(y), .de(de), .hs(hs), .vs(vs), .rgb_in(rgb_in),
	.rgb_o(rgb_o), .de_o(de_o), .hs_o(hs_o), .vs_o(vs_o)
);

localparam [15:0] W = 16'h7FFF;
localparam [15:0] B = 16'h0000;

integer errors = 0;
task check;
	input [8*46:1] name;
	input          cond;
	begin
		if (!cond) begin
			$display("FAIL %0s", name);
			errors = errors + 1;
		end else
			$display("ok   %0s", name);
	end
endtask

// one pixel through the pipeline: drive (px,py), read one cycle later
task probe;
	input [8:0]  px;
	input [9:0]  py;
	input [15:0] exp;
	input [8*34:1] name;
	begin
		@(negedge clk);
		x = px; y = py[8:0]; de = 1; hs = 1; vs = 1;
		rgb_in = 16'h0100 + px;
		@(posedge clk);
		@(negedge clk);
		if (rgb_o !== exp || de_o !== 1'b1) begin
			$display("FAIL %0s: got %04x want %04x at (%0d,%0d)",
			         name, rgb_o, exp, px, py);
			errors = errors + 1;
		end else begin
			$display("ok   %0s", name);
		end
	end
endtask

task pulse_open;
	begin
		@(negedge clk); open_req = 1;
		@(negedge clk); open_req = 0;
		repeat (2) @(posedge clk);
	end
endtask

task pulse_close;
	begin
		@(negedge clk); close_req = 1;
		@(negedge clk); close_req = 0;
		repeat (2) @(posedge clk);
	end
endtask

task pulse_down;
	begin
		@(negedge clk); down = 1;
		@(negedge clk); down = 0;
		repeat (2) @(posedge clk);
	end
endtask

task pulse_up;
	begin
		@(negedge clk); up = 1;
		@(negedge clk); up = 0;
		repeat (2) @(posedge clk);
	end
endtask

task pulse_a;
	begin
		@(negedge clk); a = 1;
		@(negedge clk); a = 0;
		repeat (2) @(posedge clk);
	end
endtask

// counts boot requests, so a one-cycle pulse is not missed
integer boot_count = 0;
always @(posedge clk) if (boot_pulse) boot_count = boot_count + 1;

integer i;
initial begin
	for (i = 0; i < 64; i = i + 1) tmem[i] = 8'h00;

	// slot 0 "FIRST GAME" code AMCE, slot 1 "SECOND GAME" code AZEP
	begin : titles
		tmem[0] = "F"; tmem[1] = "I"; tmem[2] = "R"; tmem[3] = "S";
		tmem[4] = "T"; tmem[5] = " "; tmem[6] = "G"; tmem[7] = "A";
		tmem[8] = "M"; tmem[9] = "E"; tmem[10] = " "; tmem[11] = " ";
		tmem[12] = "A"; tmem[13] = "M"; tmem[14] = "C"; tmem[15] = "E";
		tmem[16] = "S"; tmem[17] = "E"; tmem[18] = "C"; tmem[19] = "O";
		tmem[20] = "N"; tmem[21] = "D"; tmem[22] = " "; tmem[23] = "G";
		tmem[24] = "A"; tmem[25] = "M"; tmem[26] = "E"; tmem[27] = " ";
		tmem[28] = "A"; tmem[29] = "Z"; tmem[30] = "E"; tmem[31] = "P";
	end

	repeat (4) @(posedge clk);
	reset = 0;
	repeat (4) @(posedge clk);

	// ------------------------------------------------ 1. closed = passthrough
	probe(9'd10, 10'd10, 16'h010A, "closed: picture passes through");
	probe(9'd200, 10'd300, 16'h01C8, "closed: far corner passes through");
	check("closed menu is not active", active === 1'b0);

	// ------------------------------------------------ 2. open + text layout
	pulse_open;
	check("open shows the menu", active === 1'b1);

	// header "NDS BOOT MENU" starts at column 9, row 3 (y = 24):
	// 'N' = 10001 on its top row -> ink at gx 0 and 4, blank between
	probe(9'd72, 10'd24, W, "header N left stroke");
	probe(9'd73, 10'd24, B, "header N is hollow");
	probe(9'd76, 10'd24, W, "header N right stroke");
	probe(9'd0,  10'd0,  B, "menu background is black");

	// hint line at row 44 (y = 352), column 8: 'U' = 10001
	probe(9'd64, 10'd352, W, "hint U stroke");
	probe(9'd66, 10'd352, B, "hint U hollow");
	// the space between "UP" and "DOWN" is a blank cell, not a glyph
	probe(9'd80, 10'd352, B, "space between UP and DOWN is blank");

	// footer, columns 24..31: "64M SLOT", the capacity a slot holds
	probe(9'd192, 10'd352, B, "footer 6: top-left is bare");   // 00110
	probe(9'd194, 10'd352, W, "footer 6 inks its top row");
	probe(9'd203, 10'd352, W, "footer 4 inks its apex");       // 00010
	probe(9'd208, 10'd352, W, "footer M inks its left stroke");// 10001
	probe(9'd216, 10'd352, B, "footer space before SLOT is blank");
	probe(9'd224, 10'd352, B, "footer S: top-left is bare");    // 01111
	probe(9'd225, 10'd352, W, "footer S inks its top row");
	probe(9'd248, 10'd352, W, "footer T ends at the screen edge");

	// entry 0 (row 10, y = 80) is selected: bar is white, glyph is black
	probe(9'd32,  10'd80, W, "selected row is barred from column 4");
	probe(9'd24,  10'd80, B, "the bar starts at column 4, not before");
	probe(9'd40,  10'd80, W, "slot number 1: bar shows through at gx 0"); // 00100
	probe(9'd42,  10'd80, B, "slot number 1 inverts on the bar");
	probe(9'd48,  10'd80, W, "gap between slot number and title");
	probe(9'd80,  10'd80, W, "title S: top-left is bare");     // 01111
	probe(9'd81,  10'd80, B, "title S inks its second pixel");
	probe(9'd56,  10'd80, B, "title F inverts on the bar");   // 'F' top = 11111
	probe(9'd128, 10'd80, B, "title's tenth cell holds the title");
	probe(9'd136, 10'd80, W, "gap between title and game code");

	// game code columns 18..21 (x = 144..), row 10: slot 0 carries "AMCE".
	// 'A' top row is 01110, so its top-left pixel is bare on the white
	// bar and the next one is ink -- a bar with no glyph would be white
	// in both, and 'M' (10001) would ink the leftmost one.
	probe(9'd144, 10'd80, W, "game code A: top-left is bare");
	probe(9'd145, 10'd80, B, "game code A inks its top row");
	probe(9'd152, 10'd80, B, "game code M inks its left stroke");
	probe(9'd153, 10'd80, W, "game code M is hollow beside the stroke");
	probe(9'd160, 10'd80, W, "game code C: top-left is bare");
	probe(9'd161, 10'd80, B, "game code C inks its top row");
	probe(9'd168, 10'd80, B, "game code E fills its top row");
	probe(9'd176, 10'd80, W, "gap between game code and size");

	// declared size, columns 23..26 (x = 184..): slot 0 is 32 MB, so the
	// row holds " 32M" -- a blank cell, then '3' (11111 across the top, a
	// single stem on the second row), '2' (01110) and 'M' (10001)
	probe(9'd184, 10'd80, W, "size is right aligned in its four cells");
	probe(9'd192, 10'd80, B, "size 3 inks its whole top row");
	probe(9'd192, 10'd81, W, "size 3 second row starts bare");
	probe(9'd195, 10'd81, B, "size 3 second row has its stem");
	probe(9'd200, 10'd80, W, "size 2 top-left is bare");
	probe(9'd201, 10'd80, B, "size 2 inks its top row");
	probe(9'd208, 10'd80, B, "size M inks its left stroke");
	probe(9'd209, 10'd80, W, "size M is hollow beside the stroke");
	probe(9'd216, 10'd80, W, "gap between size and save type");

	// save type, columns 28..31 (x = 224..): the probe found EEPROM 512K
	// for slot 0, so 'E' (11111), '5' (11111), '1' (00100) and '2' (01110)
	probe(9'd224, 10'd80, B, "save E512: E fills its top row");
	probe(9'd228, 10'd80, B, "save E512: E ends at its fifth pixel");
	probe(9'd232, 10'd80, B, "save E512: 5 fills its top row");
	probe(9'd232, 10'd81, B, "save E512: 5 keeps its left stroke");
	probe(9'd240, 10'd80, W, "save E512: 1 has no ink off-centre");
	probe(9'd242, 10'd80, B, "save E512: 1 inks its stem");
	probe(9'd248, 10'd80, W, "save E512: 2 top-left is bare");
	probe(9'd249, 10'd80, B, "save E512: 2 inks its top row");
	probe(9'd255, 10'd80, W, "bar runs to the screen edge");

	// slot 1 holds nothing yet: "(EMPTY)" under the titles, no size or save
	probe(9'd24,  10'd104, B, "second row is not barred");
	probe(9'd56,  10'd104, B, "empty slot text starts at column 7");
	probe(9'd59,  10'd104, W, "empty slot opens a bracket");   // '(' top = 00010
	probe(9'd184, 10'd104, B, "empty slot shows no size");
	probe(9'd224, 10'd104, B, "empty slot shows no save type");
	probe(9'd232, 10'd104, B, "empty slot save cells stay blank");

	// ------------------------------------------------ 3. highlight follows
	pulse_down;
	probe(9'd32, 10'd80,  B, "bar leaves the first row");
	probe(9'd32, 10'd104, W, "bar moves to the second row");

	pulse_up;
	pulse_up;                       // back to 0, then wrap to 3
	check("Up wraps round the slots", boot_sel === 2'd3);
	probe(9'd32, 10'd152, W, "bar wraps to the last row");

	// slot 3 is the 512 MB, NAND one: four size cells with no leading gap,
	// then a blank cell, then the save type. That blank is what a four
	// character size must never eat.
	probe(9'd40,  10'd152, W, "slot number 4 has no ink at gx 0"); // 00010
	probe(9'd43,  10'd152, W, "slot number 4 inks its apex");
	probe(9'd184, 10'd152, W, "size 512M starts at column 23");    // '5' = 11111
	probe(9'd208, 10'd152, W, "size 512M ends in M");
	probe(9'd216, 10'd152, W, "gap after a four-character size");
	probe(9'd224, 10'd152, W, "save NAND inks its left stroke");   // 10001
	probe(9'd232, 10'd152, W, "save NAND A is bare top-left");

	// back to slot 0
	pulse_down;
	check("Down returns to slot 0", boot_sel === 2'd0);
	probe(9'd32, 10'd80, W, "bar is back on the first row");

	// ------------------------------------------------ 4. booting
	pulse_down;                     // slot 1 is empty in this state
	boot_count = 0;
	pulse_a;
	check("A on an empty slot does nothing", boot_count == 0 && active === 1'b1);

	slot_valid = 4'b0011;
	repeat (2) @(posedge clk);

	// slot 1 now shows its own title, code, 64 MB and FRAM; the bar is on it
	probe(9'd56,  10'd104, W, "second title starts at column 7");  // 'S' = 01111
	probe(9'd57,  10'd104, B, "second title S second pixel is inked");
	probe(9'd184, 10'd104, W, "size 64M starts at column 24");     // '6' = 00110
	probe(9'd194, 10'd104, B, "size 6 inks from its third pixel");
	probe(9'd224, 10'd104, B, "save FRAM F fills its top row");    // 11111
	probe(9'd228, 10'd104, B, "save FRAM F ends at its fifth pixel");
	probe(9'd232, 10'd104, B, "save FRAM R inks its top-left");   // 11110
	probe(9'd236, 10'd104, W, "save FRAM R is blank at its fifth pixel");
	// and the row above is now plain white-on-black, size and save included
	probe(9'd192, 10'd80, W, "unselected size 3 is white");
	probe(9'd195, 10'd81, W, "unselected size 3 stem is white");
	probe(9'd224, 10'd80, W, "unselected save E is white where it inks");
	probe(9'd225, 10'd80, W, "unselected 5 continues the white row");

	// a header that never declares 0x80 leaves the size unknown (0xFF):
	// the row draws its title and save type but the size cells stay empty
	slot_caps[23:16] = 8'hFF;
	slot_valid       = 4'b0111;
	repeat (2) @(posedge clk);
	probe(9'd184, 10'd128, B, "unknown size draws nothing");
	probe(9'd208, 10'd128, B, "unknown size leaves the last cell empty");
	probe(9'd224, 10'd128, W, "unknown size does not hide the save type");   // F = 11111
	// a slot the probe could not identify (code 0) draws nothing, exactly
	// like a size the header never declared
	slot_save[3:0] = 4'd0;
	repeat (2) @(posedge clk);
	probe(9'd224, 10'd80, B, "no save chip detected: column stays empty");
	probe(9'd232, 10'd80, B, "no save chip detected: second cell stays empty");

	boot_count = 0;
	pulse_a;
	check("A on a valid slot boots it", boot_count == 1);
	check("boot selects the highlighted slot", boot_sel === 2'd1);
	check("booting closes the menu", active === 1'b0);

	// ------------------------------------------------ 6. close and disable
	pulse_open;
	check("menu opens again", active === 1'b1);
	pulse_close;
	check("close hides the menu", active === 1'b0);

	enable = 0;
	pulse_open;
	check("disabled menu cannot be opened", active === 1'b0);
	enable = 1;

	// ------------------------------------------------ 5. no games at all
	slot_valid = 4'b0000;
	repeat (2) @(posedge clk);
	pulse_open;
	// "NO GAMES LOADED" from column 7, row 10 (y = 80): 'N' at x = 56
	probe(9'd56, 10'd80, W, "empty library says NO GAMES");
	probe(9'd57, 10'd80, B, "NO GAMES N is hollow");
	probe(9'd184, 10'd80, B, "no games means no size column");
	probe(9'd224, 10'd80, B, "no games means no save column");
	boot_count = 0;
	pulse_a;
	check("no slot to boot", boot_count == 0 && active === 1'b1);
	pulse_close;

	if (errors == 0) $display("TB BOOT MENU PASS");
	else             $display("TB BOOT MENU FAIL (%0d errors)", errors);
	$finish;
end

endmodule
