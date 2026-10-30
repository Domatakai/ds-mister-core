//============================================================================
// NDS MiSTer Test — boot menu
//
// A MiSTer core never sees the SD card: the HPS sends it one file per OSD
// selection and nothing else, so a core cannot list a folder. What it can do
// is keep several games at once — cart_slot holds four in DDR3, each named
// by the title string in its own ROM header — and let the player switch
// between them after they have been loaded. That is this menu.
//
// It draws straight into the video path: a black screen with the four slot
// titles, each row's game code, its save type and the ROM size its header
// declares, the selected row barred, and a hint line that also states how
// much a slot holds. Up/Down move, A boots the highlighted slot (the top
// level then resets the core onto it), Select or the OSD action closes it
// again. When the menu is closed the picture passes through untouched, one
// pixel clock enable later, exactly like the panel overlay.
//
// Text is 8x8 cells (5x7 glyph from font5x7) over the 256x384 frame: 32
// columns by 48 rows, which fits a 10-character title beside the game code,
// the declared size and the save type.
//
// A slot holds 64 MB, so a game whose header declares more than that will be
// cut off when it is loaded: the size column is what makes that visible
// before pressing A, and the footer repeats the limit.
//
// The save type is not in the header either: a DS cart is classified by
// probing its AUXSPI interface. The cart does that (rtl/cart/save_probe.sv)
// and hands this module what the emulated chip answered, so the column is a
// measurement rather than a copy of the OSD row -- and a slot with no chip,
// or one the probe could not identify, draws nothing at all.
//============================================================================
module boot_menu (
	input             clk,
	input             ce,        // pixel clock enable
	input             reset,

	input             enable,    // OSD: menu available
	input             open_req,  // one-cycle pulse
	input             close_req, // one-cycle pulse
	input             up,        // pad edges, one-cycle pulses
	input             down,
	input             a,

	// game slots (from cart_slot)
	input      [3:0]  slot_valid,
	output     [1:0]  hdr_slot,  // title read port
	output     [3:0]  hdr_char,
	input      [7:0]  hdr_data,
	input      [31:0] slot_caps, // one header capacity byte per slot
	input      [15:0] slot_save, // one save-type record (4 bits) per slot

	// results
	output reg        active,
	output     [1:0]  boot_sel,
	output reg        boot_pulse,

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

	//------------------------------------------------------------------
	// selection and the boot request
	//------------------------------------------------------------------
	reg [1:0] sel = 2'd0;

	assign boot_sel = sel;

	always @(posedge clk) begin
		if (reset) begin
			sel        <= 2'd0;
			active     <= 1'b0;
			boot_pulse <= 1'b0;
		end else begin
			boot_pulse <= 1'b0;
			if (open_req && enable)  active <= 1'b1;
			if (close_req || !enable) active <= 1'b0;

			if (active) begin
				if (up)   sel <= sel - 2'd1;   // wraps round the four slots
				if (down) sel <= sel + 2'd1;
				if (a && slot_valid[sel]) begin
					boot_pulse <= 1'b1;
					active     <= 1'b0;
				end
			end
		end
	end

	//------------------------------------------------------------------
	// text layout: 8x8 cells over 256x384
	//------------------------------------------------------------------
	wire [4:0] tcol = x[7:3];      // 0..31
	wire [5:0] trow = y[8:3];      // 0..47
	wire [2:0] gx   = x[2:0];
	wire [2:0] gy   = y[2:0];

	wire any_valid = |slot_valid;

	reg [1:0] ent     = 2'd0;
	reg       ent_hit = 1'b0;
	always @(*) begin
		ent_hit = 1'b1;
		case (trow)
		6'd10:   ent = 2'd0;
		6'd13:   ent = 2'd1;
		6'd16:   ent = 2'd2;
		6'd19:   ent = 2'd3;
		default: begin ent = 2'd0; ent_hit = 1'b0; end
		endcase
	end

	// Declared ROM size, right aligned in four cells: " 32M", "128M". The
	// DS header's capacity byte is 0x80 = 128 KB << cap, so every size is one
	// of thirteen constants -- no divider, and exactly what the cart clamps to.
	function [31:0] size_text;
		input [7:0] cap;
		begin
			case (cap)
			8'd0:    size_text = "128K";
			8'd1:    size_text = "256K";
			8'd2:    size_text = "512K";
			8'd3:    size_text = "  1M";
			8'd4:    size_text = "  2M";
			8'd5:    size_text = "  4M";
			8'd6:    size_text = "  8M";
			8'd7:    size_text = " 16M";
			8'd8:    size_text = " 32M";
			8'd9:    size_text = " 64M";
			8'd10:   size_text = "128M";
			8'd11:   size_text = "256M";
			8'd12:   size_text = "512M";
			default: size_text = "    ";
			endcase
		end
	endfunction

	// Save type the probe detected for the slot, in four cells. The letters
	// name the family and the digits the size, exactly as the OSD row spells
	// them out (EEPROM 512K, EEPROM 8K, FLASH 512K, FLASH 1M) -- too long for
	// a 32 column row next to a title, a game code and a size. Code 0 is
	// "no save chip": nothing is drawn, the same discipline as an undeclared
	// ROM size.
	function [31:0] save_text;
		input [3:0] rec;
		begin
			case (rec)
			4'd0:    save_text = "    ";
			4'd1:    save_text = "E512";
			4'd2:    save_text = " E8K";
			4'd3:    save_text = "F512";
			4'd4:    save_text = " F1M";
			4'd5:    save_text = "FRAM";
			4'd6:    save_text = "NAND";
			default: save_text = "    ";
			endcase
		end
	endfunction

	// Row layout, 32 columns: 5 slot number, 7..16 title (header 0x00..0x0B),
	// 18..21 game code (0x0C..0x0F), 23..26 declared size, 28..31 save type,
	// one blank cell between fields. Four fields plus a slot number need the
	// whole row, so the bar starts at column 4 rather than 6.
	wire        title_col = (tcol >= 5'd7)  && (tcol <= 5'd16);
	wire        code_col  = (tcol >= 5'd18) && (tcol <= 5'd21);
	wire        size_col  = (tcol >= 5'd23) && (tcol <= 5'd26);
	wire        save_col  = (tcol >= 5'd28);

	wire [4:0]  tchar = title_col ? (tcol - 5'd7) : 5'd0;
	wire [4:0]  cchar = code_col  ? (tcol - 5'd18) : 5'd0;
	wire [4:0]  schar = size_col  ? (tcol - 5'd23) : 5'd0;   // 0..3
	wire [4:0]  vchar = save_col  ? (tcol - 5'd28) : 5'd0;   // 0..3

	assign hdr_slot = ent;
	assign hdr_char = code_col ? {2'b11, cchar[1:0]} : tchar[3:0];   // 12..15

	wire [7:0]  cap_sel  = slot_caps[{ent, 3'b000} +: 8];
	wire [31:0] size_txt = size_text(cap_sel);
	wire [7:0]  size_ch  = size_txt[8 * (5'd3 - schar) +: 8];

	wire [3:0]  save_sel = slot_save[{ent, 2'b00} +: 4];
	wire [31:0] save_txt = save_text(save_sel);
	wire [7:0]  save_ch  = save_txt[8 * (5'd3 - vchar) +: 8];

	//------------------------------------------------------------------
	// fixed strings
	//------------------------------------------------------------------
	function [7:0] hdr_ch;      // "NDS BOOT MENU" from column 9
		input [4:0] c;
		reg   [4:0] i;
		begin
			i = c - 5'd9;
			case (i)
			5'd0:  hdr_ch = "N";
			5'd1:  hdr_ch = "D";
			5'd2:  hdr_ch = "S";
			5'd3:  hdr_ch = " ";
			5'd4:  hdr_ch = "B";
			5'd5:  hdr_ch = "O";
			5'd6:  hdr_ch = "O";
			5'd7:  hdr_ch = "T";
			5'd8:  hdr_ch = " ";
			5'd9:  hdr_ch = "M";
			5'd10: hdr_ch = "E";
			5'd11: hdr_ch = "N";
			5'd12: hdr_ch = "U";
			default: hdr_ch = " ";
			endcase
		end
	endfunction

	function [7:0] empty_ch;    // "(EMPTY)" from column 7, under the titles
		input [4:0] c;
		reg   [4:0] i;
		begin
			i = c - 5'd7;
			case (i)
			5'd0: empty_ch = "(";
			5'd1: empty_ch = "E";
			5'd2: empty_ch = "M";
			5'd3: empty_ch = "P";
			5'd4: empty_ch = "T";
			5'd5: empty_ch = "Y";
			5'd6: empty_ch = ")";
			default: empty_ch = " ";
			endcase
		end
	endfunction

	function [7:0] nofile_ch;   // "NO GAMES LOADED" from column 7
		input [4:0] c;
		reg   [4:0] i;
		begin
			i = c - 5'd7;
			case (i)
			5'd0:  nofile_ch = "N";
			5'd1:  nofile_ch = "O";
			5'd2:  nofile_ch = " ";
			5'd3:  nofile_ch = "G";
			5'd4:  nofile_ch = "A";
			5'd5:  nofile_ch = "M";
			5'd6:  nofile_ch = "E";
			5'd7:  nofile_ch = "S";
			5'd8:  nofile_ch = " ";
			5'd9:  nofile_ch = "L";
			5'd10: nofile_ch = "O";
			5'd11: nofile_ch = "A";
			5'd12: nofile_ch = "D";
			5'd13: nofile_ch = "E";
			5'd14: nofile_ch = "D";
			default: nofile_ch = " ";
			endcase
		end
	endfunction

	function [7:0] info_ch;     // "64M SLOT" from column 24
		input [4:0] c;
		reg   [4:0] i;
		begin
			i = c - 5'd24;
			case (i)
			5'd0:  info_ch = "6";
			5'd1:  info_ch = "4";
			5'd2:  info_ch = "M";
			5'd3:  info_ch = " ";
			5'd4:  info_ch = "S";
			5'd5:  info_ch = "L";
			5'd6:  info_ch = "O";
			5'd7:  info_ch = "T";
			default: info_ch = " ";
			endcase
		end
	endfunction

	function [7:0] hint_ch;     // "UP DOWN  A BOOT" from column 8
		input [4:0] c;
		reg   [4:0] i;
		begin
			i = c - 5'd8;
			case (i)
			5'd0:  hint_ch = "U";
			5'd1:  hint_ch = "P";
			5'd2:  hint_ch = " ";
			5'd3:  hint_ch = "D";
			5'd4:  hint_ch = "O";
			5'd5:  hint_ch = "W";
			5'd6:  hint_ch = "N";
			5'd7:  hint_ch = " ";
			5'd8:  hint_ch = " ";
			5'd9:  hint_ch = "A";
			5'd10: hint_ch = " ";
			5'd11: hint_ch = "B";
			5'd12: hint_ch = "O";
			5'd13: hint_ch = "O";
			5'd14: hint_ch = "T";
			default: hint_ch = " ";
			endcase
		end
	endfunction

	//------------------------------------------------------------------
	// character and highlight for this cell
	//------------------------------------------------------------------
	reg [7:0] ch = 8'h00;
	reg       hl = 1'b0;

	always @(*) begin
		ch = 8'h00;
		hl = 1'b0;
		if (trow == 6'd3) begin
			ch = hdr_ch(tcol);
		end else if (ent_hit) begin
			if (!any_valid) begin
				ch = nofile_ch(tcol);
			end else if (!slot_valid[ent]) begin
				ch = empty_ch(tcol);
			end else if (tcol == 5'd5) begin
				ch = 8'h31 + {6'd0, ent};        // '1'..'4'
			end else if (title_col) begin
				ch = hdr_data;                   // the ROM's own title
			end else if (code_col) begin
				ch = hdr_data;                   // game code: AMCE vs AMCP
			end else if (size_col) begin
				ch = size_ch;                    // declared size: 32M, 128M, ...
			end else if (save_col) begin
				ch = save_ch;                    // save type recorded for the slot
			end
			hl = (ent == sel) && (tcol >= 5'd4);   // the bar runs to the edge
		end else if (trow == 6'd44) begin
			ch = (tcol >= 5'd24) ? info_ch(tcol) : hint_ch(tcol);
		end
	end

	//------------------------------------------------------------------
	// ASCII -> font code, then the glyph row
	//------------------------------------------------------------------
	// an 8-bit difference cut down to the font code's six bits: the
	// letters land in 1..26, so only the low six bits are ever wanted
	function [5:0] low6;
		input [7:0] v;
		begin
			low6 = v[5:0];
		end
	endfunction

	function [5:0] a2c;
		input [7:0] c;
		begin
			if      (c >= 8'h61 && c <= 8'h7A) a2c = low6(c - 8'h60);   // a-z
			else if (c >= 8'h41 && c <= 8'h5A) a2c = low6(c - 8'h40);   // A-Z
			else if (c >= 8'h30 && c <= 8'h39) a2c = 6'd27 + low6(c - 8'h30);
			else begin
				case (c)
				8'h2E:   a2c = 6'd37;   // .
				8'h2D:   a2c = 6'd38;   // -
				8'h3A:   a2c = 6'd39;   // :
				8'h2F:   a2c = 6'd40;   // /
				8'h3F:   a2c = 6'd41;   // ?
				8'h28:   a2c = 6'd42;   // (
				8'h29:   a2c = 6'd43;   // )
				8'h2C:   a2c = 6'd44;   // ,
				8'h20,
				8'h00:   a2c = 6'd0;    // space, and header padding
				default: a2c = (c < 8'h20) ? 6'd0 : 6'd41;
				endcase
			end
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

	wire [15:0] bg  = hl ? WHITE : BLACK;
	wire [15:0] fg  = hl ? BLACK : WHITE;
	wire [15:0] pix = ink ? fg : bg;
	wire [15:0] mix = active ? pix : rgb_in;

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
