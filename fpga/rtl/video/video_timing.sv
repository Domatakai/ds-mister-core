//============================================================================
// NDS MiSTer Test — video timing generator
//
// Produces the scan structure for the composed frame. The default
// parameters give a 256x384 frame (top screen stacked over bottom) with
// an active picture rate of 59.8269 Hz from a 12.5 MHz pixel CE — the
// Nintendo DS refreshes at 59.8261 Hz, so drift is one frame per ~16 min.
//
//   H_TOTAL = 256 + 8 + 32 + 24  = 320
//   V_TOTAL = 384 + 24 + 4 + 241  = 653
//   rate    = 12.5e6 / (320 * 653) = 59.8201 Hz
//
// The 12.5 MHz CE itself is produced here (clk_sys / 4) until the PLL
// lands in M3, which will also provide the 67.02/33.51 MHz CPU clocks.
//============================================================================
module video_timing #(
	parameter H_ACTIVE = 256,
	parameter H_FRONT  = 8,
	parameter H_SYNC   = 32,
	parameter H_BACK   = 24,
	parameter V_ACTIVE = 384,
	parameter V_FRONT  = 24,
	parameter V_SYNC   = 4,	parameter V_BACK  = 241
) (
	input            clk,
	input            ce,       // optional external enable on the CE divider
	output           pixel_ce, // derived 12.5 MHz pixel enable
	input            reset,
	output reg [8:0] x,
	output reg [8:0] y,
	output reg       de,
	output reg       hs,
	output reg       vs,
	output           frame_start
);

localparam H_TOTAL = H_ACTIVE + H_FRONT + H_SYNC + H_BACK;
localparam V_TOTAL = V_ACTIVE + V_FRONT + V_SYNC + V_BACK;

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
		if (h_cnt == H_TOTAL - 1) begin
			h_cnt <= 0;
			v_cnt <= (v_cnt == V_TOTAL - 1) ? 10'd0 : v_cnt + 1'd1;
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
// SPU mix at the DS's native frame rate.
assign frame_start = pix_ce && (h_cnt == 0) && (v_cnt == 0);

endmodule
