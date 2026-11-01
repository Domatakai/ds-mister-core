//============================================================================
// NDS MiSTer Test — per-game CPU overclock reference
//
// The OSD's "CPU overclock" row sets the ARM9/ARM7 clock-enable pattern by
// hand. Auto mode does it per game instead: the four-character game code in
// the loaded cartridge's header (bytes 0x0C..0x0F, e.g. "AMCE") is looked up
// here and the mode that reference gives it drives `cpu_ce` -- so a title that
// wants the ARM7 lifted gets it from the load, with nothing to set first.
//
// The key is read straight from the cart slot, which means it is correct the
// moment a game is booted, after a core reset, and again after the boot menu
// switches slots: the mode always belongs to the game the window can see. No
// latch is needed, and none could survive the reset that a boot performs.
//
// The table is a tuning reference, not a measurement. A code listed here is a
// deliberate decision about that title; anything not listed runs Normal. Each
// entry costs one 32-bit compare and no memory, so the table is cheap to grow.
//
// The game code rather than the title is the key because regional variants
// share a title and not a code -- the same reason the boot menu shows both.
//============================================================================
module oc_lookup (
	input      [1:0] manual,      // OSD "CPU overclock"
	input            auto_on,     // OSD "Auto overclock"
	input     [31:0] code,        // game code of the loaded ROM's header
	output     [1:0] mode
);

localparam [1:0] OC_NORMAL  = 2'd0,   // the DS's own 2:1 ARM9:ARM7 ratio
                 OC_ARM7_X2 = 2'd1,   // both cores every cycle
                 OC_ARM7_X4 = 2'd2;   // ARM7 every cycle, ARM9 every second

// The reference. "AMCE" is the code the cart bench loads, so the bench
// exercises a real entry rather than a made-up one; add a line per title.
function automatic [1:0] ref_mode (input [31:0] c);
	case (c)
	32'h414D4345: ref_mode = OC_ARM7_X2;   // "AMCE"
	default:      ref_mode = OC_NORMAL;
	endcase
endfunction

assign mode = auto_on ? ref_mode(code) : manual;

endmodule
