//============================================================================
// NDS MiSTer Test — VRAM bank arbiter
//
// The DS exposes nine 128 KB VRAM banks (A..I), each mappable into one
// of several slots of the LCDC space or either 2D/3D engine's space via
// the VRAMCNT registers (0x04000240..0x04000247). This module owns the
// mapping registers and (from M2 on) grants cycle-stepped access to the
// 2D engines, the 3D rasterizer, the capture unit and both CPUs.
//
// Grant priority (M2): CPU9 > capture > engine A/B > rasterizer > CPU7.
//============================================================================
module vram_arbiter (
	input            clk,
	input            reset,

	// IO register writes from main_bus (VRAMCNT_A..I)
	input            reg_we,
	input      [3:0] reg_addr,   // 0..8 -> banks A..I
	input      [7:0] reg_data,

	// requestors (wired in M2)
	input            req_cpu9,
	input            req_cpu7,
	input            req_eng_a,
	input            req_eng_b,
	input            req_raster,

	output     [1:0] grant        // 0=none 1=cpu9 2=eng 3=cpu7
);

// Bank control registers: [1:0] MST (master), [2] VS (offset for 3D),
// [7] enabled. Mapped as on hardware.
reg [7:0] vramcnt [8:0];
integer i;
always @(posedge clk) begin
	if (reset) begin
		for (i = 0; i < 9; i = i + 1) vramcnt[i] <= 8'h80; // enabled, LCDC
	end else if (reg_we && reg_addr < 9) begin
		vramcnt[reg_addr] <= reg_data;
	end
end

// Round-robin grant stub — replaced with the real cycle scheduler in M2.
reg [1:0] grant_r = 0;
always @(posedge clk) begin
	if (reset) grant_r <= 0;
	else if (req_cpu9)  grant_r <= 2'd1;
	else if (req_eng_a | req_eng_b | req_raster) grant_r <= 2'd2;
	else if (req_cpu7)  grant_r <= 2'd3;
	else grant_r <= 0;
end
assign grant = grant_r;

wire _unused = &{1'b0, vramcnt[0], vramcnt[8]};

endmodule
