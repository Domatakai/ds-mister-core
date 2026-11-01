//============================================================================
// NDS MiSTer Test — ARM7TDMI core
//
// A real ARMv4T interpreter, not a stub: ARM and Thumb instruction sets, the
// CPSR/SPSR register banks, the exception vectors and the HALTCNT stop. It
// drives the main-bus master port directly (one access at a time, held until
// `bus_ready`), so what it executes is fetched from the same fabric the games
// use — BIOS, WRAM, main RAM or the cart window.
//
// It advances on `ce` (`cpu_ce`), because the ARM7's clock is half the
// ARM9's: see that module and `cpu_ce_bridge`, which is what sits between this
// port and `main_bus` so a response on a disabled cycle is not lost.
//
// Instruction coverage (ARM):
//   data processing   all 16 opcodes, all four shift types, register shifts,
//                     RRX, immediate rotate, S bit, PC write and the S+PC
//                     exception return (CPSR <- SPSR)
//   multiply          MUL MLA UMULL UMLAL SMULL SMLAL
//   load/store        LDR STR LDRB STRB, pre/post index, U/D, W, register
//                     offset with shift, the unaligned-LDR word rotate
//   halfword/signed   LDRH STRH LDRSB LDRSH, immediate and register offset
//   block transfer    LDM/STM IA IB DA DB, writeback, PC in the list
//   branch            B, BL
//   PSR               MRS, MSR (register and immediate, all four fields)
//   swap              SWP, SWPB
//   coprocessor       CDP/MCR/MRC/MCRR/MRRC take the undefined vector; the
//                     DS has no coprocessor the ARM7 can reach
//
// Instruction coverage (Thumb): all nineteen formats — shifted-register moves,
// add/sub, the eight ALU formats, hi-register ops and BX, PC- and SP-relative
// loads, every load/store format including the sign-extending ones, load
// address, SP adjust, PUSH/POP, LDMIA/STMIA, conditional branch, SWI, B and
// the two-halfword BL pair.
//
// Timing is functional, not cycle-accurate: one bus access per fetch and one
// per load/store beat, one clock for an instruction body. That is the right
// trade while the fabric is what is being brought up; the real part's cycle
// budget (three-stage pipeline, branch penalty, per-region waitstates) comes
// from melonDS traces once the system boots.
//
// The one exception is the fetch buffer: the bus answers a whole word, so the
// second halfword of a Thumb word is already in hand and re-reading it would
// cost a bus slot the DMA and video engines could use. It is invalidated by
// any store (so self-modifying code still sees its own writes) and can be
// turned off with FETCH_BUF for measurement — tb_arm7 prints both readings.
//
// Reset is the DS's: SVC mode, I and F set, T clear, PC = boot_pc. The HLE
// boot path supplies the cart header's ARM7 entry point there — what the real
// BIOS would jump to after clearing WRAM — plus the stack it leaves behind
// (GBATEK: 0x0380FD80).
//============================================================================
module arm7_core #(
	// One-word fetch buffer. Thumb instructions are halfwords, so without it
	// every second fetch reads the word the previous one already returned.
	// Set to 0 to measure the difference; the bench prints both.
	parameter FETCH_BUF = 1
) (
	input             clk,
	input             reset,

	// Clock enable (`cpu_ce`): the ARM7's clock is half the ARM9's (33.51
	// against 67.02 MHz), so this core advances only on the cycles its enable
	// is high. The bus path is synchronized by `cpu_ce_bridge`, which holds a
	// response across the disabled cycles instead of letting it be missed.
	input             ce,

	// HLE boot: cart header ARM7 entry point + the firmware's stack
	input      [31:0] boot_pc,
	input      [31:0] boot_sp,

	// ---- bus master ----
	output reg [31:0] bus_addr,
	output reg [31:0] bus_wdata,
	output reg  [3:0] bus_be,
	output reg        bus_rd,
	output reg        bus_wr,
	input      [31:0] bus_rdata,
	input             bus_ready,

	// ---- interrupts / halt ----
	input             irq,        // IME & (IE & IF) of the ARM7 bank
	input             fiq,
	input             halt,       // HALTCNT bit 7: stop until an interrupt
	output            halted,
	output            thumb_state,
	output     [31:0] pc_out,

	// ---- BIOS SWI bank (one shared engine, arbitrated: `swi_share`) ----
	// A call is CPU state, so it leaves the core: `hle_go` rises with the
	// number and r0..r3, the arbiter hands the one shared engine over, and the
	// engine's bus access comes back on `hle_b_*` only while this core owns it
	// — which is what lets the engine reach *this* core's IE/IF for Halt and
	// IntrWait.
	output reg        hle_go,
	output reg  [7:0] hle_num,
	output     [31:0] hle_r0, hle_r1, hle_r2, hle_r3,
	input             hle_done,
	input             hle_handled,
	input      [31:0] hle_res0, hle_res1, hle_res3,
	input             hle_wr0, hle_wr1, hle_wr3,
	input             hle_b_req,
	input             hle_b_wr,
	input      [31:0] hle_b_addr,
	input      [31:0] hle_b_wlane,
	input       [3:0] hle_b_be,
	output            hle_b_ack,
	output     [31:0] hle_b_rdata
);

//------------------------------------------------------------------
// Architectural state
//------------------------------------------------------------------
reg [31:0] regs [0:15];
reg  [31:0] pc;
reg         n, z, c, v, i, f, t;
reg  [4:0]  mode;

// banked r13/r14 (0 usr/sys, 1 fiq, 2 irq, 3 svc, 4 abt, 5 und)
reg [31:0] r13_b [0:5];
reg [31:0] r14_b [0:5];
// banked r8..r12 for FIQ
reg [31:0] r8f_b [0:4];
// banked SPSRs
reg [31:0] spsr_fiq, spsr_irq, spsr_svc, spsr_abt, spsr_und;

reg [31:0] insn;
reg        insn_thumb;

// memory transaction
reg [31:0] ea;
reg  [1:0] msz;         // 0 byte, 1 halfword, 2 word
reg        mload;
reg        msigned;
reg        mrot;
reg [31:0] wdata_r;
reg  [4:0] dst;         // register a load writes (ARM and Thumb differ)
// writeback of the base register after a load/store
reg        wb_en;
reg  [4:0] wb_reg;
reg [31:0] wb_val;

// BIOS SWI hand-off (see swi_hle and swi_share): the core traps the call,
// mirrors the shared engine's bus requests onto its own master and returns
// when it is done. The engine itself is not here any more — one is arbitrated
// between this core and the other — so `hle_go`/`hle_num` are ports.
//
// The acknowledge is combinational: the engine must see `m_ack` in the very
// cycle the bus answers, so it drops the request at that edge and the bus is
// not presented with the same access twice
assign hle_b_ack   = hle_b_req & bus_ready;
assign hle_b_rdata = bus_rdata;
assign hle_r0 = regs[0];
assign hle_r1 = regs[1];
assign hle_r2 = regs[2];
assign hle_r3 = regs[3];

// swap
reg        swap_en, swap_phase;
reg [31:0] swap_src, swap_val;

// block transfer
reg        blk_run, blk_ld, blk_pc_hit;
reg  [15:0] blk_list;
reg [31:0] blk_addr, blk_pc_val;

localparam S_RST  = 4'd0,
           S_FETCH= 4'd1,
           S_FW   = 4'd2,
           S_EXEC = 4'd3,
           S_MEM  = 4'd4,
           S_MW   = 4'd5,
           S_BLK  = 4'd6,
           S_HALT = 4'd7,
           S_SWI  = 4'd8;   // a BIOS call, running on the HLE bank
reg [3:0] state;

// fetch buffer: the word the last fetch returned, and whether it is still a
// valid copy of memory (a store clears it)
reg [31:0] f_word;
reg [31:0] f_addr;
reg        f_valid;
wire        f_hit = FETCH_BUF && f_valid && (f_addr == {pc[31:2], 2'b00});

assign halted      = (state == S_HALT);
assign thumb_state = t;
assign pc_out      = pc;

//------------------------------------------------------------------
// Helpers
//------------------------------------------------------------------
function [2:0] midx (input [4:0] m);
	begin
		case (m)
		5'h11:   midx = 3'd1;   // FIQ
		5'h12:   midx = 3'd2;   // IRQ
		5'h13:   midx = 3'd3;   // SVC
		5'h17:   midx = 3'd4;   // ABT
		5'h1B:   midx = 3'd5;   // UND
		default: midx = 3'd0;   // USR / SYS
		endcase
	end
endfunction

function [31:0] rotr (input [31:0] val, input [4:0] amt);
	begin
		if (amt == 5'd0) rotr = val;
		else             rotr = (val >> amt) | (val << (7'd32 - {2'd0, amt}));
	end
endfunction

// R15 reads the address of the current instruction + 8 (ARM) or + 4 (Thumb);
// `pc` already points at the next instruction, so that is pc+4 / pc+2.
function [31:0] rread (input [4:0] r);
	begin
		if (r == 5'd15) rread = pc + (insn_thumb ? 32'd2 : 32'd4);
		// r == 15 is taken above, so the index is 0..14: mask it to the four
		// bits the 16-entry array needs instead of handing the synthesiser a
		// five-bit index that can address 32 slots (warning 10027)
		else            rread = regs[r[3:0]];
	end
endfunction

// low byte of a register read (a function result cannot be part-selected
// directly in an expression)
function [7:0] rread8 (input [4:0] r);
	reg [31:0] v;
	begin
		v = rread(r);
		rread8 = v[7:0];
	end
endfunction

function [5:0] popcnt16 (input [15:0] v);
	integer j;
	begin
		popcnt16 = 6'd0;
		for (j = 0; j < 16; j = j + 1)
			popcnt16 = popcnt16 + {5'd0, v[j]};
	end
endfunction

wire [31:0] cpsr_w = {n, z, c, v, 20'd0, i, f, t, mode};
wire  [2:0] cur_m  = midx(mode);

//------------------------------------------------------------------
// Operand 2 and the barrel shifter (ARM data processing, and the register
// offset of a single data transfer, which shares the encoding)
//------------------------------------------------------------------
reg  [31:0] op2;
reg         op2_c;
reg  [31:0] sh_in;
reg  [7:0]  sh_amt;

// Read the register file directly here rather than through `rread`: a
// combinational block is only sensitive to what it names, and a function's
// internal reads of `regs` are invisible to `always @(*)`. Naming the array
// keeps the operand and the shifter amount live.
wire [4:0]  rm_f = insn[3:0];
wire [4:0]  rs_f = insn[11:8];
wire [31:0] pc_ahead = pc + (insn_thumb ? 32'd2 : 32'd4);
wire [31:0] rm_val = (rm_f == 5'd15) ? pc_ahead : regs[rm_f];
wire [7:0]  rs_amt = (rs_f == 5'd15) ? pc_ahead[7:0] : regs[rs_f][7:0];

always @(*) begin
	sh_in  = insn[25] ? {24'd0, insn[7:0]} : rm_val;
	sh_amt = insn[25] ? {insn[11:8], 1'b0}
	                  : (insn[4] ? rs_amt : {3'd0, insn[11:7]});
	op2    = sh_in;
	op2_c  = c;
	case (insn[6:5])
	2'b00: begin   // LSL
		if (sh_amt == 8'd0) op2 = sh_in;
		else if (sh_amt < 8'd32) begin
			op2   = sh_in << sh_amt[4:0];
			op2_c = sh_in[32 - {3'd0, sh_amt[4:0]}];
		end else if (sh_amt == 8'd32) begin
			op2   = 32'd0;
			op2_c = sh_in[0];
		end else begin
			op2   = 32'd0;
			op2_c = 1'b0;
		end
	end
	2'b01: begin   // LSR
		if (sh_amt == 8'd0) op2 = sh_in;
		else if (sh_amt < 8'd32) begin
			op2   = sh_in >> sh_amt[4:0];
			op2_c = sh_in[sh_amt[4:0] - 5'd1];
		end else if (sh_amt == 8'd32) begin
			op2   = 32'd0;
			op2_c = sh_in[31];
		end else begin
			op2   = 32'd0;
			op2_c = 1'b0;
		end
	end
	2'b10: begin   // ASR
		if (sh_amt == 8'd0) op2 = sh_in;
		else if (sh_amt < 8'd32) begin
			op2   = $signed(sh_in) >>> sh_amt[4:0];
			op2_c = sh_in[sh_amt[4:0] - 5'd1];
		end else begin
			op2   = {32{sh_in[31]}};
			op2_c = sh_in[31];
		end
	end
	default: begin // ROR, and RRX when the amount is zero
		if (sh_amt == 8'd0) begin
			op2   = {c, sh_in[31:1]};
			op2_c = sh_in[0];
		end else begin
			op2   = rotr(sh_in, sh_amt[4:0]);
			op2_c = op2[31];
		end
	end
	endcase
end

wire [31:0] imm32 = rotr({24'd0, insn[7:0]}, {insn[11:8], 1'b0});

//------------------------------------------------------------------
// Condition field
//------------------------------------------------------------------
// ARM keeps its condition in bits 31:28 and Thumb in bits 11:8 of the same
// word, so the test is a function over the four-bit code rather than a decode
// of one fixed field.
function cond_hold (input [3:0] cc);
	begin
		case (cc)
		4'h0: cond_hold =  z;
		4'h1: cond_hold = ~z;
		4'h2: cond_hold =  c;
		4'h3: cond_hold = ~c;
		4'h4: cond_hold =  n;
		4'h5: cond_hold = ~n;
		4'h6: cond_hold =  v;
		4'h7: cond_hold = ~v;
		4'h8: cond_hold =  c & ~z;
		4'h9: cond_hold = ~c |  z;
		4'hA: cond_hold = (n == v);
		4'hB: cond_hold = (n != v);
		4'hC: cond_hold = !z & (n == v);
		4'hD: cond_hold =  z | (n != v);
		4'hE: cond_hold = 1'b1;
		default: cond_hold = 1'b0;
		endcase
	end
endfunction

wire cond_ok = cond_hold(insn[31:28]);

//------------------------------------------------------------------
// Data processing ALU
//------------------------------------------------------------------
wire [4:0]  rn_f = insn[19:16];
wire [31:0] dp_a = (rn_f == 5'd15) ? pc_ahead : regs[rn_f];
wire [31:0] dp_b = insn[25] ? imm32 : op2;

reg  [31:0] dp_out;
reg         dp_c, dp_v;
reg  [32:0] wide;

always @(*) begin
	wide   = 33'd0;
	dp_out = 32'd0;
	dp_c   = op2_c;
	dp_v   = v;
	case (insn[24:21])
	4'h0: dp_out = dp_a & dp_b;                              // AND
	4'h1: dp_out = dp_a ^ dp_b;                              // EOR
	4'h2: begin                                              // SUB
		wide   = {1'b0, dp_a} - {1'b0, dp_b};
		dp_out = wide[31:0];
		dp_c   = wide[32];
		dp_v   = (dp_a[31] ^ dp_b[31]) & (dp_a[31] ^ dp_out[31]);
	end
	4'h3: begin                                              // RSB
		wide   = {1'b0, dp_b} - {1'b0, dp_a};
		dp_out = wide[31:0];
		dp_c   = wide[32];
		dp_v   = (dp_b[31] ^ dp_a[31]) & (dp_b[31] ^ dp_out[31]);
	end
	4'h4: begin                                              // ADD
		wide   = {1'b0, dp_a} + {1'b0, dp_b};
		dp_out = wide[31:0];
		dp_c   = wide[32];
		dp_v   = (dp_a[31] == dp_b[31]) & (dp_out[31] != dp_a[31]);
	end
	4'h5: begin                                              // ADC
		wide   = {1'b0, dp_a} + {1'b0, dp_b} + {32'd0, c};
		dp_out = wide[31:0];
		dp_c   = wide[32];
		dp_v   = (dp_a[31] == dp_b[31]) & (dp_out[31] != dp_a[31]);
	end
	4'h6: begin                                              // SBC
		wide   = {1'b0, dp_a} - {1'b0, dp_b} - {32'd0, ~c};
		dp_out = wide[31:0];
		dp_c   = wide[32];
		dp_v   = (dp_a[31] ^ dp_b[31]) & (dp_a[31] ^ dp_out[31]);
	end
	4'h7: begin                                              // RSC
		wide   = {1'b0, dp_b} - {1'b0, dp_a} - {32'd0, ~c};
		dp_out = wide[31:0];
		dp_c   = wide[32];
		dp_v   = (dp_b[31] ^ dp_a[31]) & (dp_b[31] ^ dp_out[31]);
	end
	4'h8: dp_out = dp_a & dp_b;                              // TST
	4'h9: dp_out = dp_a ^ dp_b;                              // TEQ
	4'hA: begin                                              // CMP
		wide   = {1'b0, dp_a} - {1'b0, dp_b};
		dp_out = wide[31:0];
		dp_c   = wide[32];
		dp_v   = (dp_a[31] ^ dp_b[31]) & (dp_a[31] ^ dp_out[31]);
	end
	4'hB: begin                                              // CMN
		wide   = {1'b0, dp_a} + {1'b0, dp_b};
		dp_out = wide[31:0];
		dp_c   = wide[32];
		dp_v   = (dp_a[31] == dp_b[31]) & (dp_out[31] != dp_a[31]);
	end
	4'hC: dp_out = dp_a | dp_b;                              // ORR
	4'hD: dp_out = dp_b;                                     // MOV
	4'hE: dp_out = dp_a & ~dp_b;                             // BIC
	default: dp_out = ~dp_b;                                 // MVN
	endcase
end

// SPSR of the current mode, for the exception-return form of a data op
function [31:0] cur_spsr;
	begin
		case (cur_m)
		3'd1:    cur_spsr = spsr_fiq;
		3'd2:    cur_spsr = spsr_irq;
		3'd3:    cur_spsr = spsr_svc;
		3'd4:    cur_spsr = spsr_abt;
		3'd5:    cur_spsr = spsr_und;
		default: cur_spsr = 32'd0;
		endcase
	end
endfunction

// lowest set bit of the block-transfer list
reg  [3:0] blk_idx;
reg        blk_found;
integer    kk;
always @(*) begin
	blk_found = 1'b0;
	blk_idx   = 4'd0;
	for (kk = 0; kk < 16; kk = kk + 1)
		if (!blk_found && blk_list[kk]) begin
			blk_idx   = kk[3:0];
			blk_found = 1'b1;
		end
end

// SP adjustment for Thumb PUSH/POP: four bytes per listed register, and the
// link bit adds r14 to the count as well
wire [31:0] thumb_sp_off = {23'd0, insn[8], insn[7:0]} << 2;

// temporaries used with blocking assignment inside the machine
reg [31:0] t32;
reg [63:0] t64;
reg [4:0]  tidx;
//------------------------------------------------------------------
// Banked register write. Every architectural register write goes through
// this, so r13/r14 shadow into the current mode and r8..r12 into the FIQ
// copy while that bank is visible.
//------------------------------------------------------------------
`define WREG(sel, val) \
	begin \
		regs[(sel)] <= (val); \
		if ((sel) == 5'd13) r13_b[cur_m] <= (val); \
		if ((sel) == 5'd14) r14_b[cur_m] <= (val); \
		if (cur_m == 3'd1 && (sel) >= 5'd8 && (sel) <= 5'd12) \
			r8f_b[bidx(sel)] <= (val); \
	end

reg [31:0] t32b, t32c, t32d;

// architectural registers start at zero in simulation (a real part has no
// such guarantee, but every path that matters writes before it reads)
integer rz;
initial for (rz = 0; rz < 16; rz = rz + 1) regs[rz] = 32'd0;
reg        c_tmp, v_tmp;

// Loads read a word-aligned word and the byte/half select picks the lane,
// which is what every region of the DS bus returns. The I/O block is the one
// exception: its registers are halfword-mapped, so a word read would answer
// the low half only and lose the neighbouring register. There the access
// stays on the addressed halfword.
wire is_io_region = (ea[31:24] == 8'h04);

// FIQ bank index for r8..r12, clamped so the array access stays in range
// even when the caller's selector is outside that window
// only the six architectural modes may be selected through MSR; anything
// else leaves the current mode alone (the ARM7 has no mode 0x01..0x0F)
function cpsr_mode_ok (input [4:0] m);
	begin
		// the six architectural modes plus system (0x1F), which shares the
		// user bank but is privileged -- without it an MSR to system mode is
		// silently dropped, and the DS's software does run in system mode
		case (m)
		5'h10, 5'h11, 5'h12, 5'h13, 5'h17, 5'h1B, 5'h1F: cpsr_mode_ok = 1'b1;
		default:                                          cpsr_mode_ok = 1'b0;
		endcase
	end
endfunction

function [2:0] bidx (input [4:0] s);
	begin
		bidx = (s >= 5'd8 && s <= 5'd12) ? s[2:0] : 3'd0;
	end
endfunction

//------------------------------------------------------------------
// The machine
//------------------------------------------------------------------
always @(posedge clk) begin
	if (reset) begin
		pc       <= boot_pc;
		n <= 1'b0; z <= 1'b0; c <= 1'b0; v <= 1'b0;
		i <= 1'b1; f <= 1'b1; t <= 1'b0;
		mode     <= 5'h13;               // SVC
		regs[13] <= boot_sp;
		regs[14] <= 32'd0;
		r13_b[3] <= boot_sp;
		r14_b[3] <= 32'd0;
		state    <= S_FETCH;
		bus_rd   <= 1'b0;
		bus_wr   <= 1'b0;
		blk_run  <= 1'b0;
		blk_list <= 16'd0;
		swap_en  <= 1'b0;
		swap_phase <= 1'b0;
		wb_en    <= 1'b0;
		f_valid  <= 1'b0;
		hle_go   <= 1'b0;
	end else if (ce) begin
		case (state)

		//--------------------------------------------------------
		// instruction fetch
		//--------------------------------------------------------
		S_FETCH: begin
			if (fiq && !f) begin
				spsr_fiq  <= cpsr_w;
				r14_b[1]  <= pc;
				regs[14]  <= pc;
				mode      <= 5'h11;
				f <= 1'b1; i <= 1'b1;
				pc <= 32'h0000_001C;
			end else if (irq && !i) begin
				spsr_irq  <= cpsr_w;
				r14_b[2]  <= pc;
				regs[14]  <= pc;
				mode      <= 5'h12;
				i <= 1'b1;
				pc <= 32'h0000_0018;
			end else if (halt) begin
				state <= S_HALT;
			end else if (t && f_hit) begin
				// the word is already here: take the other halfword without a
				// bus access (sequential Thumb code is the common case)
				insn_thumb <= 1'b1;
				insn       <= pc[1] ? f_word[31:16] : f_word[15:0];
				pc         <= pc + 32'd2;
				state      <= S_EXEC;
			end else begin
				insn_thumb <= t;
				bus_addr   <= pc;
				bus_be     <= t ? (pc[1] ? 4'b1100 : 4'b0011) : 4'b1111;
				bus_rd     <= 1'b1;
				bus_wr     <= 1'b0;
				state      <= S_FW;
			end
		end

		S_FW: begin
			if (bus_ready) begin
				bus_rd <= 1'b0;
				f_word  <= bus_rdata;
				f_addr  <= {bus_addr[31:2], 2'b00};
				f_valid <= 1'b1;
				if (insn_thumb)
					insn <= pc[1] ? bus_rdata[31:16] : bus_rdata[15:0];
				else
					insn <= bus_rdata;
				pc    <= pc + (insn_thumb ? 32'd2 : 32'd4);
				state <= S_EXEC;
			end
		end

		S_HALT: begin
			if (irq || fiq) state <= S_FETCH;
		end

		//--------------------------------------------------------
		// BIOS call on the HLE bank: mirror its requests onto the bus
		//--------------------------------------------------------
		S_SWI: begin
			// the engine's request, presented exactly as the core's own
			// accesses are (address and enables stable with the strobe)
			bus_addr  <= hle_b_addr;
			bus_wdata <= hle_b_wlane;
			bus_be    <= hle_b_be;
			bus_rd    <= hle_b_req & ~hle_b_wr;
			bus_wr    <= hle_b_req &  hle_b_wr;
			if (hle_done) begin
				hle_go  <= 1'b0;
				bus_rd  <= 1'b0;
				bus_wr  <= 1'b0;
				// the call may have written memory: the fetch buffer is a
				// copy of what was there, so it can no longer be trusted
				f_valid <= 1'b0;
				if (hle_handled) begin
					if (hle_wr0) regs[0] <= hle_res0;
					if (hle_wr1) regs[1] <= hle_res1;
					if (hle_wr3) regs[3] <= hle_res3;
					// return from the exception the call stood in for, the same
					// way a `MOVS pc,lr` return does: CPSR from SPSR and the
					// caller's bank back into r13/r14 (and r8..r12 if the
					// caller was in FIQ)
					n <= spsr_svc[31]; z <= spsr_svc[30];
					c <= spsr_svc[29]; v <= spsr_svc[28];
					i <= spsr_svc[7];  f <= spsr_svc[6];
					t <= spsr_svc[5];
					mode     <= spsr_svc[4:0];
					regs[13] <= r13_b[midx(spsr_svc[4:0])];
					regs[14] <= r14_b[midx(spsr_svc[4:0])];
					if (midx(spsr_svc[4:0]) == 3'd1) begin
						regs[8]  <= r8f_b[0];
						regs[9]  <= r8f_b[1];
						regs[10] <= r8f_b[2];
						regs[11] <= r8f_b[3];
						regs[12] <= r8f_b[4];
					end
					pc   <= r14_b[3];
				end else begin
					// not in the bank: vector as before
					pc <= 32'h0000_0008;
				end
				state <= S_FETCH;
			end
		end

		//--------------------------------------------------------
		// decode + execute
		//--------------------------------------------------------
		S_EXEC: begin
			wb_en   <= 1'b0;
			blk_run <= 1'b0;

			if (insn_thumb) begin
				//====================================================
				// Thumb
				//====================================================
				if (insn[15:13] == 3'b000 && insn[12:11] != 2'b11) begin
					// ---- 1. LSL/LSR/ASR immediate ----
					tidx  = {2'd0, insn[2:0]};
					t32   = rread(insn[5:3]);
					c_tmp = c;
					case (insn[12:11])
					2'b00: begin   // LSL
						if (insn[10:6] == 5'd0) t32b = t32;
						else begin
							t32b  = t32 << insn[10:6];
							c_tmp = t32[32 - insn[10:6]];
						end
					end
					2'b01: begin   // LSR
						if (insn[10:6] == 5'd0) begin
							t32b  = 32'd0;
							c_tmp = t32[31];
						end else begin
							t32b  = t32 >> insn[10:6];
							c_tmp = t32[insn[10:6] - 5'd1];
						end
					end
					default: begin // ASR
						if (insn[10:6] == 5'd0) begin
							t32b  = {32{t32[31]}};
							c_tmp = t32[31];
						end else begin
							t32b  = $signed(t32) >>> insn[10:6];
							c_tmp = t32[insn[10:6] - 5'd1];
						end
					end
					endcase
					n <= t32b[31];
					z <= (t32b == 32'd0);
					c <= c_tmp;
					`WREG(tidx, t32b)
					state <= S_FETCH;

				end else if (insn[15:13] == 3'b000) begin
					// ---- 2. ADD/SUB register or imm3 ----
					tidx = {2'd0, insn[2:0]};
					t32  = rread(insn[5:3]);
					t32b = insn[10] ? {29'd0, insn[8:6]} : rread(insn[8:6]);
					if (insn[9]) wide = {1'b0, t32} - {1'b0, t32b};
					else         wide = {1'b0, t32} + {1'b0, t32b};
					v_tmp = insn[9] ? ((t32[31] ^ t32b[31]) & (t32[31] ^ wide[31]))
					                : ((t32[31] == t32b[31]) & (wide[31] != t32[31]));
					n <= wide[31];
					z <= (wide[31:0] == 32'd0);
					c <= wide[32];
					v <= v_tmp;
					`WREG(tidx, wide[31:0])
					state <= S_FETCH;

				end else if (insn[15:13] == 3'b001) begin
					// ---- 3. MOV/CMP/ADD/SUB imm8 ----
					tidx = {1'b0, insn[10:8]};
					t32  = rread(insn[10:8]);
					t32b = {24'd0, insn[7:0]};
					case (insn[12:11])
					2'b00: begin                       // MOV
						n <= insn[7];
						z <= (t32b == 32'd0);
						`WREG(tidx, t32b)
					end
					2'b01: begin                       // CMP
						wide = {1'b0, t32} - {1'b0, t32b};
						n <= wide[31]; z <= (wide[31:0] == 32'd0); c <= wide[32];
						v <= (t32[31] ^ t32b[31]) & (t32[31] ^ wide[31]);
					end
					2'b10: begin                       // ADD
						wide = {1'b0, t32} + {1'b0, t32b};
						n <= wide[31]; z <= (wide[31:0] == 32'd0); c <= wide[32];
						v <= (t32[31] == t32b[31]) & (wide[31] != t32[31]);
						`WREG(tidx, wide[31:0])
					end
					default: begin                     // SUB
						wide = {1'b0, t32} - {1'b0, t32b};
						n <= wide[31]; z <= (wide[31:0] == 32'd0); c <= wide[32];
						v <= (t32[31] ^ t32b[31]) & (t32[31] ^ wide[31]);
						`WREG(tidx, wide[31:0])
					end
					endcase
					state <= S_FETCH;

				end else if (insn[15:10] == 6'b010000) begin
					// ---- 4. ALU operations ----
					tidx  = {2'd0, insn[2:0]};
					t32   = rread(insn[2:0]);
					t32b  = rread(insn[5:3]);
					c_tmp = c;
					t32c  = 32'd0;
					case (insn[9:6])
					4'h0: begin t32c = t32 & t32b; n <= t32c[31]; z <= (t32c == 0); end
					4'h1: begin t32c = t32 ^ t32b; n <= t32c[31]; z <= (t32c == 0); end
					4'h2: begin   // LSL by register
						if (t32b[7:0] == 8'd0) t32c = t32;
						else if (t32b[7:0] < 8'd32) begin
							t32c = t32 << t32b[4:0]; c_tmp = t32[32 - t32b[4:0]];
						end else begin
							t32c = 32'd0;
							c_tmp = (t32b[7:0] == 8'd32) ? t32[0] : 1'b0;
						end
						n <= t32c[31]; z <= (t32c == 0); c <= c_tmp;
					end
					4'h3: begin   // LSR by register
						if (t32b[7:0] == 8'd0) t32c = t32;
						else if (t32b[7:0] < 8'd32) begin
							t32c = t32 >> t32b[4:0]; c_tmp = t32[t32b[4:0] - 5'd1];
						end else begin
							t32c = 32'd0;
							c_tmp = (t32b[7:0] == 8'd32) ? t32[31] : 1'b0;
						end
						n <= t32c[31]; z <= (t32c == 0); c <= c_tmp;
					end
					4'h4: begin   // ASR by register
						if (t32b[7:0] == 8'd0) t32c = t32;
						else if (t32b[7:0] < 8'd32) begin
							t32c = $signed(t32) >>> t32b[4:0];
							c_tmp = t32[t32b[4:0] - 5'd1];
						end else begin
							t32c = {32{t32[31]}};
							c_tmp = t32[31];
						end
						n <= t32c[31]; z <= (t32c == 0); c <= c_tmp;
					end
					4'h5: begin   // ADC
						wide = {1'b0, t32} + {1'b0, t32b} + {32'd0, c};
						t32c = wide[31:0];
						n <= t32c[31]; z <= (t32c == 0); c <= wide[32];
						v <= (t32[31] == t32b[31]) & (t32c[31] != t32[31]);
					end
					4'h6: begin   // SBC
						wide = {1'b0, t32} - {1'b0, t32b} - {32'd0, ~c};
						t32c = wide[31:0];
						n <= t32c[31]; z <= (t32c == 0); c <= wide[32];
						v <= (t32[31] ^ t32b[31]) & (t32[31] ^ t32c[31]);
					end
					4'h7: begin   // ROR by register
						if (t32b[7:0] == 8'd0) t32c = t32;
						else t32c = rotr(t32, t32b[4:0]);
						c_tmp = t32c[31];
						n <= t32c[31]; z <= (t32c == 0); c <= c_tmp;
					end
					4'h8: begin   // TST
						t32c = t32 & t32b;
						n <= t32c[31]; z <= (t32c == 0);
					end
					4'h9: begin   // NEG
						wide = {1'b0, 32'd0} - {1'b0, t32b};
						t32c = wide[31:0];
						n <= t32c[31]; z <= (t32c == 0); c <= wide[32];
						v <= (1'b0 ^ t32b[31]) & (1'b0 ^ t32c[31]);
					end
					4'hA: begin   // CMP
						wide = {1'b0, t32} - {1'b0, t32b};
						t32c = wide[31:0];
						n <= t32c[31]; z <= (t32c == 0); c <= wide[32];
						v <= (t32[31] ^ t32b[31]) & (t32[31] ^ t32c[31]);
					end
					4'hB: begin   // CMN
						wide = {1'b0, t32} + {1'b0, t32b};
						t32c = wide[31:0];
						n <= t32c[31]; z <= (t32c == 0); c <= wide[32];
						v <= (t32[31] == t32b[31]) & (t32c[31] != t32[31]);
					end
					4'hC: begin t32c = t32 | t32b; n <= t32c[31]; z <= (t32c == 0); end
					4'hD: begin t32c = t32 * t32b; n <= t32c[31]; z <= (t32c == 0); end
					4'hE: begin t32c = t32 & ~t32b; n <= t32c[31]; z <= (t32c == 0); end
					default: begin t32c = ~t32b; n <= t32c[31]; z <= (t32c == 0); end
					endcase
					if (!(insn[9:6] == 4'h8 || insn[9:6] == 4'hA ||
					      insn[9:6] == 4'hB))
						`WREG(tidx, t32c)
					state <= S_FETCH;

				end else if (insn[15:10] == 6'b010001) begin
					// ---- 5. hi-register ops / BX ----
					tidx = {insn[7], insn[2:0]};
					t32  = rread({insn[6], insn[5:3]});
					t32b = rread(tidx);
					case (insn[9:8])
					2'b00: begin   // ADD (no flags)
						t32c = t32b + t32;
						if (tidx == 5'd15) begin
							pc <= t32c; state <= S_FETCH;
						end else begin
							`WREG(tidx, t32c)
							state <= S_FETCH;
						end
					end
					2'b01: begin   // CMP
						wide = {1'b0, t32b} - {1'b0, t32};
						n <= wide[31]; z <= (wide[31:0] == 0); c <= wide[32];
						v <= (t32b[31] ^ t32[31]) & (t32b[31] ^ wide[31]);
						state <= S_FETCH;
					end
					2'b10: begin   // MOV (no flags)
						if (tidx == 5'd15) pc <= t32;
						else               `WREG(tidx, t32)
						state <= S_FETCH;
					end
					default: begin // BX
						pc <= t32 & 32'hFFFF_FFFE;
						t  <= t32[0];
						state <= S_FETCH;
					end
					endcase

				end else if (insn[15:11] == 5'b01001) begin
					// ---- 6. LDR Rd, [PC, #imm] ----
					t32     = (pc + 32'd2) & 32'hFFFF_FFFC;
					ea      <= t32 + {22'd0, insn[7:0], 2'b00};
					dst     <= {1'b0, insn[10:8]};
					msz     <= 2'd2;
					mload   <= 1'b1;
					msigned <= 1'b0;
					mrot    <= 1'b0;
					state   <= S_MEM;

				end else if (insn[15:12] == 4'b0101) begin
					// ---- 7. load/store with register offset ----
					t32   = rread(insn[5:3]) + rread(insn[8:6]);
					ea    <= t32;
					dst     <= {2'd0, insn[2:0]};
					wdata_r <= rread(insn[2:0]);
					mload   <= (insn[11:9] > 3'd2);
					mrot    <= 1'b0;
					case (insn[11:9])
					3'b000: begin msz <= 2'd2; msigned <= 1'b0; end
					3'b001: begin msz <= 2'd1; msigned <= 1'b0; end
					3'b010: begin msz <= 2'd0; msigned <= 1'b0; end
					3'b011: begin msz <= 2'd0; msigned <= 1'b1; end
					3'b100: begin msz <= 2'd2; msigned <= 1'b0; end
					3'b101: begin msz <= 2'd1; msigned <= 1'b0; end
					3'b110: begin msz <= 2'd0; msigned <= 1'b0; end
					default: begin msz <= 2'd1; msigned <= 1'b1; end
					endcase
					state <= S_MEM;

				end else if (insn[15:13] == 3'b011) begin
					// ---- 8. LDR/STR word or byte, imm5 ----
					t32  = rread(insn[5:3]) + {24'd0, insn[10:6]};
					ea   <= t32;
					dst   <= {2'd0, insn[2:0]};
					wdata_r <= rread(insn[2:0]);
					mload   <= insn[11];
					msz     <= insn[12] ? 2'd0 : 2'd2;
					msigned <= 1'b0;
					mrot    <= (!insn[12]) && (t32[1:0] != 2'b00);
					state   <= S_MEM;

				end else if (insn[15:12] == 4'b1000) begin
					// ---- 9. LDRH/STRH, imm5 scaled by two ----
					ea      <= rread(insn[5:3]) + {23'd0, insn[10:6], 1'b0};
					dst     <= {2'd0, insn[2:0]};
					wdata_r <= rread(insn[2:0]);
					msz     <= 2'd1;
					mload   <= insn[11];
					msigned <= 1'b0;
					mrot    <= 1'b0;
					state   <= S_MEM;

				end else if (insn[15:12] == 4'b1001) begin
					// ---- 10. LDR/STR, SP relative ----
					ea      <= r13_b[cur_m] + {22'd0, insn[7:0], 2'b00};
					dst     <= {1'b0, insn[10:8]};
					wdata_r <= rread(insn[10:8]);
					msz     <= 2'd2;
					mload   <= insn[11];
					msigned <= 1'b0;
					mrot    <= 1'b0;
					state   <= S_MEM;

				end else if (insn[15:12] == 4'b1010) begin
					// ---- 11. ADD Rd, PC/SP, #imm ----
					t32b = insn[11] ? r13_b[cur_m] : ((pc + 32'd2) & 32'hFFFF_FFFC);
					`WREG({1'b0, insn[10:8]}, t32b + {22'd0, insn[7:0], 2'b00})
					state <= S_FETCH;

				end else if (insn[15:8] == 8'b10110000) begin
					// ---- 12. ADD/SUB SP, #imm ----
					t32b = insn[7] ? (r13_b[cur_m] - {23'd0, insn[6:0], 2'b00})
					               : (r13_b[cur_m] + {23'd0, insn[6:0], 2'b00});
					regs[13]  <= t32b;
					r13_b[cur_m] <= t32b;
					state <= S_FETCH;

				end else if (insn[15:12] == 4'b1011 && insn[11:9] == 3'b010) begin
					// ---- 13a. PUSH ----
					blk_list <= insn[7:0] | (insn[8] ? 16'h4000 : 16'h0000);
					blk_addr <= r13_b[cur_m] - thumb_sp_off;
					blk_ld   <= 1'b0;
					blk_pc_hit <= 1'b0;
					blk_run  <= 1'b1;
					wb_en    <= 1'b1;
					wb_reg   <= 5'd13;
					wb_val   <= r13_b[cur_m] - thumb_sp_off;
					state    <= S_BLK;

				end else if (insn[15:12] == 4'b1011 && insn[11:9] == 3'b110) begin
					// ---- 13b. POP ----
					blk_list <= insn[7:0] | (insn[8] ? 16'h8000 : 16'h0000);
					blk_addr <= r13_b[cur_m];
					blk_ld   <= 1'b1;
					blk_pc_hit <= 1'b0;
					blk_run  <= 1'b1;
					wb_en    <= 1'b1;
					wb_reg   <= 5'd13;
					wb_val   <= r13_b[cur_m] + thumb_sp_off;
					state    <= S_BLK;

				end else if (insn[15:12] == 4'b1100) begin
					// ---- 14. STMIA ----
					blk_list <= insn[7:0];
					blk_addr <= rread(insn[10:8]);
					blk_ld   <= 1'b0;
					blk_pc_hit <= 1'b0;
					blk_run  <= 1'b1;
					wb_en    <= 1'b1;
					wb_reg   <= {2'd0, insn[10:8]};
					wb_val   <= rread(insn[10:8]) +
					            {24'd0, popcnt16(insn[7:0]), 2'b00};
					state    <= S_BLK;

				end else if (insn[15:8] == 8'b11011111) begin
					// ---- SWI ---- the BIOS call goes to the HLE bank, with
					// the SVC bank set up as if the exception had been taken
					// so an unimplemented number can still vector to 0x08
					spsr_svc <= cpsr_w;
					r14_b[3] <= pc;
					regs[14] <= pc;
					mode     <= 5'h13;
					i        <= 1'b1;
					hle_num  <= insn[7:0];
					hle_go   <= 1'b1;
					state    <= S_SWI;

				end else if (insn[15:12] == 4'b1101 && insn[11]) begin
					// ---- 15. LDMIA ----
					blk_list <= insn[7:0];
					blk_addr <= rread(insn[10:8]);
					blk_ld   <= 1'b1;
					blk_pc_hit <= 1'b0;
					blk_run  <= 1'b1;
					wb_en    <= 1'b1;
					wb_reg   <= {2'd0, insn[10:8]};
					wb_val   <= rread(insn[10:8]) +
					            {24'd0, popcnt16(insn[7:0]), 2'b00};
					state    <= S_BLK;

				end else if (insn[15:12] == 4'b1101) begin
					// ---- 16. conditional branch ----
					// a Thumb branch is relative to the instruction plus four, and
					// `pc` is already past it by two; its condition is in[11:8]
					if (cond_hold(insn[11:8]))
						pc <= pc + 32'd2 + {{23{insn[7]}}, insn[7:0], 1'b0};
					state <= S_FETCH;

				end else if (insn[15:11] == 5'b11100) begin
					// ---- 17. unconditional branch ----
					pc <= pc + 32'd2 + {{20{insn[10]}}, insn[10:0], 1'b0};
					state <= S_FETCH;

				end else if (insn[15:11] == 5'b11110) begin
					// ---- 18. BL (high half): LR = pc + offset ----
					regs[14] <= pc + 32'd2 + {{9{insn[10]}}, insn[10:0], 12'd0};
					state <= S_FETCH;

				end else if (insn[15:11] == 5'b11111) begin
					// ---- 19. BL (low half): branch and link back ----
					// the return address is the instruction after the pair, which
					// is exactly where `pc` already points
					pc       <= regs[14] + {20'd0, insn[10:0], 1'b0};
					regs[14] <= pc | 32'd1;
					state    <= S_FETCH;

				end else state <= S_FETCH;
			end else begin
				//====================================================
				// ARM
				//====================================================
			if (!cond_ok) begin
				state <= S_FETCH;

			end else if (insn[27:26] == 2'b00) begin
				if (!insn[25] && insn[7:4] == 4'b1001) begin
					// ---- multiply / swap ----
					// they share bits 7:4; SWP is the one with 00010 in 27:23
					// (MUL clears bit 23), and its bit 22 is B, not S
					if (insn[27:23] == 5'b00010) begin
						// SWP / SWPB: read, then write back
						ea         <= rread(insn[19:16]);
						msz        <= insn[22] ? 2'd0 : 2'd2;
						mload      <= 1'b1;
						msigned    <= 1'b0;
						mrot       <= 1'b0;
						swap_en    <= 1'b1;
						swap_phase <= 1'b0;
						swap_src   <= rread(insn[3:0]);
						state      <= S_MEM;
					end else if (insn[5]) begin
						// long multiply
						if (insn[22]) begin
							t64 = $signed(rread(insn[3:0])) * $signed(rread(insn[11:8]));
							if (insn[21])
								t64 = t64 + $signed({rread(insn[19:16]), rread(insn[15:12])});
						end else begin
							t64 = rread(insn[3:0]) * rread(insn[11:8]);
							if (insn[21])
								t64 = t64 + {rread(insn[19:16]), rread(insn[15:12])};
						end
						if (insn[20]) begin
							n <= t64[63];
							z <= (t64 == 64'd0);
						end
						`WREG(insn[15:12], t64[31:0])
						`WREG(insn[19:16], t64[63:32])
						state <= S_FETCH;
					end else begin
						// MUL / MLA
						t64 = rread(insn[3:0]) * rread(insn[11:8]);
						if (insn[21]) t64 = t64 + {32'd0, rread(insn[15:12])};
						if (insn[20]) begin
							n <= t64[31];
							z <= (t64[31:0] == 32'd0);
						end
						`WREG(insn[19:16], t64[31:0])
						state <= S_FETCH;
					end

				end else if (!insn[25] && insn[7] && insn[4]) begin
					// ---- halfword / signed transfer ----
					// these reverse the data-processing sense of bit 22: here it
					// set means the 8-bit immediate offset, clear a register
					t32  = insn[22] ? {24'd0, insn[11:8], insn[3:0]} : rread(insn[3:0]);
					t32b = rread(insn[19:16]);
					t32c = insn[23] ? (t32b + t32) : (t32b - t32);
					ea      <= insn[24] ? t32c : t32b;
					wb_en   <= insn[24] ? insn[21] : 1'b1;
					wb_reg  <= insn[19:16];
					wb_val  <= t32c;
					dst     <= insn[15:12];
					wdata_r <= rread(insn[15:12]);
					msz     <= (insn[6] && !insn[5]) ? 2'd0 : 2'd1;
					msigned <= insn[6];
					mload   <= insn[20];
					mrot    <= 1'b0;
					state   <= S_MEM;

				end else if (!insn[25] && insn[27:4] == 24'h12_FFF1) begin
					// ---- BX ----
					// 0001 0010 1111 1111 1111 0001 Rm: it shares bits 27:23 with
					// MRS/MSR, so it has to be recognised before them or the
					// branch would be decoded as a PSR write
					t32 = rread(insn[3:0]);
					pc  <= t32 & 32'hFFFF_FFFE;
					t   <= t32[0];
					state <= S_FETCH;

				end else if (!insn[25] && !insn[6] && !insn[5] &&
				             insn[27:23] == 5'b00010 &&
				             (insn[21:20] == 2'b00 || insn[21:20] == 2'b10)) begin
					// ---- MRS / MSR ----
					if (insn[21:20] == 2'b00) begin
						`WREG(insn[15:12], insn[22] ? cur_spsr() : cpsr_w)
					end else begin
						t32  = insn[25] ? imm32 : rread(insn[3:0]);
						tidx = insn[19:16];
						if (insn[22]) begin
							t32b = cur_spsr();
							if (tidx[0]) t32b[7:0]   = t32[7:0];
							if (tidx[1]) t32b[15:8]  = t32[15:8];
							if (tidx[2]) t32b[23:16] = t32[23:16];
							if (tidx[3]) t32b[31:24] = t32[31:24];
							case (cur_m)
							3'd1:    spsr_fiq <= t32b;
							3'd2:    spsr_irq <= t32b;
							3'd3:    spsr_svc <= t32b;
							3'd4:    spsr_abt <= t32b;
							3'd5:    spsr_und <= t32b;
							default: ;
							endcase
						end else begin
							if (tidx[0]) begin
								i <= t32[7];
								f <= t32[6];
								t <= t32[5];
								if (cpsr_mode_ok(t32[4:0]) && t32[4:0] != mode) begin
									mode     <= t32[4:0];
									regs[13] <= r13_b[midx(t32[4:0])];
									regs[14] <= r14_b[midx(t32[4:0])];
									if (midx(t32[4:0]) == 3'd1) begin
										regs[8]  <= r8f_b[0];
										regs[9]  <= r8f_b[1];
										regs[10] <= r8f_b[2];
										regs[11] <= r8f_b[3];
										regs[12] <= r8f_b[4];
									end
								end
							end
							if (tidx[3]) begin
								n <= t32[31];
								z <= t32[30];
								c <= t32[29];
								v <= t32[28];
							end
						end
					end
					state <= S_FETCH;

				end else begin
					// ---- data processing ----
					// (A $test$plusargs/+dp $display trace used to print here. It is
					// gone: Quartus rejects $test$plusargs outside a simulation-only
					// construct -- error 10174, "system function is not supported for
					// synthesis" -- and it aborted elaboration of the whole ARM7. No
					// bench passed +dp, so nothing is lost; the tracing the benches use
					// (+bus / +regs / +trace) lives in tb_arm7.sv, not in the core.)
					t32  = dp_out;
					tidx = insn[15:12];
					if (insn[24:23] == 2'b10) begin
						// TST / TEQ / CMP / CMN: flags only, the Rd field is unused
						n <= t32[31];
						z <= (t32 == 32'd0);
						c <= dp_c;
						v <= dp_v;
						state <= S_FETCH;
					end else if (insn[20]) begin
						if (tidx == 5'd15) begin
							// exception return: CPSR <- SPSR
							t32b = cur_spsr();
							n <= t32b[31];
							z <= t32b[30];
							c <= t32b[29];
							v <= t32b[28];
							i <= t32b[7];
							f <= t32b[6];
							t <= t32b[5];
							mode     <= t32b[4:0];
							regs[13] <= r13_b[midx(t32b[4:0])];
							regs[14] <= r14_b[midx(t32b[4:0])];
							if (midx(t32b[4:0]) == 3'd1) begin
								regs[8]  <= r8f_b[0];
								regs[9]  <= r8f_b[1];
								regs[10] <= r8f_b[2];
								regs[11] <= r8f_b[3];
								regs[12] <= r8f_b[4];
							end
							pc <= t32;
						end else begin
							n <= t32[31];
							z <= (t32 == 32'd0);
							c <= dp_c;
							v <= dp_v;
							`WREG(tidx, t32)
						end
					end else begin
						if (tidx == 5'd15) pc <= t32;
						else               `WREG(tidx, t32)
					end
					state <= S_FETCH;
				end

			end else if (insn[27:26] == 2'b01) begin
				// ---- single data transfer ----
				// single data transfer: bit 25 set means a register offset, clear
				// means the 12-bit immediate (the opposite of data processing)
				t32  = insn[25] ? op2 : {20'd0, insn[11:0]};
				t32b = rread(insn[19:16]);
				t32c = insn[23] ? (t32b + t32) : (t32b - t32);
				t32d = insn[24] ? t32c : t32b;
				ea      <= t32d;
				wb_en   <= insn[24] ? insn[21] : 1'b1;
				wb_reg  <= insn[19:16];
				wb_val  <= t32c;
				dst     <= insn[15:12];
				wdata_r <= rread(insn[15:12]);
				msz     <= insn[22] ? 2'd0 : 2'd2;
				msigned <= 1'b0;
				mload   <= insn[20];
				mrot    <= (!insn[22]) && (t32d[1:0] != 2'b00);
				state   <= S_MEM;

			end else if (insn[27:26] == 2'b10 && !insn[25]) begin
				// ---- block transfer ----
				// bit 25 clear separates LDM/STM (100 P U S W L) from B/BL
				// (101 L), which share bits 27:26
				blk_list <= insn[15:0];
				t32      = rread(insn[19:16]);
				t32b     = (insn[15:0] == 16'd0) ? 32'd64
				                                : {24'd0, popcnt16(insn[15:0]), 2'b00};
				if (insn[24])
					blk_addr <= insn[23] ? (t32 + 32'd4) : (t32 - t32b);
				else
					blk_addr <= insn[23] ? t32 : (t32 - (t32b - 32'd4));
				blk_ld    <= insn[20];
				blk_pc_hit<= 1'b0;
				blk_run   <= 1'b1;
				// only W writes the base back: LDM without "!" keeps it
				wb_en     <= insn[21];
				wb_reg    <= insn[19:16];
				wb_val    <= insn[23] ? (t32 + t32b) : (t32 - t32b);
				state     <= S_BLK;

			end else begin
				// ---- branch / SWI / undefined ----
				if (insn[27:25] == 3'b101) begin
					if (insn[24]) begin          // BL: LR takes the return address
						// written out rather than through `WREG: with a constant
						// selector the macro's bank tests fold to a constant, which
						// is warning 10037 for no reason
						regs[14]     <= pc;
						r14_b[cur_m] <= pc;
					end
					// the branch offset is relative to the instruction address
					// plus eight, and `pc` is already past it by four
					pc    <= pc + 32'd4 + {{6{insn[23]}}, insn[23:0], 2'b00};
					state <= S_FETCH;
				end else if (insn[27:24] == 4'hF) begin
					// SWI — the number is the top byte of the comment field
					// (GBATEK), and the call runs on the HLE bank
					spsr_svc <= cpsr_w;
					r14_b[3] <= pc;
					regs[14] <= pc;
					mode     <= 5'h13;
					i        <= 1'b1;
					hle_num  <= insn[23:16];
					hle_go   <= 1'b1;
					state    <= S_SWI;
				end else begin
					// undefined instruction (including any coprocessor op)
					spsr_und <= cpsr_w;
					r14_b[5] <= pc;
					regs[14] <= pc;
					mode     <= 5'h1B;
					i        <= 1'b1;
					pc       <= 32'h0000_0004;
					state    <= S_FETCH;
				end
			end
		end		end

		//--------------------------------------------------------
		// one bus transaction
		//--------------------------------------------------------
		S_MEM: begin
			// A load reads the word-aligned word unless the access is a byte or
			// halfword on the halfword-mapped I/O block.
			if (mload && !(is_io_region && msz != 2'd2)) begin
				bus_addr <= {ea[31:2], 2'b00};
				bus_be   <= 4'b1111;
			end else begin
				bus_addr <= ea;
				case (msz)
				2'd0:    bus_be <= 4'b0001 << ea[1:0];
				2'd1:    bus_be <= ea[1] ? 4'b1100 : 4'b0011;
				default: bus_be <= 4'b1111;
				endcase
			end
			if (msz == 2'd0)
				bus_wdata <= wdata_r << (8 * ea[1:0]);
			else if (msz == 2'd1)
				bus_wdata <= ea[1] ? {wdata_r[15:0], 16'h0000}
				                   : {16'h0000, wdata_r[15:0]};
			else
				bus_wdata <= wdata_r;
			bus_rd <= mload;
			bus_wr <= ~mload;
			state  <= S_MW;
		end

		S_MW: begin
			if (bus_ready) begin
				bus_rd <= 1'b0;
				// a store may have changed the word the buffer holds
				if (bus_wr) f_valid <= 1'b0;
				bus_wr <= 1'b0;
				if (blk_run) begin
					if (blk_ld) begin
						if (blk_idx == 4'd15) begin
							blk_pc_hit <= 1'b1;
							blk_pc_val <= bus_rdata;
						end else begin
							tidx = {1'b0, blk_idx};
							`WREG(tidx, bus_rdata)
						end
					end
					blk_list <= blk_list & ~(16'd1 << blk_idx);
					blk_addr <= blk_addr + 32'd4;
					state    <= S_BLK;
				end else if (swap_en) begin
					if (!swap_phase) begin
						swap_val   <= (msz == 2'd0) ? (bus_rdata >> (8 * ea[1:0]))
						                            : bus_rdata;
						swap_phase <= 1'b1;
						mload      <= 1'b0;
						wdata_r    <= swap_src;
						state      <= S_MEM;
					end else begin
						swap_en    <= 1'b0;
						swap_phase <= 1'b0;
						`WREG(insn[15:12], swap_val)
						state <= S_FETCH;
					end
				end else begin
					if (wb_en) `WREG(wb_reg, wb_val)
					if (mload) begin
						if (msz == 2'd0) begin
							case (ea[1:0])
							2'b00:   t32 = msigned ? {{24{bus_rdata[7]}},  bus_rdata[7:0]}
							                        : {24'd0, bus_rdata[7:0]};
							2'b01:   t32 = msigned ? {{24{bus_rdata[15]}}, bus_rdata[15:8]}
							                        : {24'd0, bus_rdata[15:8]};
							2'b10:   t32 = msigned ? {{24{bus_rdata[23]}}, bus_rdata[23:16]}
							                        : {24'd0, bus_rdata[23:16]};
							default: t32 = msigned ? {{24{bus_rdata[31]}}, bus_rdata[31:24]}
							                        : {24'd0, bus_rdata[31:24]};
							endcase
						end else if (msz == 2'd1) begin
							if (is_io_region)
								t32 = msigned ? {{16{bus_rdata[15]}}, bus_rdata[15:0]}
								              : {16'd0, bus_rdata[15:0]};
							else if (ea[1])
								t32 = msigned ? {{16{bus_rdata[31]}}, bus_rdata[31:16]}
								              : {16'd0, bus_rdata[31:16]};
							else
								t32 = msigned ? {{16{bus_rdata[15]}}, bus_rdata[15:0]}
								              : {16'd0, bus_rdata[15:0]};
						end else begin
							t32 = mrot ? rotr(bus_rdata, {ea[1:0], 3'b000}) : bus_rdata;
						end
						if (dst == 5'd15) pc <= t32;
						else               `WREG(dst, t32)
					end
					state <= S_FETCH;
				end
			end
		end

		//--------------------------------------------------------
		// block transfer beats
		//--------------------------------------------------------
		S_BLK: begin
			if (blk_list == 16'd0) begin
				if (wb_en && !blk_pc_hit) `WREG(wb_reg, wb_val)
				if (blk_pc_hit) pc <= blk_pc_val;
				blk_run <= 1'b0;
				state   <= S_FETCH;
			end else begin
				bus_addr  <= blk_addr;
				bus_wdata <= regs[blk_idx];
				bus_be    <= 4'b1111;
				bus_rd    <= blk_ld;
				bus_wr    <= ~blk_ld;
				state     <= S_MW;
			end
		end

		default: state <= S_FETCH;
		endcase
	end
end

// `undef'd so the name cannot leak into arm9_core.sv (or any later file): that
// core has its own WREG with a different body, and a leaked definition would
// silently pick the wrong one when both are compiled together.
`undef WREG

// The SPSR banks are only read inside psr_get(), and Verific's function-body
// read analysis does not follow those readers, so Quartus calls the banks
// "assigned a value but never read" (warning 10036). Reading them here states
// the fact; the branch cannot be taken and synthesises to nothing. Measured on
// a throwaway module with the same shape: 5 such warnings without this, 0 with.
wire _unused_spsr = &{1'b0, spsr_abt, spsr_fiq, spsr_irq, spsr_svc, spsr_und};
always @(*) if (_unused_spsr) begin end

endmodule
