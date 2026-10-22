//============================================================================
// NDS MiSTer Test — spatial video filter
//
// Runs at the pixel CE (12.5 MHz) on the composed RGB555 stream with a
// one-line buffer. Total latency is exactly one CE: rgb_o for position
// (x,y) appears one CE after the input, and de/hs/vs are delayed by the
// same one CE so alignment never shifts. Neighbour taps at the first
// column/row fold to the centre pixel (no wrap-around smear).
//
//   0 Off      identity (still pipelined — sync delay is constant)
//   1 Soft     5/8 centre + 1/8 each of right, below, diagonal
//   2 Smooth   true 2x2 bilinear average (centre, right, below, diagonal)
//   3 Sharp    unsharp: centre + (centre - 2x2 average), clamped
//============================================================================
module video_filter (
	input            clk,
	input            ce,        // pixel clock enable
	input      [2:0] mode,
	input      [8:0] x,
	input      [8:0] y,
	input            de,
	input            hs,
	input            vs,
	input     [15:0] rgb_in,

	output reg [15:0] rgb_o,
	output reg        de_o,
	output reg        hs_o,
	output reg        vs_o
);

reg [15:0] linebuf [0:511];

// stage 1: input sampling + neighbourhood capture
reg [15:0] cur    = 0;   // pixel at (x,   y)
reg [15:0] h_prev = 0;   // pixel at (x-1, y)
reg [15:0] v_line = 0;   // pixel at (x,   y-1)
reg [15:0] v_pl   = 0;   // pixel at (x-1, y-1)
reg        m_s1   = 0;   // bit 15 delayed with the pixel
reg  [8:0] xb = 0, yb = 0;
reg        de_b = 0, hs_b = 0, vs_b = 0;

always @(posedge clk) begin
	if (ce) begin
		cur    <= rgb_in;
		h_prev <= cur;
		v_line <= linebuf[x];          // old line, read-before-write
		v_pl   <= v_line;
		m_s1   <= rgb_in[15];
		xb <= x;  yb <= y;
		de_b <= de; hs_b <= hs; vs_b <= vs;
		if (de) linebuf[x] <= rgb_in;
	end
end

// stage 2: blend + sync delay
function [4:0] fchan;
	input [4:0] c, h, v, p;
	input [2:0] m;
	reg   [7:0] sm;      // c+h+v+p   (max 124)
	reg   [8:0] s9;      // 5c+h+v+p  (max 248)
	reg signed [9:0] s;
	begin
		sm = {3'b000, c} + {3'b000, h} + {3'b000, v} + {3'b000, p};
		s9 = c * 9'd5 + {4'b0000, h} + {4'b0000, v} + {4'b0000, p};
		case (m)
		3'd1: fchan = s9[7:3];              // (5c + h + v + p) / 8
		3'd2: fchan = sm[6:2];              // (c + h + v + p) / 4
		3'd3: begin                         // 2c - avg, clamped
			s = {4'b0000, c, 1'b0} - {5'b00000, sm[6:2]};
			fchan = (s < 0) ? 5'd0 : (s > 10'sd31) ? 5'd31 : s[4:0];
		end
		default: fchan = c;
		endcase
	end
endfunction

// edge folding: no neighbour past the first column / first row
wire [4:0] c_r = cur[14:10], c_g = cur[9:5],  c_b = cur[4:0];
wire [4:0] h_r = (xb == 0) ? cur[14:10] : h_prev[14:10];
wire [4:0] h_g = (xb == 0) ? cur[9:5]   : h_prev[9:5];
wire [4:0] h_b = (xb == 0) ? cur[4:0]   : h_prev[4:0];
wire [4:0] v_r = (yb == 0) ? cur[14:10] : v_line[14:10];
wire [4:0] v_g = (yb == 0) ? cur[9:5]   : v_line[9:5];
wire [4:0] v_b = (yb == 0) ? cur[4:0]   : v_line[4:0];
wire [4:0] p_r = (xb == 0 || yb == 0) ? cur[14:10] : v_pl[14:10];
wire [4:0] p_g = (xb == 0 || yb == 0) ? cur[9:5]   : v_pl[9:5];
wire [4:0] p_b = (xb == 0 || yb == 0) ? cur[4:0]   : v_pl[4:0];

always @(posedge clk) begin
	if (ce) begin
		rgb_o <= {m_s1,
		          fchan(c_r, h_r, v_r, p_r, mode),
		          fchan(c_g, h_g, v_g, p_g, mode),
		          fchan(c_b, h_b, v_b, p_b, mode)};
		de_o <= de_b;
		hs_o <= hs_b;
		vs_o <= vs_b;
	end
end

endmodule
