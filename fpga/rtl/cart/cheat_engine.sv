//============================================================================
// NDS MiSTer Test — cheat engine (Action Replay DS / GameShark v3)
//
// Reference: GBATEK "DS Cart Cheat: Action Replay DS"
//   https://problemkaputt.de/gbatek-ds-cart-cheat-action-replay-ds.htm
//
// The F2 download path streams the cheat text as ASCII bytes (hps_io
// f2_dout). The loader assembles lines of two 8-hex-digit words:
//
//     <TAAAAAAA> <DDDDDDDD>
//
// where T is the type nibble and AAAAAAA the 28-bit byte address.
// Supported at runtime (the common unconditional subset plus guarded
// writes):
//
//   type 0  DDDDDDDD  write 32-bit word
//   type 1  0000DDDD  write 16-bit halfword
//   type 2  000000DD  write 8-bit byte (lane = addr[0])
//   type 3  DDDDDDDD  condition: D > word[X]   (fail blocks writes)
//   type 4            condition: D < word[X]
//   type 5            condition: D == word[X]
//   type 6            condition: D != word[X]
//   type 7..A  ZZZZDDDD  16-bit masked condition vs halfword at X
//              (compare D op (half & ~Z), ops >, <, ==, !=)
//   other types (B, C, D3..DC, E, F) — ignored, parsed as no-ops so a
//   data-register/loop code never wedges the loader.
//
// Guard model (documented approximation of the ARDS interpreter): a
// condition whose address matches the word being read is evaluated
// immediately — pass clears the block, fail sets it — and blocked
// writes are suppressed until the condition passes on a later access
// or a new file is loaded. Unblocked write types substitute the value
// main_bus returns for that read.
//
// Codes live in BRAM (32 stored). Loading a new file clears the set
// and the block; "Disable all cheats" (status[125]) sets a lockout
// that only a new file load clears.
//============================================================================
module cheat_engine (
	input            clk,
	input            reset,

	// F2 text stream (8-bit ASCII bytes)
	input            f2_wr,
	input      [7:0] f2_dout,

	// OSD "Disable all cheats" trigger (status[125])
	input            clr_cheats,

	// runtime query from main_bus (per main-RAM read)
	input            chk_en,
	input     [31:0] chk_addr,
	input     [31:0] chk_word,     // full word at the read address

	output reg       hit,          // low halfword substitution
	output reg [15:0] patch,
	output reg       patch_hi_en,  // high halfword substitution (type 0)
	output reg [15:0] patch_hi
);

//------------------------------------------------------------------
// Storage: raw code pairs (32 entries)
//------------------------------------------------------------------
reg [27:0] c_addr [0:31];
reg [31:0] c_raw  [0:31];
reg  [3:0] c_type [0:31];
reg  [5:0] c_count = 0;     // codes stored (0..32, walk uses c_valid)
reg        c_valid [0:31];

reg        blk_reg = 0;   // guarded-write block state (persistent)
reg        lockout = 0;   // "Disable all cheats"

//------------------------------------------------------------------
// Loader: bytes -> ASCII line -> one code pair
//------------------------------------------------------------------
reg [7:0]  line [0:63];
reg [5:0]  line_len = 0;
reg        in_digit = 0;
reg [31:0] d1 = 0;
reg        have_d1 = 0;

// end-of-file detection: f2 activity gap separates successive loads
reg [15:0] gap = 0;
reg        in_load = 0;

integer i;

function [3:0] hexv;
	input [7:0] ch;
	reg   [7:0] t;
	begin
		if      (ch >= "0" && ch <= "9") t = ch - "0";
		else if (ch >= "a" && ch <= "f") t = ch - "a" + 8'd10;
		else if (ch >= "A" && ch <= "F") t = ch - "A" + 8'd10;
		else                             t = 8'hFF;
		hexv = t[3:0];
	end
endfunction

task parse_line;
	reg [31:0] w0, w1;
	reg  [3:0] nib;
	reg        ok;
	integer    k;
	begin
		if (line_len >= 6'd8 && in_digit) begin
			w0 = 32'd0; w1 = 32'd0; ok = 1'b1;
			for (k = 0; k < 8; k = k + 1) begin
				nib = hexv(line[k]);
				if (nib == 4'hF) ok = 1'b0;
				w0 = {w0[27:0], nib};
			end
			if (ok) begin
				if (line_len >= 6'd17 && line[8] == " ") begin
					for (k = 0; k < 8; k = k + 1) begin
						nib = hexv(line[9 + k]);
						if (nib == 4'hF) ok = 1'b0;
						w1 = {w1[27:0], nib};
					end
				end else
					ok = 1'b0;                 // need the data word too

				if (ok && c_count < 6'd32) begin
					c_addr[c_count[4:0]]  <= w0[27:0];
					c_raw[c_count[4:0]]   <= w1;
					c_type[c_count[4:0]]  <= w0[31:28];
					c_valid[c_count[4:0]] <= 1'b1;
					c_count               <= c_count + 6'd1;
				end
			end
		end
		line_len <= 6'd0;
		in_digit <= 1'b0;
	end
endtask

always @(posedge clk) begin
	if (reset) begin
		line_len <= 6'd0; in_digit <= 0; have_d1 <= 0;
		gap <= 0; in_load <= 0;
	end else begin
		if (f2_wr) begin
			// first byte after an idle gap = new file: clear codes
			if (!in_load) begin
				c_count <= 0;
				for (i = 0; i < 32; i = i + 1) c_valid[i] <= 1'b0;
			end
			in_load <= 1'b1;
			gap     <= 16'hFFFF;
			if (f2_dout == "\n") begin
				parse_line;
			end else if (f2_dout != "\r" && line_len < 6'd40) begin
				if (f2_dout >= "0" && f2_dout <= "9") in_digit <= 1'b1;
				line[line_len] <= f2_dout;
				line_len <= line_len + 6'd1;
			end
		end else if (gap != 0) begin
			gap <= gap - 16'd1;
		end else
			in_load <= 1'b0;
	end
end

//------------------------------------------------------------------
// Runtime walk (combinational, list order, running block state)
//------------------------------------------------------------------
reg        blk;
integer    j;

always @(*) begin
	hit         = 1'b0;
	patch       = chk_word[15:0];
	patch_hi_en = 1'b0;
	patch_hi    = chk_word[31:16];
	blk         = blk_reg;

	if (chk_en && !lockout) begin
		for (j = 0; j < 32; j = j + 1) begin
			if (c_valid[j] && c_addr[j] == chk_addr[27:0]) begin
				case (c_type[j])
				// ---- unconditional writes (gated by running blk)
				4'h0: if (!blk) begin
					hit = 1'b1;
					patch     = c_raw[j][15:0];
					patch_hi_en = 1'b1;
					patch_hi  = c_raw[j][31:16];
				end
				4'h1: if (!blk) begin
					hit   = 1'b1;
					patch = c_raw[j][15:0];
				end
				4'h2: if (!blk) begin
					hit = 1'b1;
					// lane0 = low byte of the halfword, lane1 = high byte
					patch = chk_addr[0] ?
						{c_raw[j][7:0], chk_word[7:0]} :
						{chk_word[15:8], c_raw[j][7:0]};
				end
				// ---- conditionals: eval on matching read, update blk
				4'h3: blk = !(c_raw[j] >  chk_word);
				4'h4: blk = !(c_raw[j] <  chk_word);
				4'h5: blk = !(c_raw[j] == chk_word);
				4'h6: blk = !(c_raw[j] != chk_word);
				4'h7, 4'h8, 4'h9, 4'hA:
					blk = !(
						(c_type[j] == 4'h7) ? ((chk_word[15:0] & ~c_raw[j][31:16]) <  c_raw[j][15:0]) :
						(c_type[j] == 4'h8) ? ((chk_word[15:0] & ~c_raw[j][31:16]) >  c_raw[j][15:0]) :
						(c_type[j] == 4'h9) ? ((chk_word[15:0] & ~c_raw[j][31:16]) == c_raw[j][15:0]) :
						                     ((chk_word[15:0] & ~c_raw[j][31:16]) != c_raw[j][15:0]));
				default: ;   // B/C/D/E/F and unknown: no-op
				endcase
			end
		end
	end
end

// persist the block decision; new-file load resets guard + lockout
always @(posedge clk) begin
	if (reset) begin
		blk_reg <= 1'b0;
		lockout <= 1'b0;
	end else begin
		if (f2_wr && !in_load) begin
			blk_reg <= 1'b0;
			lockout <= 1'b0;
		end else
			blk_reg <= blk;
		if (clr_cheats) lockout <= 1'b1;
	end
end

endmodule
