//============================================================================
// NDS MiSTer Test — video timing generator
//
// Produces the scan structure for the composed 256x384 frame (top screen
// stacked over bottom). The 12.5 MHz pixel CE is derived from the 50 MHz
// clock (removed with the PLL in M3, which will also add the
// 67.02/33.51 MHz CPU clocks).
//
// The OSD "Refresh rate" option selects one of three modes by changing
// the frame totals; the active area stays 256x384 in all of them:
//
//   mode    H_TOTAL  V_TOTAL  rate (12.5e6 / (H*V))   error vs target
//   native    320      653    59.8201 Hz (DS 59.8261)  -100 ppm
//   59.95     332      628    59.9532 Hz               +53 ppm
//   60.00     320      651    60.0038 Hz               +63 ppm
//
// H_FRONT/H_SYNC and V_FRONT/V_SYNC stay fixed across modes; the tail of
// each blanking interval absorbs the difference, so sync polarity and
// width never change and the HDMI scaler re-locks cleanly.
//============================================================================
module video_timing (
	input            clk,
	input            ce,       // optional external enable on the CE divider
	output           pixel_ce, // derived 12.5 MHz pixel enable
	input            reset,

	input      [8:0] h_total,  // OSD-selected line length
	input     [9:0]  v_total,  // OSD-selected frame height (incl. blanking)

	output reg [8:0] x,
	output reg [8:0] y,
	output reg       de,
	output reg       hs,
	output reg       vs,
	output           frame_start
);

localparam H_ACTIVE = 256;
localparam H_FRONT  = 8;
localparam H_SYNC   = 32;
localparam V_ACTIVE = 384;
localparam V_FRONT  = 24;
localparam V_SYNC   = 4;

// Derive the 12.5 MHz pixel CE from a 50 MHz clock while the core still
// runs on a single domain. Removed with the PLL in M3.
reg [1:0] ce_div = 0;
wire pix_ce = ce ? (ce_div == 2'd2) : 1'b0; // single-cycle enable, 1-in-4
assign pixel_ce = pix_ce;
always @(posedge clk) begin
	if (reset) ce_div <= 0;
	else       ce_div <= ce_div + 1'd1;
end

reg [8:0] h_cnt = 0;
reg [9:0] v_cnt = 0;

always @(posedge clk) begin
	if (reset) begin
		h_cnt <= 0;
		v_cnt <= 0;
	end else if (pix_ce) begin
		if (h_cnt == h_total - 1'd1) begin
			h_cnt <= 0;
			v_cnt <= (v_cnt == v_total - 1'd1) ? 10'd0 : v_cnt + 1'd1;
		end else begin
			h_cnt <= h_cnt + 1'd1;
		end
	end
end

wire h_active = (h_cnt < H_ACTIVE);
wire v_active = (v_cnt < V_ACTIVE);

always @(posedge clk) begin
	if (reset) begin
		x  <= 0;
		y  <= 0;
		de <= 0;
		hs <= 0;
		vs <= 0;
	end else if (pix_ce) begin
		x  <= h_active ? h_cnt : 9'd0;
		y  <= v_active ? v_cnt[8:0] : 9'd0;
		de <= h_active & v_active;
		hs <= (h_cnt >= H_ACTIVE + H_FRONT) && (h_cnt < H_ACTIVE + H_FRONT + H_SYNC);
		vs <= (v_cnt >= V_ACTIVE + V_FRONT) && (v_cnt < V_ACTIVE + V_FRONT + V_SYNC);
	end
end

// First active pixel of a frame — resets the CPU pipeline and paces the
// SPU mix at the frame rate.
assign frame_start = pix_ce && (h_cnt == 0) && (v_cnt == 0);

endmodule
