//============================================================================
// NDS MiSTer Test — video timing generator
//
// Produces the scan structure for the composed frame. The OSD "Video output"
// row picks one of four modes; the pixel CE, active window and sync widths all
// move with it, and every mode lands on 59.8261 Hz so the emulation runs at
// the DS's own frame rate whichever output is in use.
//
//   vmode  mode                     active    CE   point rate    line rate
//     0    HDMI 256x384 stacked     256x384   /5   13.40548 MHz  totals below
//     1    CRT 240p side by side    512x240   /6   11.17123 MHz  15.734 kHz
//     2    CRT 240p single screen   256x240   /10   6.70274 MHz  15.734 kHz
//     3    CRT 31 kHz               256x384   /5   13.40548 MHz  31.468 kHz
//
// In modes 1 and 2 the 192-line picture sits centred in 240 active lines and
// the composer paints the 24-line bands above and below black. Mode 1 puts the
// two screens side by side at native width (256 pixels each) so both are on
// screen at once; mode 2 shows one screen at a time.
//
// HDMI totals come from the OSD "Refresh rate" row:
//   native  330 x 679 -> 59.8272 Hz (DS native is 59.8261, +18 ppm)
//   59.95   344 x 650 -> 59.9530 Hz
//   60.00   331 x 675 -> 59.9999 Hz
// CRT totals are fixed, because a 15 kHz standard has no equivalent choice:
//   mode 1  710 x 263 at /6  -> 59.8261 Hz
//   mode 2  426 x 263 at /10 -> 59.8270 Hz
//   mode 3  426 x 526 at /5  -> 59.8261 Hz
//
// hsync widths are chosen to land in the standard windows at each point rate
// (about 4.7 us at 6.7 and 11.2 MHz, 3.6 us at 13.4); the tail of each
// blanking interval absorbs the rest, so sync polarity and width never change
// within a mode.
//============================================================================
module video_timing (
	input            clk,
	input            ce,       // optional external enable on the CE divider
	output           pixel_ce, // derived pixel enable (clk/N, N by mode)
	input            reset,

	input      [1:0] vmode,    // 0 HDMI, 1 CRT 240p side by side, 2 CRT 240p
	                           // single, 3 CRT 31 kHz
	input      [9:0] h_total,  // line length (OSD-selected in mode 0)
	input      [9:0] v_total,  // frame height incl. blanking (mode 0)

	output reg [8:0] x,
	output reg [8:0] y,
	output reg       de,
	output reg       hs,
	output reg       vs,
	output           frame_start
);

wire [9:0] h_act = (vmode == 2'd1) ? 10'd512 : 10'd256;
wire [9:0] v_act = (vmode == 2'd0 || vmode == 2'd3) ? 10'd384 : 10'd240;

// Sync windows as absolute counts instead of act+front+width sums, so both
// comparators see a constant and no adder sits in the sync path. These are
// the same edges the sums produced:
//   mode 0  hs 264..296 (32), vs 408..412 (4)
//   mode 1  hs 552..604 (52), vs 244..247 (3)
//   mode 2  hs 280..312 (32), vs 244..247 (3)
//   mode 3  hs 272..320 (48), vs 388..391 (3)
wire [9:0] hs_beg = (vmode == 2'd1) ? 10'd552 : (vmode == 2'd2) ? 10'd280 :
                    (vmode == 2'd3) ? 10'd272 : 10'd264;
wire [9:0] hs_end = (vmode == 2'd1) ? 10'd604 : (vmode == 2'd2) ? 10'd312 :
                    (vmode == 2'd3) ? 10'd320 : 10'd296;
wire [9:0] vs_beg = (vmode == 2'd0) ? 10'd408 : (vmode == 2'd3) ? 10'd388 : 10'd244;
wire [9:0] vs_end = (vmode == 2'd0) ? 10'd412 : (vmode == 2'd3) ? 10'd391 : 10'd247;

// Single-cycle enable on the last count: 67.0274/5 = 13.40548 MHz,
// /6 = 11.17123 MHz, /10 = 6.70274 MHz. >= rather than == so an OSD mode
// change that shortens the divider re-locks instead of stalling.
wire [3:0] ce_max = (vmode == 2'd1) ? 4'd5 : (vmode == 2'd2) ? 4'd9 : 4'd4;
reg  [3:0] ce_div = 0;
wire pix_ce = ce ? (ce_div == ce_max) : 1'b0;
assign pixel_ce = pix_ce;
always @(posedge clk) begin
	if (reset)                 ce_div <= 0;
	else if (ce_div >= ce_max) ce_div <= 0;
	else                       ce_div <= ce_div + 4'd1;
end

reg [9:0] h_cnt = 0;
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

wire h_active = (h_cnt < h_act);
wire v_active = (v_cnt < v_act);

always @(posedge clk) begin
	if (reset) begin
		x  <= 0;
		y  <= 0;
		de <= 0;
		hs <= 0;
		vs <= 0;
	end else if (pix_ce) begin
		x  <= h_active ? h_cnt[8:0] : 9'd0;
		y  <= v_active ? v_cnt[8:0] : 9'd0;
		de <= h_active & v_active;
		hs <= (h_cnt >= hs_beg) && (h_cnt < hs_end);
		vs <= (v_cnt >= vs_beg) && (v_cnt < vs_end);
	end
end

// First active pixel of a frame — resets the CPU pipeline and paces the
// SPU mix at the frame rate.
assign frame_start = pix_ce && (h_cnt == 0) && (v_cnt == 0);

endmodule
