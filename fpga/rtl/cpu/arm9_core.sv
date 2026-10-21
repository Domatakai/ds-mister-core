//============================================================================
// NDS MiSTer Test — ARM946E-S core — STUB (milestone M1)
//
// Targets: ARMv5TE, 67.02 MHz, seven-stage pipeline, CP15 with
// ITCM/DTCM and protection unit, hardware Mul/LongMul, extended QADD.
// The ARM9 also owns the majority of DMA channels and the MMU that
// maps the bus in main_bus.sv.
//
// Bring-up order:
//   1. fetch/decode/execute a minimal integer subset, boot from HLE BIOS
//   2. CP15 TCM + caches (cache modelling can start disabled)
//   3. exceptions (reset/IRQ/undef) and coprocessor 15 timing
//   4. cycle-exact bus timing against melonDS traces
//============================================================================
module arm9_core (
	input            clk,
	input            reset,
	input            ce,
	// OSD "CPU overclock": 0 normal, 1 ARM7 x2, 2 ARM7 x4 (melonDS-style
	// headroom for demanding titles). The M3 PLL turns this into faster
	// clock enables; the ARM9 domain stays at 67.02 MHz nominal.
	input      [1:0] oc_mode
);

// Bus master interface (wired in M1):
//   output [31:0] bus_addr; bus_wr_data; output bus_rd, bus_wr;
//   input  [31:0] bus_rd_data; input bus_ack;
reg [31:0] pc = 32'hFFFF0000; // reset vector

wire _unused = &{1'b0, clk, reset, ce, oc_mode, pc};

endmodule
