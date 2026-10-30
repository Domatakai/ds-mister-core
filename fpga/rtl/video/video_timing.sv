//============================================================================
// NDS MiSTer Test — video timing generator
//
// Produces the scan structure for the composed 256x384 frame (top screen
// stacked over bottom). The pixel CE is clk_sys / 5: from the DS's own
// 67.0274 MHz that is 13.40548 MHz, which is the rate the frame totals below
// are worked out against. (The core clock is the 67.0274 MHz PLL output; the
// ARM7's 33.513982 MHz and the pixel enable are both enables off it.)
//
// The OSD "Refresh rate" option selects one of three modes by changing
// the frame totals; the active area stays 256x384 in all of them:
//
//   mode    H_TOTAL  V_TOTAL  rate (13.40548e6 / (H*V))  error vs target
//   native    330      679    59.8272 Hz (DS 59.8261)     +18 ppm
//   59.95     344      650    59.9530 Hz                  +49 ppm
//   60.00     331      675    59.9999 Hz                   -2 ppm
//
// H_FRONT/H_SYNC and V_FRONT/V_SYNC stay fixed across modes; the tail of
// each blanking interval absorbs the difference, so sync polarity and
// width never change and the HDMI scaler re-locks cleanly.
//============================================================================
module video_timing (
	input            clk,
	input            ce,       // optional external enable on the CE divider
	output           pixel_ce, // derived 13.40548 MHz pixel enable (clk/5)
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

// 1-in-5 single-cycle enable: 67.0274 / 5 = 13.40548 MHz.
reg [2:0] ce_div = 0;
wire pix_ce = ce ? (ce_div == 3'd4) : 1'b0;
assign pixel_ce = pix_ce;
always @(posedge clk) begin
	if (reset)                                    ce_div <= 0;
	else if (ce_div == 3'd4)                      ce_div <= 0;
	else                                          ce_div <= ce_div + 3'd1;
end

reg [8:0] h_cnt = 0;
reg [9:0] v_cnt = 0;

always @(posedge clk) begin
	if (reset) begin
		h_cnt <= 0;
		v_cnt <= 0;
	end else if (pix_ce) begin
		// >= so an OSD refresh switch that shortens the totals mid-frame
		// re-locks on the next boundary instead of counting to 2^N-1
		if (h_cnt >= h_total - 1'd1) begin
			h_cnt <= 0;
			v_cnt <= (v_cnt >= v_total - 1'd1) ? 10'd0 : v_cnt + 1'd1;
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
