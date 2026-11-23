//============================================================================
// NDS MiSTer Test — replay status strip
//
// The input log has no readout of its own: `Record` and `Off` look the same
// on screen, `Play` on an empty log quietly passes the live pad through, and
// a log that fills up stops recording without saying so. This module draws
// the state of the log along the bottom of the picture, and draws nothing at
// all when the row is Off:
//
//   REC 0123          recording, 0123 frames stored
//   FULL8192          the log filled up and recording stopped by itself
//   PLAY0123/8192     playing, frame 0123 of 8192
//   END 0123/8192     play reached the end and handed the pad back
//   EMPTY             Play was selected with nothing in the log
//
// All of it comes from the recorder's own counters (`count`, `pos` and their
// decimal copies), so the readout cannot disagree with what is stored. It is
// drawn into the boot menu's bottom row (47, y = 376..383) inside a bar from
// column 8 to 23, and everything outside the bar passes through untouched --
// one pixel clock enable, like the menu above it. The module is only enabled
// while a replay mode is selected; the top level also gates it off while the
// boot menu is open, so the two overlays never fight over the same row.
//============================================================================
module replay_status (
	input             clk,
	input             ce,        // pixel clock enable
	input             reset,

	input       [1:0] mode,      // 0 off, 1 record, 2 play
	input             recording,
	input             playing,
	input      [15:0] count,     // frames in the log
	input      [15:0] frames_bcd,// the same count, four decimal digits
	input      [15:0] pos_bcd,   // frames replayed, four decimal digits

	// video
	input      [8:0]  x,
	input      [8:0]  y,
	input             de,
	input             hs,
	input             vs,
	input      [15:0] rgb_in,
	output reg [15:0] rgb_o,
	output reg        de_o,
	output reg        hs_o,
	output reg        vs_o
);

	localparam [15:0] WHITE = 16'h7FFF;
	localparam [15:0] BLACK = 16'h0000;

	// the row is drawn, and the bar runs from column 8 to 23
	wire        on   = (mode != 2'd0);
	wire [4:0]  tcol = x[7:3];
	wire [5:0]  trow = y[8:3];
	wire [2:0]  gx   = x[2:0];
	wire [2:0]  gy   = y[2:0];

	wire        bar  = (tcol >= 5'd8) && (tcol <= 5'd23);
	wire [4:0]  idx  = tcol - 5'd9;   // text starts one cell into the bar

	// Five cells of label, one per state: the ones that need a word to
	// themselves ("FULL", "EMPTY") and the ones that do not ("REC",
	// "PLAY", "END").
	reg [39:0] label;
	always @(*) begin
		if (mode == 2'd2 && count == 16'd0) label = "EMPTY";
		else if (mode == 2'd1) label = recording ? "REC  " : "FULL ";
		else if (playing)      label = "PLAY ";
		else                   label = "END  ";
	end

	// The line, in one place: label, four digits, and for Play a slash and
	// the log's length. A blank cell wherever a field is not used.
	function [7:0] st_ch;
		input [4:0] i;
		reg   [3:0] d;
		begin
			st_ch = 8'h20;
			if (i <= 5'd4) begin
				st_ch = label[8 * (5'd4 - i) +: 8];
			end else if (i >= 5'd5 && i <= 5'd8) begin
				// digit 0 is the most significant: i = 5..8 -> 15..12
				d = (mode == 2'd2) ? pos_bcd[4 * (5'd8 - i) +: 4]
				                   : frames_bcd[4 * (5'd8 - i) +: 4];
				if (!(mode == 2'd2 && count == 16'd0))
					st_ch = 8'h30 + {4'd0, d};
			end else if (i == 5'd9) begin
				if (mode == 2'd2 && count != 16'd0) st_ch = "/";
			end else if (i >= 5'd10 && i <= 5'd13) begin
				d = frames_bcd[4 * (5'd13 - i) +: 4];
				if (mode == 2'd2 && count != 16'd0)
					st_ch = 8'h30 + {4'd0, d};
			end
		end
	endfunction

	wire [7:0] ch = (tcol >= 5'd9) ? st_ch(idx) : 8'h20;

	// ASCII -> font code: the line only ever holds A-Z, 0-9, space and '/'
	function [5:0] a2c;
		input [7:0] c;
		begin
			if      (c >= 8'h41 && c <= 8'h5A) a2c = {2'd0, c[4:0]};
			else if (c >= 8'h30 && c <= 8'h39) a2c = 6'd27 + {2'd0, c[3:0]};
			else if (c == 8'h2F)               a2c = 6'd40;
			else                               a2c = 6'd0;
		end
	endfunction

	wire [5:0] code = a2c(ch);
	wire [4:0] ink_row;

	font5x7 font5x7 (
		.code(code),
		.row(gy),
		.bits(ink_row)
	);

	wire ink = (gy != 3'd7) && (gx <= 3'd4) && ink_row[4 - gx];
	wire [15:0] pix = ink ? WHITE : BLACK;
	wire [15:0] mix = (on && bar) ? pix : rgb_in;

	//------------------------------------------------------------------
	// output register: one CE, sync delayed to match
	//------------------------------------------------------------------
	always @(posedge clk) begin
		if (reset) begin
			rgb_o <= 16'd0;
			de_o  <= 1'b0;
			hs_o  <= 1'b0;
			vs_o  <= 1'b0;
		end else if (ce) begin
			rgb_o <= mix;
			de_o  <= de;
			hs_o  <= hs;
			vs_o  <= vs;
		end
	end

endmodule
