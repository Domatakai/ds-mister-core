//============================================================================
// NDS MiSTer Test — SDRAM controller
//
// Compact single-port controller for the DE10-Nano's 32 MB SDRAM
// (4M x 16 bit, CL3, burst length 1). Word address map:
//
//   addr[8:0]   column   (512)
//   addr[10:9]  bank     (4)
//   addr[23:11] row      (8192)
//
// Regions carved out by the core (see main_bus.sv):
//   0x000000..0x1FFFFF  cart ROM window   (up to 2 MB banked; full cart
//                                           banking lands with M4)
//   0x200000..0x27FFFF  main RAM (4 MB, the DS's 32-bit main memory
//                        presented as 16-bit words)
//   0x280000..0x283FFF  save data (up to 1 MB in later milestones)
//
// One requester at a time for now; main_bus.sv is where arbitration
// between ARM9, ARM7, DMA and the video path gets added.
//============================================================================
module sdram_ctrl (
	input            clk,
	input            reset,
	input     [24:0] addr,
	input     [15:0] din,
	input            rd,
	input            wr,
	output reg [15:0] dout,
	output reg       rd_done,
	output reg       wr_done,

	output           SDRAM_CLK,
	output           SDRAM_CKE,
	output    [12:0] SDRAM_A,
	output     [1:0] SDRAM_BA,
	inout     [15:0] SDRAM_DQ,
	output           SDRAM_DQML,
	output           SDRAM_DQMH,
	output           SDRAM_nCS,
	output           SDRAM_nCAS,
	output           SDRAM_nRAS,
	output           SDRAM_nWE
);

localparam INIT_WAIT  = 16'd5000;  // 100 us at 50 MHz
localparam REFRESH_IV = 10'd390;   // 8192 rows / 64 ms

localparam OP_NOP  = 4'b0111; // {nCS,nCAS,nRAS,nWE}
localparam OP_READ = 4'b0101;
localparam OP_WRIT = 4'b0100;
localparam OP_PRE  = 4'b0010;
localparam OP_REF  = 4'b0001;
localparam OP_LMR  = 4'b0000;
localparam OP_ACT  = 4'b0110;reg [3:0]  op = OP_NOP;
reg        dqm = 1'b1;
reg        drive_dq = 1'b0;
reg [12:0] a;
reg [1:0]  ba;
reg [15:0] dq_out;

assign SDRAM_CLK = ~clk;   // board adds trace delay; invert for centre
assign SDRAM_CKE = 1'b1;
assign SDRAM_A   = a;
assign SDRAM_BA  = ba;
assign SDRAM_DQ  = drive_dq ? dq_out : 16'hzzzz;
assign SDRAM_DQML = dqm;
assign SDRAM_DQMH = dqm;
assign {SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE} = op;

//------------------------------------------------------------------
// state machine
//------------------------------------------------------------------
localparam S_INIT   = 4'd0;
localparam S_PRE0   = 4'd1;
localparam S_REF0   = 4'd2;
localparam S_REF1   = 4'd3;
localparam S_LMR    = 4'd4;
localparam S_IDLE   = 4'd5;
localparam S_REFRESH= 4'd6;
localparam S_ACT    = 4'd7;
localparam S_RCD    = 4'd8;
localparam S_READ   = 4'd9;
localparam S_RCV    = 4'd10;
localparam S_WRITE  = 4'd11;

reg [3:0]  state = S_INIT;
reg [15:0] init_cnt = 0;
reg [9:0]  ref_cnt = 0;
reg        ref_due = 0;
reg [2:0]  wait_cnt = 0;
reg [24:0] a_lat = 0;

wire [8:0]  col  = addr[8:0];
wire [1:0]  bank = addr[10:9];
wire [12:0] row  = addr[23:11];

always @(posedge clk) begin
	rd_done <= 0;
	wr_done <= 0;

	if (ref_cnt == REFRESH_IV) begin
		ref_cnt <= 0;
		ref_due <= 1;
	end else begin
		ref_cnt <= ref_cnt + 1'd1;
	end

	case (state)
	S_INIT: begin
		op <= OP_NOP; dqm <= 1; drive_dq <= 0;
		if (init_cnt == INIT_WAIT) state <= S_PRE0;
		else init_cnt <= init_cnt + 1'd1;
	end
	S_PRE0: begin op <= OP_PRE; a[10] <= 1; state <= S_REF0; end
	S_REF0: begin op <= OP_REF; state <= S_REF1; end
	S_REF1: begin op <= OP_REF; state <= S_LMR; wait_cnt <= 3'd6; end
	S_LMR: begin
		// CL=3, burst length 1
		op <= OP_LMR; a <= 13'b0000_0_011_0_000; ba <= 2'b00;
		if (wait_cnt == 0) begin state <= S_IDLE; op <= OP_NOP; end
		else wait_cnt <= wait_cnt - 1'd1;
	end
	S_IDLE: begin
		op <= OP_NOP; dqm <= 0; drive_dq <= 0;
		if (ref_due) begin
			op <= OP_REF; ref_due <= 0; state <= S_REFRESH;
		end else if (rd || wr) begin
			a_lat <= addr;
			state <= S_ACT;
		end
	end
	S_REFRESH: begin
		state <= S_IDLE;
	end
	S_ACT: begin
		// ACTIVE: nRAS low only, then honour tRCD before read/write
		op <= OP_ACT; ba <= a_lat[10:9]; a <= a_lat[23:11];
		wait_cnt <= 3'd2;
		state <= S_RCD;
	end
	S_RCD: begin
		op <= OP_NOP;
		if (wait_cnt == 0) state <= rd ? S_READ : S_WRITE;
		else wait_cnt <= wait_cnt - 1'd1;
	end
	S_READ: begin
		op <= OP_READ; ba <= a_lat[10:9]; a <= {4'd0, a_lat[8:0]}; a[10] <= 0;
		dqm <= 0; wait_cnt <= 3'd3; // CL=3
		state <= S_RCV;
	end
	S_RCV: begin
		op <= OP_NOP;
		if (wait_cnt == 0) begin
			dout <= SDRAM_DQ;
			rd_done <= 1;
			state <= S_IDLE;
		end else wait_cnt <= wait_cnt - 1'd1;
	end
	S_WRITE: begin
		op <= OP_WRIT; ba <= a_lat[10:9]; a <= {4'd0, a_lat[8:0]}; a[10] <= 0;
		dq_out <= din; drive_dq <= 1; dqm <= 0;
		wr_done <= 1;
		state <= S_IDLE;
	end
	default: state <= S_IDLE;
	endcase

	if (reset) begin
		state <= S_INIT; init_cnt <= 0; ref_cnt <= 0; ref_due <= 0;
	end
end

endmodule
