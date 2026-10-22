//============================================================================
// NDS MiSTer Test — audio filter (EQ presets + stereo width)
//
// Runs in the core clock domain on the sample strobe (frame_start until
// the M4 I2S framing gives it a true sample tick — the coefficients are
// rate-relative one-poles, so the shape holds either way).
//
// EQ (per channel, signed, saturating):
//   0 Off     pass-through
//   1 Warm    one-pole low-pass (darker, gentle)
//   2 Bright  input + high-pass content (x + (x - lp))
//   3 Bass    input + half the low band (x + lp/2)
//
// Stereo width (mid/side, applied after the EQ):
//   0 Off     exact pass-through (integer m/s would round)
//   1 Soft    side x1.25
//   2 Strong  side x1.5
//   3 reserved = Off
//============================================================================
module audio_filter (
	input            clk,
	input            reset,
	input            strobe,     // sample tick
	input      [1:0] mode,       // EQ preset
	input      [1:0] width,      // stereo width
	input     [15:0] in_l,
	input     [15:0] in_r,
	output reg [15:0] out_l,
	output reg [15:0] out_r
);

function [15:0] sat16;
	input signed [18:0] v;
	begin
		if (v > 19'sd32767)       sat16 = 16'h7FFF;
		else if (v < -19'sd32768) sat16 = 16'h8000;
		else                      sat16 = v[15:0];
	end
endfunction

// datapath is 18-bit signed end to end; inputs sign-extended once.
wire signed [17:0] xl = {{2{in_l[15]}}, in_l};
wire signed [17:0] xr = {{2{in_r[15]}}, in_r};

// one-pole LP state (k = 1/8 per sample)
reg signed [17:0] lp_l = 0, lp_r = 0;
wire signed [17:0] nl = lp_l + ((xl - lp_l) >>> 3);
wire signed [17:0] nr = lp_r + ((xr - lp_r) >>> 3);

// EQ result for this sample
reg signed [17:0] el, er;
always @(*) begin
	case (mode)
	2'd1:    begin el = nl;              er = nr;              end
	2'd2:    begin el = xl + (xl - nl);  er = xr + (xr - nr);  end
	2'd3:    begin el = xl + (nl >>> 1); er = xr + (nr >>> 1); end
	default: begin el = xl;              er = xr;              end
	endcase
end

// mid/side width (19-bit headroom: |el+er| can reach ~196k)
reg signed [18:0] m_w, s_w, sl, sr;
always @(*) begin
	m_w = $signed({el[17], el} + {er[17], er}) >>> 1;
	s_w = $signed({el[17], el} - {er[17], er}) >>> 1;
	if      (width == 2'd1) s_w = s_w + (s_w >>> 2);  // 1.25x
	else if (width == 2'd2) s_w = s_w + (s_w >>> 1);  // 1.5x

	if (width == 2'd0) begin                          // exact bypass
		sl = {el[17], el};
		sr = {er[17], er};
	end else begin
		sl = m_w + s_w;
		sr = m_w - s_w;
	end
end

always @(posedge clk) begin
	if (reset) begin
		lp_l <= 0; lp_r <= 0;
		out_l <= 0; out_r <= 0;
	end else if (strobe) begin
		lp_l <= nl;
		lp_r <= nr;
		out_l <= sat16(sl);
		out_r <= sat16(sr);
	end
end

endmodule
