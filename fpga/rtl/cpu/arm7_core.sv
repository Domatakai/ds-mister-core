//============================================================================
// NDS MiSTer Test — ARM7TDMI core — STUB (milestone M1)
//
// Targets: ARMv4T, 33.51 MHz, Thumb + ARM states, sound/DMA/touch/
// keypad controllers, SPI (firmware flash, touchscreen, power),
// and the WiFi SPI port (local DS-to-DS play is milestone M5).
// Shares IPC + WRAM with the ARM9 through main_bus.
//============================================================================
module arm7_core (
	input            clk,
	input            reset,
	input            ce,
	// OSD "CPU overclock" (see arm9_core.sv): with the M3 PLL this raises
	// the ARM7 clock enable above its 33.51 MHz base for heavy games.
	input      [1:0] oc_mode
);

// Bus master interface (wired in M1):
//   output [31:0] bus_addr; bus_wr_data; output bus_rd, bus_wr;
//   input  [31:0] bus_rd_data; input bus_ack;
reg [31:0] pc = 32'h00000000;

wire _unused = &{1'b0, clk, reset, ce, oc_mode, pc};

endmodule
