//============================================================================
// NDS MiSTer Test — cheat engine (GameShark / Action Replay v3)
//
// The F2 download path feeds cheat text through hps_io `f2_dout` (8-bit
// bytes, WIDE=1 mode) into a loader that parses one code line at a time.
// During gameplay every main-RAM read is offered here: a RAM-type code
// whose address matches may substitute the returned halfword.
//
// Code formats parsed (case-insensitive; blank lines and ';' comments
// are skipped), two ASCII hex words per line: <AAAAAAAA> <BBBBBBBB>:
//
//   000VVVVV   set:   X = V                (32-bit)
//   1EEV0000   inc:   X += V               (EE = condition, amount nibble)
//   2EE00000   dec:   X -= V
//   3XXXXXXX   or:    X |= X
//   8EE0YYYY   IF X == Y                   \  conditional pair — the
//   000ZZZZZ   then Z (previous IF holds)  /  then-code applies alone
//   D2000000   code end (stop this page)
//   D4.. / DC.. page/bank forms skipped
//
// Any other format loads as "ignore" so a stray code never wedges the
// loader. Codes live in BRAM (12 entries matched against; 128 stored);
// an F2 reload clears them.
//
// Data flow (the CPU-side read service lands with the CPUs in M1):
//   cheat_chk_en/addr/data from main_bus -> this module returns
//   cheat_hit + cheat_patch, applied to the halfword being returned.
//============================================================================
module cheat_engine (
	input            clk,
	input            reset,

	// F2 text stream (8-bit ASCII bytes)
	input            f2_wr,
	input      [7:0] f2_dout,
	input            f2_last,     // final byte of the download

	// runtime query from main_bus (per main-RAM read)
	input            chk_en,
	input     [31:0] chk_addr,
	input     [15:0] chk_data,    // halfword actually read from RAM

	output reg       hit,
	output reg [15:0] patch
);

//------------------------------------------------------------------
// Storage of parsed codes
//------------------------------------------------------------------
reg [31:0] c_addr [0:127];
reg [31:0] c_data [0:127];
reg  [2:0] c_type [0:127];  // 0 ignore, 1 set, 2 inc, 3 dec, 4 or
reg  [6:0] c_count = 0;     // codes stored in current page
reg        c_valid [0:127];

//------------------------------------------------------------------
// Loader: bytes -> ASCII line -> one code pair
//------------------------------------------------------------------
reg [7:0]  line [0:63];
reg [5:0]  line_len = 0;
reg        in_digit = 0;
reg [31:0] d1 = 0;         // first word (address) of the pair
reg        have_d1 = 0;

integer i;

function [3:0] hexv;
	input [7:0] ch;
	reg   [7:0] t;
	begin
		if      (ch >= "0" && ch <= "9") t = ch - "0";
		else if (ch >= "a" && ch <= "f") t = ch - "a" + 8'd10;
		else if (ch >= "A" && ch <= "F") t = ch - "A" + 8'd10;
		else                             t = 8'hFF;
		hexv = t[3:0];            // 8'hFF -> 4'hF = invalid marker
	end
endfunction

// parse the accumulated ASCII line into one code pair word
task parse_line;
	reg [31:0] w0, w1;
	reg  [3:0] nib;
	reg        ok;
	integer    k;
	begin
		// line[0..7] = first word; line[8] = ' '; line[9..16] = second
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
					if (!ok) w1 = 32'h1000_0000; // malformed -> ignore
				end else
					w1 = 32'h1000_0000;          // lone word -> ignore

				if (!have_d1) begin
					d1      <= w0;
					have_d1 <= 1'b1;
				end else begin
					if (c_count < 7'd12) begin
						c_addr[c_count]  <= d1;
						c_valid[c_count] <= 1'b1;
						if (w1[31:28] == 4'h0) begin
							c_data[c_count] <= {16'h0000, w1[15:0]};
							c_type[c_count] <= 3'd1;      // set
						end else if (w1[31:28] == 4'h1) begin
							c_data[c_count] <= {28'h0, w1[23:20]};
							c_type[c_count] <= 3'd2;      // inc
						end else if (w1[31:28] == 4'h2) begin
							c_data[c_count] <= {28'h0, w1[23:20]};
							c_type[c_count] <= 3'd3;      // dec
						end else if (w1[31:28] == 4'h3) begin
							c_data[c_count] <= {16'h0000, w1[15:0]};
							c_type[c_count] <= 3'd4;      // or
						end else begin
							c_type[c_count] <= 3'd0;      // ignore/IF/D2..
						end
						if (w1 == 32'hD200_0000)
							c_count <= 7'd12;             // page closed
						else
							c_count <= c_count + 7'd1;
					end
					have_d1 <= 1'b0;
				end
			end else
				have_d1 <= 1'b0;
		end
		line_len <= 6'd0;
		in_digit <= 1'b0;
	end
endtask

always @(posedge clk) begin
	if (reset) begin
		line_len <= 6'd0;
		in_digit <= 1'b0;
		have_d1  <= 1'b0;
		c_count  <= 7'd0;
		for (i = 0; i < 128; i = i + 1) c_valid[i] <= 1'b0;
	end else if (f2_wr) begin
		if (f2_dout == "\n" || f2_last) begin
			parse_line;
		end else if (f2_dout != "\r" && line_len < 6'd40) begin
			if (f2_dout >= "0" && f2_dout <= "9") in_digit <= 1'b1;
			line[line_len] <= f2_dout;
			line_len <= line_len + 6'd1;
		end
	end
end

//------------------------------------------------------------------
// Runtime compare/patch (single cycle)
//------------------------------------------------------------------
integer j;
always @(*) begin
	hit   = 1'b0;
	patch = chk_data;
	if (chk_en) begin
		for (j = 0; j < 12; j = j + 1) begin
			if (c_valid[j] && c_addr[j] == chk_addr) begin
				case (c_type[j])
				3'd1: begin hit = 1'b1; patch = c_data[j][15:0]; end
				3'd2: begin hit = 1'b1; patch = chk_data + {8'h00, c_data[j][7:0]}; end
				3'd3: begin hit = 1'b1; patch = chk_data - {8'h00, c_data[j][7:0]}; end
				3'd4: begin hit = 1'b1; patch = chk_data | c_data[j][15:0]; end
				default: ;
				endcase
			end
		end
	end
end

endmodule
