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
//   0x000000..0x0FFFFF  save data (up to 1 MB; cart_slot save master,
//                        M4 completes the handshakes)
//   0x200000..0x3FFFFF  main RAM (4 MB of the DS's 32-bit main memory
//                        as 16-bit halfwords: base + byte_offset/2)
//   0x400000..0x4FFFFF  palette/OAM overflow (M2)
//
// Row policy: one row is kept open per bank, and ACTIVE is only issued
// when the access needs a different row — precharging the open one
// first. Sequential traffic (scanline fetches, and the 3D frame reads
// that walk a row for hundreds of columns) then costs READ + CL per
// halfword instead of ACT + tRCD + READ + CL. ACTIVE without a
// preceding PRECHARGE is a protocol violation on real hardware, so this
// is a correctness fix as much as a speed one. Burst length stays 1:
// every requester assumes one halfword per access.
//
// Two ways to move data, and the difference is the whole point:
//
//   * single access — `rd`/`wr` pulse in, one `rd_done`/`wr_done` out.
//     From the request edge to done is ~9 clocks, because the request,
//     the ACTIVE, the column and the CL capture are all serialised.
//   * read burst — `rd_bst` with `bst_len` beats in, then `bst_valid` one
//     beat per cycle and `bst_done` at the end. Once the row is open a
//     READ goes out every cycle, so N beats cost N clocks plus the row and
//     CL2 overhead instead of 9*N. A stretch that crosses a row boundary
//     precharges and re-activates inside the burst, so the caller never
//     has to align anything.
//
//     The burst carries a stride (`bst_step`, 1..3 address units between
//     beats) because a 16-bpp VRAM pixel occupies two halfwords under this
//     core's one-address-unit-per-byte VRAM map. A strided burst fetches
//     exactly the pixels it needs at one beat per clock instead of reading
//     the gap halfwords and throwing half the data away.
//
// The burst stream has no back-pressure: while `bst_valid` is high the
// beat is there to be consumed that cycle. The beat cadence is derived
// from the issue cadence, so a burst that stalls for a refresh keeps its
// data streamed in the same order with the gap preserved.
//
// AUTO REFRESH requires every bank precharged, so a refresh that comes
// due with a row open runs PRECHARGE ALL and waits tRP first, then tRFC
// after the refresh. The mode register is written once, after the
// initial precharge + refresh pair.
//
// The request is a one-cycle pulse on rd/wr/rd_bst (mem_arbiter drops it
// as soon as it has issued), so the controller latches address, length
// and direction the moment the pulse appears and serves it from S_IDLE.
// Without that latch a request landing on a refresh cycle is lost and
// the requester waits forever — tb_sdram_ctrl catches exactly that.
//============================================================================
module sdram_ctrl (
	input            clk,
	input            reset,
	input     [24:0] addr,
	input     [15:0] din,
	input      [1:0] be,     // byte enable: {DQMH, DQML} = {byte1, byte0}
	input            rd,
	input            wr,
	input            rd_bst, // read burst: bst_len beats starting at addr
	input      [7:0] bst_len,
	input      [1:0] bst_step,// address units between beats (1 = linear)
	output reg [15:0] dout,
	output reg       rd_done,
	output reg       wr_done,
	output reg       bst_valid,   // one halfword per cycle, in address order
	output reg [15:0] bst_data,
	output reg       bst_done,    // last beat has been returned

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

// Timings are for clk_sys = 67.0274 MHz (14.92 ns a cycle), the DS's own
// clock. Each wait below is the JEDEC minimum rounded *up* to whole cycles:
// the refresh interval is 8192 rows / 64 ms = 7.8125 us, and the FSM's
// tRP/tRCD/tRFC counts are 3/3/7 cycles = 45/45/104 ns against 20/20/66 ns.
localparam INIT_WAIT  = 16'd6703;  // 100 us
localparam REFRESH_IV = 10'd523;   // 7.8125 us
localparam [2:0] CL   = 3'd3;      // CAS latency (mode register below)

localparam OP_NOP  = 4'b0111; // {nCS,nCAS,nRAS,nWE}
localparam OP_READ = 4'b0101;
localparam OP_WRIT = 4'b0100;
localparam OP_PRE  = 4'b0010;
localparam OP_REF  = 4'b0001;
localparam OP_LMR  = 4'b0000;
localparam OP_ACT  = 4'b0110;

reg [3:0]  op = OP_NOP;
reg  [1:0] dqm = 2'b11;   // {DQMH, DQML} per-byte write mask
reg        drive_dq = 1'b0;
reg [12:0] a;
reg  [1:0] ba;
reg [15:0] dq_out;

assign SDRAM_CLK = ~clk;   // board adds trace delay; invert for centre
assign SDRAM_CKE = 1'b1;
assign SDRAM_A   = a;
assign SDRAM_BA  = ba;
assign SDRAM_DQ  = drive_dq ? dq_out : 16'hzzzz;
assign SDRAM_DQML = dqm[0];
assign SDRAM_DQMH = dqm[1];
assign {SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE} = op;

//------------------------------------------------------------------
// state machine
//------------------------------------------------------------------
localparam [4:0]
	S_INIT  = 5'd0,
	S_PRE0  = 5'd1,   // precharge all, then the init refresh pair
	S_REF0  = 5'd2,
	S_REF1  = 5'd3,
	S_LMR   = 5'd4,
	S_IDLE  = 5'd5,
	S_PREA  = 5'd6,   // PRECHARGE ALL before a runtime refresh
	S_REFW  = 5'd7,   // tRP between PRECHARGE ALL and REFRESH
	S_REFR  = 5'd8,   // runtime AUTO REFRESH
	S_RFC   = 5'd9,   // tRFC after AUTO REFRESH
	S_ACT   = 5'd10,
	S_RCD   = 5'd11,  // tRCD (or tRP) wait before the access
	S_READ  = 5'd12,
	S_RCV   = 5'd13,  // CL=3 data capture
	S_WRITE = 5'd14,
	S_PREB  = 5'd15,  // PRECHARGE one bank before a new row in it
	S_BST   = 5'd16;  // burst: one READ issue per cycle in an open row

reg [4:0]  state = S_INIT;
reg [15:0] init_cnt = 0;
reg [9:0]  ref_cnt = 0;
reg        ref_due = 0;
reg [2:0]  wait_cnt = 0;
reg [24:0] a_lat = 0;
reg        is_wr = 0;          // direction latched with the request
reg        is_bst = 0;         // the access in flight is a read burst
reg        act_pending = 0;    // S_RCD must activate before the access

// request latch: a one-cycle rd/wr/rd_bst pulse is held until the FSM
reg        have_req = 0;
reg [24:0] req_addr = 0;
reg        req_wr = 0;
reg        req_bst = 0;
reg  [7:0] req_len = 0;
reg  [1:0] req_inc = 1;

// burst engine
reg [24:0] bst_ptr = 0;        // next halfword to issue
reg  [1:0] bst_inc = 1;        // address units per beat
reg  [7:0] bst_left = 0;       // reads still to issue
reg  [4:0] bst_pipe = 0;       // 1 = a READ left this cycle (bit0) ...
                               // ... and bit n+3 = its data is on DQ now

// one open row per bank (the address of the last ACTIVE in that bank)
reg        row_open [0:3];
reg [12:0] open_row [0:3];

integer b;
wire    any_open = row_open[0] | row_open[1] | row_open[2] | row_open[3];

wire [1:0]  rq_bank = req_addr[10:9];
wire [12:0] rq_row  = req_addr[23:11];

wire hit_row  = row_open[rq_bank] && (open_row[rq_bank] == rq_row);
wire miss_row = row_open[rq_bank] && (open_row[rq_bank] != rq_row);

// burst issue: one READ per cycle while the current halfword's row is open
wire [1:0]  bp_bank  = bst_ptr[10:9];
wire [12:0] bp_row   = bst_ptr[23:11];
wire        bp_hit   = row_open[bp_bank] && (open_row[bp_bank] == bp_row);
wire        bst_busy = |bst_pipe;
wire        do_issue = (state == S_BST) && (bst_left != 8'd0) && bp_hit;

always @(posedge clk) begin
	rd_done  <= 0;
	wr_done  <= 0;
	bst_done <= 0;
	bst_valid <= 0;

	// latch a request the moment it appears, so it survives a refresh
	if ((rd || wr || rd_bst) && !have_req) begin
		have_req <= 1'b1;
		req_addr <= addr;
		req_wr   <= wr;			req_bst  <= rd_bst;
			req_len  <= bst_len;
			req_inc  <= bst_step;
	end

	if (ref_cnt == REFRESH_IV) begin
		ref_cnt <= 0;
		ref_due <= 1;
	end else begin
		ref_cnt <= ref_cnt + 1'd1;
	end

	case (state)
	S_INIT: begin
		op <= OP_NOP; dqm <= 2'b11; drive_dq <= 0;
		if (init_cnt == INIT_WAIT) state <= S_PRE0;
		else init_cnt <= init_cnt + 1'd1;
	end
	S_PRE0: begin op <= OP_PRE; a <= 13'h0400; ba <= 2'b00; state <= S_REF0; end
	S_REF0: begin op <= OP_REF; a <= 13'h0400; state <= S_REF1; end
	S_REF1: begin op <= OP_REF; a <= 13'h0400; state <= S_LMR; wait_cnt <= 3'd6; end
	S_LMR: begin
		// CL=3, burst length 1
		op <= OP_LMR; a <= 13'b0000_0_011_0_000; ba <= 2'b00;
		if (wait_cnt == 0) begin state <= S_IDLE; op <= OP_NOP; end
		else wait_cnt <= wait_cnt - 1'd1;
	end
	S_IDLE: begin
		op <= OP_NOP; dqm <= 2'b00; drive_dq <= 0;
		if (have_req) begin
			have_req    <= 1'b0;
			a_lat       <= req_addr;
			is_wr       <= req_wr;
			is_bst      <= req_bst;
			bst_ptr     <= req_addr;
			bst_inc     <= (req_inc == 2'd0) ? 2'd1 : req_inc;
			bst_left    <= req_len;
			bst_pipe    <= 5'd0;
			act_pending <= !hit_row;
			// same row already open: skip ACTIVE and the tRCD wait
			state       <= miss_row ? S_PREB :
			               hit_row  ? (req_bst ? S_BST : (req_wr ? S_WRITE : S_READ))
			                        : S_ACT;
		end else if (ref_due) begin
			ref_due <= 0;
			state   <= any_open ? S_PREA : S_REFR;
		end
	end
	S_PREA: begin
		op <= OP_PRE; a <= 13'h0400; ba <= 2'b00;   // A10 = precharge all
		wait_cnt <= 3'd2;
		state <= S_REFW;
		for (b = 0; b < 4; b = b + 1) row_open[b] <= 1'b0;
	end
	S_REFW: begin
		op <= OP_NOP;
		if (wait_cnt == 0) state <= S_REFR;
		else wait_cnt <= wait_cnt - 1'd1;
	end
	S_REFR: begin
		op <= OP_REF; a <= 13'h0400; ba <= 2'b00;   // A10 = all banks
		wait_cnt <= 3'd6;               // tRFC: 7 cycles = 104 ns
		state <= S_RFC;
	end
	S_RFC: begin
		op <= OP_NOP;
		if (wait_cnt == 0) state <= S_IDLE;
		else wait_cnt <= wait_cnt - 1'd1;
	end
	S_ACT: begin
		// ACTIVE: nRAS low only; tRCD is honoured before the access
		op <= OP_ACT; ba <= a_lat[10:9]; a <= a_lat[23:11];
		row_open[a_lat[10:9]] <= 1'b1;
		open_row[a_lat[10:9]] <= a_lat[23:11];
		wait_cnt <= 3'd2;
		act_pending <= 1'b0;
		state <= S_RCD;
	end
	S_PREB: begin
		op <= OP_PRE; a <= 13'h0400; ba <= a_lat[10:9];  // this bank only
		row_open[a_lat[10:9]] <= 1'b0;
		wait_cnt <= 3'd2;
		state <= S_RCD;
	end
	S_RCD: begin
		op <= OP_NOP;
		if (wait_cnt == 0) begin
			if (act_pending) state <= S_ACT;   // precharge done, activate
			else             state <= is_bst ? S_BST :
			                          is_wr  ? S_WRITE : S_READ;
		end else wait_cnt <= wait_cnt - 1'd1;
	end
	S_READ: begin
		op <= OP_READ; ba <= a_lat[10:9]; a <= {4'd0, a_lat[8:0]}; a[10] <= 0;
		dqm <= 2'b00; wait_cnt <= CL; // CL=3
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
		dq_out <= din; drive_dq <= 1; dqm <= ~be; // per-byte write mask
		wr_done <= 1;
		state <= S_IDLE;
	end
	S_BST: begin
		op <= OP_NOP; dqm <= 2'b00; drive_dq <= 0;
		if (bst_left == 8'd0 && !bst_busy) begin
			is_bst   <= 1'b0;
			bst_done <= 1;
			state    <= S_IDLE;
		end else if (bst_left != 8'd0 && !bp_hit) begin
			// the walk reached a new row: precharge the bank and re-activate
			a_lat       <= bst_ptr;
			act_pending <= 1'b1;
			state       <= row_open[bp_bank] ? S_PREB : S_ACT;
		end
	end
	default: state <= S_IDLE;
	endcase

	// burst issue and capture, after the case so it owns op/bst_* on the
	// cycles it acts. One READ leaves each cycle the row is open, and its
	// data lands CL+1 clocks later, so bit 3 of the issue pipe marks the
	// clock on which DQ carries the beat issued four cycles ago.
	bst_pipe <= {bst_pipe[3:0], do_issue};
	if (do_issue) begin
		op  <= OP_READ;
		ba  <= bp_bank;
		a   <= {4'd0, bst_ptr[8:0]};
		a[10] <= 1'b0;
		bst_ptr  <= bst_ptr + {22'd0, bst_inc};
		bst_left <= bst_left - 1'd1;
	end
	if (bst_pipe[3]) begin
		bst_data  <= SDRAM_DQ;
		bst_valid <= 1'b1;
	end

	if (reset) begin
		state <= S_INIT;
		init_cnt <= 0; ref_cnt <= 0; ref_due <= 0;
		act_pending <= 0; is_wr <= 0; is_bst <= 0; have_req <= 0;
		bst_ptr <= 0; bst_inc <= 1; bst_left <= 0; bst_pipe <= 0;
		bst_valid <= 0; bst_done <= 0;
		for (b = 0; b < 4; b = b + 1) row_open[b] <= 1'b0;
	end
end

endmodule
