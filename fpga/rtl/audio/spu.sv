//============================================================================
// NDS MiSTer Test — sound processing unit (SPU) — STUB (milestone M4)
//
// The DS mixes 16 hardware channels (8 ADPCM + 8 PCM/capture) with
// panning, a master volume, and an explicit hardware volume sweep,
// clocked by the ARM7 at 33.51 MHz and framed out over I2S.
//
// This stub keeps the sample framing correct — one stereo frame per
// DS refresh (59.8261 Hz) with the OSD master volume applied — so the
// audio path through the framework is proven before channels exist.
//============================================================================
module spu (
	input            clk,        // core clock
	input            clk_audio,  // 24.576 MHz I2S domain from the framework
	input            reset,
	input      [3:0] volume,     // OSD: 0..10 -> 0%..100%
	input      [1:0] mix_mode,
	input            frame_start,
	output reg [15:0] audio_l,
	output reg [15:0] audio_r
);

// 0..10 mapped to a 0..256 gain (10 -> 250 ~= unity at the I2S DAC)
wire [8:0] vol_gain = (volume > 4'd10) ? 9'd256 : volume * 9'd25;

// Channel accumulator — silence until the channel engines land.
reg [18:0] mix_acc_l = 0;
reg [18:0] mix_acc_r = 0;

always @(posedge clk) begin
	if (reset) begin
		mix_acc_l <= 0;
		mix_acc_r <= 0;
	end else if (frame_start) begin
		// unsigned mix scaled by master volume; channels land in M4
		audio_l <= (mix_acc_l[15:0] * vol_gain) >> 8;
		audio_r <= (mix_acc_r[15:0] * vol_gain) >> 8;
		mix_acc_l <= 0;
		mix_acc_r <= 0;
	end
end

wire _unused = &{1'b0, clk_audio, mix_mode};

endmodule
