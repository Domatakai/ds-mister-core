//============================================================================
// NDS MiSTer Test — 3D geometry engine — STUB
//
// Milestone M3. The hardware engine consumes GXFIFO commands (matrix
// stack ops, vertex submissions, box test, begin/end) at up to 6144
// vertices per frame and feeds the rasterizer. Register block lives at
// 0x04000440..0x0400051F (matrix + GXSTAT), reached through main_bus.
//
// This stub keeps the command FIFO plumbing and status bits so the CPU
// side can be written against a stable contract.
//============================================================================
module geometry_engine (
	input            clk,
	input            reset,

	// matrix / command register access from main_bus
	input            reg_we,
	input      [7:0] reg_addr,
	input     [31:0] reg_data,
	output    [31:0] reg_rdata,

	// vertex output towards the rasterizer
	output           vtx_valid,
	output    [15:0] vtx_x,     // 4.12 fixed
	output    [15:0] vtx_y,
	output     [7:0] vtx_color,
	output     [1:0] vtx_poly    // polygon mode
);

// GXSTAT-style status: FIFO empty, geometry engine idle.
assign reg_rdata = 32'h0100_0000; // busy=0, FIFO empty
assign vtx_valid = 1'b0;
assign vtx_x = 0;
assign vtx_y = 0;
assign vtx_color = 0;
assign vtx_poly = 0;

wire _unused = &{1'b0, clk, reset, reg_we, reg_addr, reg_data};

endmodule
