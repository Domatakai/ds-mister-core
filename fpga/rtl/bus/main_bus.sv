//============================================================================
// NDS MiSTer Test — main bus interconnect — SKELETON
//
// Holds the Nintendo DS address map and will arbitrate between ARM9,
// ARM7, DMA channels and the video path. Milestone M1 fills in the
// decode; M2/M3 attach the engines.
//
// Memory map (physical, as seen by the ARM9):
//   0x00000000  ITCM                (mapped via CP15)
//   0x02000000  Main RAM      4 MB  -> SDRAM 0x200000
//   0x027FF000  Main RAM mirror
//   0x03000000  Shared WRAM   64 KB (internal BRAM)
//   0x03800000  ARM7 WRAM     64 KB (internal BRAM)
//   0x04000000  I/O registers       (INTSTAT, POWCNT, VRAMCNT, GXFIFO…)
//   0x05000000  Palette       2 KB
//   0x06000000  VRAM          656 KB -> vram_arbiter banks A..I
//   0x07000000  OAM           2 KB
//   0x08000000  GBA slot ROM  (Slot-2, M4)
//   0xFFFF0000  BIOS mirror
//
// The ARM7 sees the same map minus ITCM/DTCM with its own WRAM at
// 0x03800000; the BIOS images (bios7.bin/bios9.bin) are HLE'd or
// loaded from SD when the OSD "Slot-1 BIOS" option is set to Real.
//============================================================================
module main_bus (
	input clk,
	input reset,

	// input state from input_mapper — served as KEYINPUT (0x04000130,
	// active low: 0=Pressed) and the touch/mic SPI devices in M1
	input     [11:0] ds_keys,
	input      [8:0] touch_x,
	input      [7:0] touch_y,
	input            touch_down,
	input            mic_in
);

// 64 KB shared WRAM and 64 KB ARM7 WRAM as inferred block RAM — filled
// in with real bus ports in M1.
reg [7:0] wram_shared [0:65535];
reg [7:0] wram_arm7   [0:65535];

wire _unused = &{1'b0, clk, reset, ds_keys, touch_x, touch_y, touch_down,
                 mic_in, wram_shared[0], wram_arm7[0]};

endmodule
