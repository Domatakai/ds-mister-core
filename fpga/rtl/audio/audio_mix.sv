//============================================================================
// NDS MiSTer Test — audio mixer for the MT-32-pi return path
//
// MT-32-pi sends its synthesis back as an I2S stream on USER_IN, which
// sys/mt32pi.sv recovers into 16-bit L/R words in the audio clock domain.
// This module sums that with the core's own output and drives AUDIO_L/R.
//
// It runs on CLK_AUDIO (24.576 MHz) because that is where the MT-32-pi
// samples live; CLK_AUDIO/512 is exactly 48 kHz, so the mixer tick is a
// free-running divide rather than a strobe from the video domain. The SPU
// side is sampled on that tick (it changes once per frame today), which
// removes the need for a rate converter until the SPU gets a real sample
// clock in M4.
//
// MIDI volume is its own OSD row: the DS master volume must not drag the
// external synthesiser down with it, and 0% is a clean mute (MT-32-pi keeps
// running, the mix just ignores it).
//============================================================================
module audio_mix (
	input             clk_audio,      // 24.576 MHz
	input             reset,
	input      [15:0] spu_l,
	input      [15:0] spu_r,
	input      [15:0] mt32_l,
	input      [15:0] mt32_r,
	input             mt32_en,
	input      [2:0]  mt32_vol,       // 0..7 -> 0%..100%
	output reg [15:0] out_l,
	output reg [15:0] out_r
);

	// 24.576 MHz / 512 = 48.000 kHz
	reg [8:0] div = 9'd0;
	reg       tick_48k = 1'b0;
	always @(posedge clk_audio) begin
		if (reset) begin
			div      <= 9'd0;
			tick_48k <= 1'b0;
		end else begin
			div      <= div + 9'd1;
			tick_48k <= (div == 9'd511);
		end
	end

	// gain: 36 per step -> 252/256 at full scale, so the sum cannot clip on
	// its own and 0 shuts the return path off completely
	wire [8:0] gain = mt32_vol * 9'd36;

	// the SPU side crosses from clk_sys; a two-flop settle per bit is enough
	// for a value that only changes at 59.8 Hz
	reg [15:0] spu_l_s1, spu_l_s2, spu_r_s1, spu_r_s2;
	always @(posedge clk_audio) begin
		spu_l_s1 <= spu_l; spu_l_s2 <= spu_l_s1;
		spu_r_s1 <= spu_r; spu_r_s2 <= spu_r_s1;
	end

	function [15:0] sat16;
		input signed [24:0] v;
		begin
			if (v > 25'sd32767)       sat16 = 16'h7FFF;
			else if (v < -25'sd32768) sat16 = 16'h8000;
			else                      sat16 = v[15:0];
		end
	endfunction

	wire signed [15:0] sl = $signed(spu_l_s2);
	wire signed [15:0] sr = $signed(spu_r_s2);

	// 16-bit sample x 9-bit gain, arithmetic-shifted back down. The shift is
	// done on the signed product, so a negative sample floors rather than
	// turning into a large positive one.
	wire signed [23:0] ml = $signed(mt32_l) * $signed({1'b0, gain});
	wire signed [23:0] mr = $signed(mt32_r) * $signed({1'b0, gain});
	wire signed [23:0] gl = mt32_en ? (ml >>> 8) : 24'sd0;
	wire signed [23:0] gr = mt32_en ? (mr >>> 8) : 24'sd0;

	wire signed [24:0] sum_l = $signed({{9{sl[15]}}, sl}) + $signed({gl[23], gl});
	wire signed [24:0] sum_r = $signed({{9{sr[15]}}, sr}) + $signed({gr[23], gr});

	always @(posedge clk_audio) begin
		if (reset) begin
			out_l <= 16'h0000;
			out_r <= 16'h0000;
		end else if (tick_48k) begin
			out_l <= sat16(sum_l);
			out_r <= sat16(sum_r);
		end
	end

endmodule
