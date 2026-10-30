//============================================================================
// NDS MiSTer Test — MT-32-pi selection
//
// The Pi chooses what it boots into from a request the core presents over
// I2C: mode (MT-32 emulation or SoundFont playback), the control ROM, and —
// in SoundFont mode — which of its soundfonts on the SD card to load. See
// sys/mt32pi.sv for the wire side: mode request 0xA1 = MT-32, 0xA2 =
// SoundFont, and the third byte of the reply carries the soundfont index.
//
// Two things the OSD needs that a plain status bit cannot do:
//
//   * the index has to be a value, not a toggle: `sf_index` is the raw bank
//     number the Pi looks up.
//   * the Pi reads the request once, when it starts, and a request made
//     after that is never seen. So when the selection changes the core has
//     to make the Pi look again. Pulsing this module's `restart` into
//     mt32pi's reset does exactly that: the slave answers 0xA0 (reload) to
//     the next read, then the new mode and index. Without it, changing
//     "MT-32-pi synth" mid-session would do nothing at all.
//
// `restart` is held for RST_HOLD clocks and drops on its own, so the Pi has
// time to notice the reset whether it polls the bus or waits for it.
// Changing the soundfont bank while MT-32 emulation is active is not worth a
// reload: the index is ignored until SoundFont mode is asked for.
//============================================================================
module mt32_select #(
	parameter integer RST_HOLD = 2048   // clocks the reload request is held
)(
	input         clk,
	input         reset,
	input  [2:0]  sf_bank,     // OSD: which soundfont the Pi should load
	input         synth,       // OSD: 0 = MT-32, 1 = SoundFont

	output        mode_sf,     // -> mt32pi.mt32_mode_req
	output [7:0]  sf_index,    // -> mt32pi.mt32_sf_req
	output        restart      // -> mt32pi.reset (with the core reset)
);

	assign mode_sf  = synth;
	assign sf_index = {5'd0, sf_bank};

	// selection as it was when the Pi last read it
	reg       synth_d = 1'b0;
	reg [2:0] bank_d  = 3'd0;
	reg [31:0] hold   = 32'd0;

	wire changed = (synth != synth_d) || (synth && (sf_bank != bank_d));

	always @(posedge clk) begin
		if (reset) begin
			synth_d <= 1'b0;
			bank_d  <= 3'd0;
			hold    <= 32'd0;
		end else begin
			// latch what the Pi is now running
			synth_d <= synth;
			bank_d  <= sf_bank;

			if (changed)                    hold <= RST_HOLD;
			else if (hold != 32'd0)         hold <= hold - 32'd1;
		end
	end

	assign restart = (hold != 32'd0);

endmodule
