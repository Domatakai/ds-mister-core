//============================================================================
// NDS MiSTer Test — microphone ADC front end
//
// The DS microphone is an analog input: the ARM7 reads it through the
// touchscreen controller's AUX channel as a 12-bit value. MiSTer's HPS has no
// audio capture at all, so an external microphone can only come in through the
// board's LTC2308 (the converter the framework also carries for paddles).
//
// One channel at 48 kHz — the DS's own output rate — from CLK_50M, because
// ltc2308 derives its conversion timing from CLK_RATE/625 kHz. The sample is
// moved into clk_sys by synchronizing the converter's once-per-conversion
// toggle and latching the data on that edge: `dout` changes at the end of a
// conversion and the next one starts by flipping the toggle, so the word is
// stable for a whole sample period when it is read. The result is one sample
// (20.8 us) behind the microphone, which no DS game can see.
//============================================================================
module mic_adc #(
	parameter CLK_RATE    = 50_000_000,
	parameter SAMPLE_RATE = 48_000
) (
	input             clk_adc,     // CLK_50M, the converter's clock
	input             reset_adc,   // synchronous, clk_adc domain
	inout      [3:0]  ADC_BUS,     // {SCK, SDO, SDI, CONVST}

	input             clk,         // clk_sys
	input             reset,
	output            sample_tick, // one cycle per conversion, clk_sys
	output reg [11:0] sample       // 0..4095, mid-scale when silent
);

	wire [11:0] adc_dout;
	wire        adc_sync;

	ltc2308 #(.NUM_CH(1), .ADC_RATE(SAMPLE_RATE), .CLK_RATE(CLK_RATE)) adc (
		.reset(reset_adc),
		.clk(clk_adc),
		.ADC_BUS(ADC_BUS),
		.dout_sync(adc_sync),
		.dout(adc_dout)
	);

	// adc_sync flips once per conversion; the flop pair is the crossing and
	// bit 2 detects the edge in clk_sys.
	reg [2:0] sync_sr = 3'b000;
	always @(posedge clk) begin
		if (reset) sync_sr <= 3'b000;
		else       sync_sr <= {sync_sr[1:0], adc_sync};
	end

	assign sample_tick = sync_sr[2] ^ sync_sr[1];

	always @(posedge clk) begin
		if (reset)            sample <= 12'h400;
		else if (sample_tick) sample <= adc_dout;
	end

endmodule
