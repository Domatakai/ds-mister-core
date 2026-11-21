//============================================================================
// NDS MiSTer Test -- ARM9 tightly-coupled memory
//
// Step A of the cache work: the 32 KB instruction and 16 KB data TCM the
// ARM946E-S has, as storage behind the CPU's bus port. It sits between
// arm9_core and cpu_ce_bridge, on the same handshake, so the core does not
// know it is there and the fabric never sees a TCM access.
//
// Registers (GBATEK, ARM946E-S TRM):
//   CP15 c9 opcode_2=0  data TCM region   [31:12] base, [5:1] size
//   CP15 c9 opcode_2=1  instruction TCM   (base fixed at 0 on the hard part)
//   CP15 c1 bit 16      data TCM enable
//   CP15 c1 bit 18      instruction TCM enable
// Size encoding: b00011 = 4 KB and each step doubles, so
// 4 KB << (enc - 3); b0000x and b0001x are prohibited and read as no area.
//
// The DS firmware programs the ITCM area as 32 MB, which is why the ITCM
// mirrors every 32 KB of the low 32 MB (0, 0x01000000, ...) -- libnds and
// blocksds both run from 0x01000000. The storage is 32 KB and the area
// decode is the register's, so the mirror comes out of the address wrap:
// the index is address[14:2] for the ITCM and address[13:2] for the DTCM.
//
// Both TCMs are dormant at reset: the core's post-BIOS control register has
// the DTCM enable set but the region register is still zero, and a zero
// region size means no area. Software that wants them (crt0 does, early)
// writes c9 and the control bits itself, exactly as it does on the board.
// Starting them enabled would shadow the low vector page and 0x027C0000
// with zeros nothing has filled yet, and this core has no BIOS to fill them.
//
// A hit answers in one clock: the request is taken on the edge it is seen,
// the word is read out of the block RAM in that same edge, and `c_ready`
// is asserted for the cycle the core samples it. A miss passes the request
// to the fabric untouched, including the HLE SWI engine's accesses, which
// reach the bus through the core's own master.
//============================================================================
`timescale 1ns / 1ps

module arm9_tcm (
	input             clk,

	// CP15 state, from the core
	input      [31:0] c1_ctrl,
	input      [31:0] c9_dtcm,
	input      [31:0] c9_itcm,

	// core side
	input      [31:0] c_addr,
	input      [31:0] c_wdata,
	input      [3:0]  c_be,
	input             c_rd,
	input             c_wr,
	output     [31:0] c_rdata,
	output            c_ready,

	// fabric side
	output     [31:0] f_addr,
	output     [31:0] f_wdata,
	output     [3:0]  f_be,
	output            f_rd,
	output            f_wr,
	input      [31:0] f_rdata,
	input             f_ready
);

function [31:0] area (input [31:0] cfg);
	begin
		if (cfg[5:1] < 5'd3) area = 32'd0;
		else                 area = 32'd4096 << (cfg[5:1] - 5'd3);
	end
endfunction

wire [31:0] itcm_sz = area(c9_itcm);
wire [31:0] dtcm_sz = area(c9_dtcm);
wire        itcm_on = c1_ctrl[18] && (itcm_sz != 32'd0);
wire        dtcm_on = c1_ctrl[16] && (dtcm_sz != 32'd0);

// The subtraction is the whole test: for a power-of-two area aligned to its
// own size, (addr - base) < size is true exactly inside it, and the wrap at
// 4 GB comes out right without a wider compare.
wire        itcm_hit = itcm_on && ((c_addr - {c9_itcm[31:12], 12'd0}) < itcm_sz);
wire        dtcm_hit = dtcm_on && ((c_addr - {c9_dtcm[31:12], 12'd0}) < dtcm_sz);
wire        hit      = itcm_hit | dtcm_hit;

reg [31:0] itcm [0:8191];      // 32 KB
reg [31:0] dtcm [0:4095];      // 16 KB

wire [12:0] idx_i = c_addr[14:2];
wire [11:0] idx_d = c_addr[13:2];

// one request at a time: the core holds its address and strobes until it has
// seen c_ready, so a single pending bit is all the handshake needs
reg        pend = 1'b0;   // power-up: no request in flight (Quartus takes it)
reg [31:0] rd_q;

always @(posedge clk) begin
	pend <= 1'b0;
	if (!pend && hit && (c_rd || c_wr)) begin
		pend <= 1'b1;
		if (c_rd)
			rd_q <= dtcm_hit ? dtcm[idx_d] : itcm[idx_i];
		if (c_wr) begin
			if (dtcm_hit) begin
				if (c_be[0]) dtcm[idx_d][7:0]   <= c_wdata[7:0];
				if (c_be[1]) dtcm[idx_d][15:8]  <= c_wdata[15:8];
				if (c_be[2]) dtcm[idx_d][23:16] <= c_wdata[23:16];
				if (c_be[3]) dtcm[idx_d][31:24] <= c_wdata[31:24];
			end else begin
				if (c_be[0]) itcm[idx_i][7:0]   <= c_wdata[7:0];
				if (c_be[1]) itcm[idx_i][15:8]  <= c_wdata[15:8];
				if (c_be[2]) itcm[idx_i][23:16] <= c_wdata[23:16];
				if (c_be[3]) itcm[idx_i][31:24] <= c_wdata[31:24];
			end
		end
	end
end

assign c_ready = hit ? pend   : f_ready;
assign c_rdata = hit ? rd_q   : f_rdata;

assign f_addr  = c_addr;
assign f_wdata = c_wdata;
assign f_be    = c_be;
assign f_rd    = c_rd & ~hit;
assign f_wr    = c_wr & ~hit;

endmodule
