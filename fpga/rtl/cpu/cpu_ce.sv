//============================================================================
// NDS MiSTer Test — CPU clock enables
//
// The DS clocks the ARM9 at 67.0274 MHz and the ARM7 at 33.513982 MHz — a 2:1
// ratio, and the ratio is what the software depends on: the ARM7 does the
// I/O, the sound and the DMA while the ARM9 runs the game, and a game that
// finds the ARM7 twice as fast as it should be finds its handshakes twice as
// fast too. clk_sys *is* the ARM9's 67.0274 MHz (the PLL in NDS.sv), so in
// Normal mode the ARM9 runs on every cycle at its nominal rate and the ARM7
// on every second one at exactly half of it — the pattern is the hardware's
// ratio, not a scale factor:
//
//   Normal     ARM9 every clk_sys cycle, ARM7 every second one (the DS's 2:1)
//   ARM7 x2    both every cycle — the ARM7 at the ARM9's rate, for the
//              ARM7-bound titles the OSD row exists for
//   ARM7 x4    the ARM7 every cycle and the ARM9 every second one: the same
//              2:1 pattern the other way up (the only way a fixed clk_sys can
//              give the ARM7 *more* cycles than the ARM9)
//
// Both rates are therefore nominal — 67.0274 MHz for the ARM9 and 33.513982
// for the ARM7 — with no scale factor anywhere in the CPU domain. (Before the
// PLL landed this ran from CLK_50M and both cores were 0.746 of nominal; and
// before *this* module existed both ran on every cycle, giving them a 1:1
// ratio, i.e. the ARM7 at the ARM9's rate, which was the original bug.)
//
// Everything clocked by that 33.513982 MHz domain follows it, not just the
// core: the timers count `ce7` (they are a divider of it, GBATEK gives that F
// for both CPUs) and the DMA engine advances on it, so their rates stay in the
// DS's ratio to the CPU under every mode above. The video, audio and SDRAM
// paths keep their absolute rates (59.826 Hz frames, 48 kHz samples), and so
// does the RTC's own crystal: they are not CPU-domain hardware.
//============================================================================
module cpu_ce (
	input        clk,
	input  [1:0] mode,      // OSD "CPU overclock": 0 Normal, 1 ARM7 x2, 2 ARM7 x4
	output reg   ce9,
	output reg   ce7
);

// The half-rate phase. It free-runs — deliberately: it is a clock pattern,
// not machine state, and holding it while a core is reset would leave that
// core with no enables at all (which is exactly what the bench caught). Its
// starting phase is irrelevant, because both cores' enables are derived from
// the same phase, so the ratio holds whichever edge it comes up on.
reg ph = 1'b0;

always @(posedge clk) ph <= ~ph;

always @(*) begin
	case (mode)
	2'd1:    begin ce9 = 1'b1; ce7 = 1'b1; end   // ARM7 x2
	2'd2:    begin ce9 = ph;   ce7 = 1'b1; end   // ARM7 x4
	default: begin ce9 = 1'b1; ce7 = ph;   end   // Normal: the DS's 2:1
	endcase
end

endmodule
