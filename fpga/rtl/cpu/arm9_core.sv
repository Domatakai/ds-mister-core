//============================================================================
// NDS MiSTer Test — ARM946E-S core (ARMv5TE)
//
// A real ARMv5TE interpreter, not a stub: the ARM and Thumb instruction sets,
// the v5TE media instructions, CP15, the CPSR/SPSR banks and the HALTCNT stop.
// It drives a main-bus master port directly (one access at a time, held until
// `bus_ready`), so what it executes is fetched from the same fabric the games
// use — BIOS mirrors, main RAM or the cart window.
//
// This file is the sibling of arm7_core.sv (the ARM7TDMI core). ARMv5TE adds
// and changes, relative to that core:
//
//   decode   BLX (immediate and register), CLZ, the QADD/QSUB/QDADD/QDSUB
//            family, SMULxy SMLAxy SMULWy SMLAWy SMLALxy (all four halfword
//            combinations), LDRD/STRD (immediate and register), PLD (a hint,
//            executed as a no-op), BKPT, and Thumb BKPT and BLX
//   state    the sticky Q (saturation) flag, CPSR bit 27
//   memory   the DS's alignment rules, which are not ARMv4T's (GBATEK's ARM
//            CPU memory alignments page is the reference): a misaligned LDR
//            reads the aligned word rotated right by 8*address[1:0] and SWP
//            reads rotated but writes unrotated, while a misaligned store, a
//            misaligned LDRH/LDRSH (the GBA's ARM7 rotates those; the ARM9
//            does not), LDRD/STRD and LDM/STM all force-align the address
//   banking  LDM/STM with S=1 use the user-mode registers, and LDM with S=1
//            and R15 in the list restores CPSR from SPSR
//   CP15     MCR/MRC coprocessor 15: main ID and cache type reads, the control
//            register (including the V high-vector bit), translation table
//            base, domain, fault address, cache maintenance and TCM config
//   vectors  undefined 0x04, SWI 0x08, prefetch abort 0x0C, IRQ 0x18, FIQ
//            0x1C, taken at 0x00000000 or (V=1) 0xFFFF0000
//
// Not modelled, deliberately: caches, the MMU/MPU, and TCM *storage*. The
// control register's bits are kept and read back, so software that turns the
// caches on sees what it wrote, but every access still goes to the bus. TCM
// storage would shadow memory the bus already decodes (the vector page, the
// BIOS mirrors and main RAM), so it belongs with the MMU work. Timing is
// functional rather than cycle-accurate, exactly as in the ARM7 core: one bus
// access per fetch and one per load/store beat.
//
// The data-abort vector (0x10) is not entered from anywhere yet — the bus
// cannot report an error and there is no MPU/MMU to raise a translation or
// permission fault. The prefetch abort *is* reachable, from BKPT. As on the
// real part, a prefetch abort leaves LR_abt at the aborting instruction plus
// four in *either* state and does not touch CP15 c6: only a data abort writes
// the fault address register (GBATEK, ARM CPU exceptions; melonDS's ARM9 also
// leaves c6 alone on a prefetch abort). The fault *status* encoding is not
// modelled (c5 stays whatever software wrote).
//
// Reset is the DS's post-BIOS state, because that is where the HLE boot starts
// from: CP15 control = 0x00012078 (DT|V|L|D|P|W, so the vector page is the
// high one at 0xFFFF0000), CP15 c0 reads 0x41059461 (ARM946E-S) and the core
// starts in SVC with I and F set at the cart header's ARM9 entry point.
//============================================================================
module arm9_core #(
	// One-word fetch buffer, inherited from the ARM7 core: the bus answers a
	// whole word, so the second halfword of a Thumb word is already in hand
	// and re-reading it would cost a bus slot the DMA and video engines can
	// use. Invalidated by any store and by a CP15 c7 maintenance write.
	parameter FETCH_BUF = 1
) (
	input             clk,
	input             reset,

	// The ARM9's side of the DS's 2:1 clock ratio: `cpu_ce` drives it, high on
	// every cycle at the native ratio (and on every second one in the OSD's
	// ARM7 x4 mode). The bus path is synchronized by `cpu_ce_bridge`, which
	// holds a response across the cycles this core is gated off.
	input             ce,

	// HLE boot: cart header ARM9 entry point, and the stack the firmware
	// leaves behind (GBATEK: 0x03002F7C)
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
	input             irq,        // IME & (IE & IF) of the ARM9 bank
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
reg [31:0] pc;
reg        n, z, c, v, q, i, f, t;
reg  [4:0] mode;

// banked r13/r14 (0 usr/sys, 1 fiq, 2 irq, 3 svc, 4 abt, 5 und)
reg [31:0] r13_b [0:5];
reg [31:0] r14_b [0:5];
// r8..r12 exist in two banks: the FIQ set and the user set. Only one of them
// is visible in `regs`, so the other one has to be kept separately — that is
// what the ARM7 core was missing, and what makes LDM/STM with the ^ bit (and
// an FIQ handler that returns) work.
reg [31:0] r8f_b [0:4];
reg [31:0] r8u_b [0:4];
// banked SPSRs
reg [31:0] spsr_fiq, spsr_irq, spsr_svc, spsr_abt, spsr_und;

//------------------------------------------------------------------
// CP15
//
// cp15_r is indexed by CRn. The one register with two opcode_2 halves gets a
// second slot: c1/op2=0 is the control register, c1/op2=1 the auxiliary
// control register.
//------------------------------------------------------------------
reg [31:0] cp15_r [0:15];
reg [31:0] cp15_aux;
// reset values, and the two read-only identification values (ARM946E-S: the
// ID decodes as architecture 5TE, part 0x946, revision 1; the cache type
// decodes as 4 KB four-way data and 8 KB four-way instruction caches, which is
// what GBATEK lists for the DS ARM9)
localparam [31:0] CP15_RESET_CTRL = 32'h0001_2078;
localparam [31:0] CP15_ID         = 32'h4105_9461;
localparam [31:0] CP15_CACHETYPE  = 32'h0F0D_2112;

// V (bit 13) moves the exception vectors to 0xFFFF0000
wire [31:0] vbase = cp15_r[1][13] ? 32'hFFFF_0000 : 32'h0000_0000;

reg [31:0] insn;
reg        insn_thumb;

// memory transaction
reg [31:0] ea;
reg  [1:0] msz;         // 0 byte, 1 halfword, 2 word
reg        mload;
reg        msigned;
reg        mrot;
reg [31:0] wdata_r;
reg  [4:0] dst;
reg        wb_en;
reg  [4:0] wb_reg;
reg [31:0] wb_val;

// swap
reg        swap_en, swap_phase;
reg [31:0] swap_src, swap_val;

// block transfer
reg        blk_run, blk_ld, blk_pc_hit;
reg        blk_usr;            // S=1: the user-mode register bank
reg        blk_restore;        // LDM with S=1 and R15 in the list
reg  [15:0] blk_list;
reg [31:0] blk_addr, blk_pc_val;

// doubleword transfer (LDRD/STRD): two word beats on consecutive addresses
reg        dw_run, dw_phase, dw_ld;
reg  [3:0] dw_rd;
reg [31:0] dw_addr, dw_lo, dw_hi;

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

// fetch buffer: the word the last fetch returned, and whether it is still a
// valid copy of memory (a store or a cache-maintenance write clears it)
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

function [5:0] popcnt16 (input [15:0] v);
	integer j;
	begin
		popcnt16 = 6'd0;
		for (j = 0; j < 16; j = j + 1)
			popcnt16 = popcnt16 + {5'd0, v[j]};
	end
endfunction

// the user-mode bank, for LDM/STM with S=1
function [31:0] rread_user (input [4:0] r);
	begin
		if      (r == 5'd13)                rread_user = r13_b[0];
		else if (r == 5'd14)                rread_user = r14_b[0];
		else if (r >= 5'd8 && r <= 5'd12)   rread_user = r8u_b[r[2:0]];   // 5 entries: 3 bits
		else                                rread_user = regs[r[3:0]];
	end
endfunction

// CLZ needs six bits: 32 is a real answer (a zero operand)
function [5:0] count_lead_zeros (input [31:0] v);
	integer j;
	reg found;
	begin
		found = 1'b0;
		count_lead_zeros = 6'd32;
		for (j = 31; j >= 0; j = j - 1)
			if (!found && v[j]) begin
				// 31 - j leading zeros: the count *before* the top set bit
				count_lead_zeros = 6'd31 - j[5:0];
				found = 1'b1;
			end
	end
endfunction

// only the six architectural modes may be selected through MSR
function cpsr_mode_ok (input [4:0] m);
	begin
		// the six architectural modes plus system: user, FIQ, IRQ, SVC, ABT,
		// UND and SYS (0x1F, which shares the user bank but is privileged,
		// and which real DS code -- and the boot firmware -- does run in)
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

wire [31:0] cpsr_w = {n, z, c, v, q, 19'd0, i, f, t, mode};
wire  [2:0] cur_m  = midx(mode);

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

//------------------------------------------------------------------
// Banked register write. Every architectural register write goes through
// this, so r13/r14 shadow into the current mode and r8..r12 into whichever of
// the two banks is visible.
//------------------------------------------------------------------
`define WREG(sel, val) \
	begin \
		regs[(sel)] <= (val); \
		if ((sel) == 5'd13) r13_b[cur_m] <= (val); \
		if ((sel) == 5'd14) r14_b[cur_m] <= (val); \
		if ((sel) >= 5'd8 && (sel) <= 5'd12) begin \
			if (cur_m == 3'd1) r8f_b[bidx(sel)] <= (val); \
			else               r8u_b[bidx(sel)] <= (val); \
		end \
	end

// the same write, but aimed at the user-mode bank regardless of the current
// mode: the destination of an LDM/STM with S=1
`define WUSR(sel, val) \
	begin \
		if ((sel) == 5'd13)                    r13_b[0] <= (val); \
		else if ((sel) == 5'd14)               r14_b[0] <= (val); \
		else if ((sel) >= 5'd8 && (sel) <= 5'd12) r8u_b[bidx(sel)] <= (val); \
		else                                   regs[(sel)] <= (val); \
	end

// FIQ swaps r8..r12 with the user bank on entry and exit. `nm` is the mode
// being entered, and `cur_m` is still the old one when this runs.
`define SWAP8(nm) \
	begin \
		if (cur_m == 3'd1 && (nm) != 5'h11) begin \
			regs[8]  <= r8u_b[0]; regs[9]  <= r8u_b[1]; regs[10] <= r8u_b[2]; \
			regs[11] <= r8u_b[3]; regs[12] <= r8u_b[4]; \
		end \
		if (cur_m != 3'd1 && (nm) == 5'h11) begin \
			r8u_b[0] <= regs[8];  r8u_b[1] <= regs[9];  r8u_b[2] <= regs[10]; \
			r8u_b[3] <= regs[11]; r8u_b[4] <= regs[12]; \
			regs[8]  <= r8f_b[0]; regs[9]  <= r8f_b[1]; regs[10] <= r8f_b[2]; \
			regs[11] <= r8f_b[3]; regs[12] <= r8f_b[4]; \
		end \
	end

//------------------------------------------------------------------
// The masked PSR write that MSR (register) and MSR (immediate) share.
// `mask` is the field mask from bits 19:16: bit 0 the control field, bit 1 the
// extension field (unused here, the ARM946 has no CPSR_x), bit 2 the status
// field and bit 3 the flags. Bit 27 of the flags field is Q, which only this
// write can clear.
//------------------------------------------------------------------
task psr_write (input [31:0] val, input [3:0] mask, input spsr_sel);
	reg [31:0] tmp;
	begin
		// assigned before the branch: a task-local written only inside it is
		// what Verific reports as warning 10776 ("may have unintended latch
		// behavior"), which is noise here but hides the real ones
		tmp = cur_spsr();
		if (spsr_sel) begin
			if (mask[0]) tmp[7:0]   = val[7:0];
			if (mask[1]) tmp[15:8]  = val[15:8];
			if (mask[2]) tmp[23:16] = val[23:16];
			if (mask[3]) tmp[31:24] = val[31:24];
			case (cur_m)
			3'd1:    spsr_fiq <= tmp;
			3'd2:    spsr_irq <= tmp;
			3'd3:    spsr_svc <= tmp;
			3'd4:    spsr_abt <= tmp;
			3'd5:    spsr_und <= tmp;
			default: ;          // user and system modes have no SPSR
			endcase
		end else begin
			if (mask[0]) begin
				i <= val[7];
				f <= val[6];
				t <= val[5];
				if (cpsr_mode_ok(val[4:0]) && val[4:0] != mode) begin
					`SWAP8(val[4:0])
					mode     <= val[4:0];
					regs[13] <= r13_b[midx(val[4:0])];
					regs[14] <= r14_b[midx(val[4:0])];
				end
			end
			if (mask[3]) begin
				n <= val[31];
				z <= val[30];
				c <= val[29];
				v <= val[28];
				q <= val[27];
			end
		end
	end
endtask

// Exception entry and return, used by every exception and by the S+PC forms.
// Written out once here because the ARM9 has six exception vectors and several
// returns through them.
`define UND \
	begin \
		spsr_und <= cpsr_w; \
		r14_b[5] <= pc; \
		regs[14] <= pc; \
		mode     <= 5'h1B; \
		i        <= 1'b1; \
		t        <= 1'b0; \
		pc       <= vbase + 32'h0000_0004; \
		state    <= S_FETCH; \
	end

// BKPT takes a prefetch abort. LR_abt is the breakpoint plus four in either
// state (PC + 4 in ARM, PC + 2 in Thumb), which is what GBATEK's "R14_abt - 4"
// convention for finding the faulting instruction relies on, and c6 is left
// untouched because only a data abort writes it.
`define PABT(lr) \
	begin \
		spsr_abt  <= cpsr_w; \
		r14_b[4]  <= (lr); \
		regs[14]  <= (lr); \
		mode      <= 5'h17; \
		i         <= 1'b1; \
		t         <= 1'b0; \
		pc        <= vbase + 32'h0000_000C; \
		state     <= S_FETCH; \
	end

// exception return: CPSR <- SPSR, banks switched, pc <- val
`define EXC_RET(val) \
	begin \
		t32b = cur_spsr(); \
		n <= t32b[31]; z <= t32b[30]; c <= t32b[29]; v <= t32b[28]; q <= t32b[27]; \
		i <= t32b[7]; f <= t32b[6]; t <= t32b[5]; \
		`SWAP8(t32b[4:0]) \
		mode     <= t32b[4:0]; \
		regs[13] <= r13_b[midx(t32b[4:0])]; \
		regs[14] <= r14_b[midx(t32b[4:0])]; \
		pc       <= (val); \
		state    <= S_FETCH; \
	end

// Loads read a word-aligned word and the byte/half select picks the lane,
// which is what every region of the DS bus returns. The I/O block is the one
// exception: its registers are halfword-mapped, so a word read would answer
// the low half only and lose the neighbouring register. There the access
// stays on the addressed halfword.
wire is_io_region = (ea[31:24] == 8'h04);

// temporaries used with blocking assignment inside the machine
reg [31:0] t32, t32a, t32b, t32c, t32d, t32e, t32f;
reg [63:0] t64;
reg  [4:0] tidx;
reg        c_tmp, v_tmp;

// architectural registers start at zero in simulation (a real part has no
// such guarantee, but every path that matters writes before it reads)
integer rz;
initial begin
	for (rz = 0; rz < 16; rz = rz + 1) regs[rz] = 32'd0;
	for (rz = 0; rz < 5; rz = rz + 1) begin r8f_b[rz] = 32'd0; r8u_b[rz] = 32'd0; end
	for (rz = 0; rz < 6; rz = rz + 1) begin r13_b[rz] = 32'd0; r14_b[rz] = 32'd0; end
end

//------------------------------------------------------------------
// Operand 2 and the barrel shifter (ARM data processing, and the register
// offset of a single data transfer, which shares the encoding)
//------------------------------------------------------------------
reg  [31:0] op2;
reg         op2_c;
reg  [31:0] sh_in;
reg  [7:0]  sh_amt;

// A combinational block is only sensitive to what it names, and a function's
// internal reads of `regs` are invisible to `always @(*)` -- which is why the
// read ports below (search "The register-file read ports") select the array
// directly instead of going through a function.
wire [31:0] pc_ahead = pc + (insn_thumb ? 32'd2 : 32'd4);

// the four shared read ports: index and data, wired up after blk_idx
reg  [3:0] rp_ia, rp_ib, rp_ic, rp_id;
reg [31:0] rp_a, rp_b, rp_c, rp_d;

// operand 2 and the shifter amount are Rm and Rs, which are insn[3:0] and
// insn[11:8] in every encoding that reads them, so the ports decode them for
// every ARM instruction and each Thumb one names them in the table below
wire [31:0] rm_val = rp_b;
wire [7:0]  rs_amt = rp_c[7:0];

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
		default: cond_hold = 1'b0;   // 0b1111: unconditional space
		endcase
	end
endfunction

wire cond_ok = cond_hold(insn[31:28]);

//------------------------------------------------------------------
// Data processing ALU
//------------------------------------------------------------------
wire [31:0] dp_a = rp_a;
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
//------------------------------------------------------------------------
// The register-file read ports
//------------------------------------------------------------------------
// Four ports serve every register read in the machine, and each port's index
// is decoded from `state` and `insn` alone. What that removes is the point: a
// read whose index is an instruction field makes the synthesiser build a
// 16-entry mux over the register file, and an index written inline at each
// call site builds one mux per field -- eleven of them, 3,875 ALUTs, 21% of
// this core's combinational logic. Four muxes fed by four decoded indices cost
// about a quarter of that, and the register bits fan out to four trees instead
// of eleven, which is what the worst setup path was made of.
//
// The index cannot be a register. The machine assigns its temporaries with
// blocking assignments inside the clocked block, so an index written there
// would be read a delta too late; it has to be a function of `state` and
// `insn`, which is why the decode repeats the FSM's branch conditions.
//
// The ARM side needs almost no branch tests: Rn (19:16), Rm (3:0), Rs (11:8)
// and Rd (15:12) are the four fields every ARM read comes from, so those are
// the defaults and only the halfword/doubleword group's Rd+1 is special. Thumb
// reads three-bit fields, so it does need its table.
//
// R15 reads pc+8 (ARM) or pc+4 (Thumb) rather than the array, exactly as the
// per-site function it replaces did. The index is four bits, which is all a
// 16-entry array needs. (Quartus 17 prints warning 10027 on the variable index
// either way -- for a 4-bit index too, and not for a constant one -- so it is
// not what stops the build; that is the RAM conversion described in NDS.qsf.)
always @(*) begin
	if (rp_ia == 4'd15) rp_a = pc_ahead; else rp_a = regs[rp_ia];
	if (rp_ib == 4'd15) rp_b = pc_ahead; else rp_b = regs[rp_ib];
	if (rp_ic == 4'd15) rp_c = pc_ahead; else rp_c = regs[rp_ic];
	if (rp_id == 4'd15) rp_d = pc_ahead; else rp_d = regs[rp_id];
end

always @(*) begin
	rp_ia = 4'd0; rp_ib = 4'd0; rp_ic = 4'd0; rp_id = 4'd0;
	case (state)
	S_EXEC: begin
		if (insn_thumb) begin
			if (insn[15:13] == 3'b000 && insn[12:11] != 2'b11) begin
				// LSL/LSR/ASR immediate: Rs
				rp_ia = insn[5:3];
			end else if (insn[15:13] == 3'b000) begin
				// ADD/SUB register or imm3: Rs and Rn
				rp_ia = insn[5:3];
				rp_ib = insn[8:6];
			end else if (insn[15:13] == 3'b001) begin
				// MOV/CMP/ADD/SUB imm8: Rd, which is also the source
				rp_ia = insn[10:8];
			end else if (insn[15:10] == 6'b010000) begin
				// ALU operations: Rd and Rs
				rp_ia = insn[2:0];
				rp_ib = insn[5:3];
			end else if (insn[15:10] == 6'b010001) begin
				// hi-register ops / BX: the two five-bit register fields
				rp_ia = {insn[6], insn[5:3]};
				rp_ib = {insn[7], insn[2:0]};
			end else if (insn[15:12] == 4'b0101) begin
				// load/store with register offset: base, offset, data
				rp_ia = insn[5:3];
				rp_ib = insn[8:6];
				rp_ic = insn[2:0];
			end else if (insn[15:13] == 3'b011) begin
				// LDR/STR word or byte, imm5: base and data
				rp_ia = insn[5:3];
				rp_ic = insn[2:0];
			end else if (insn[15:12] == 4'b1000) begin
				// LDRH/STRH, imm5: base and data
				rp_ia = insn[5:3];
				rp_ic = insn[2:0];
			end else if (insn[15:12] == 4'b1001) begin
				// LDR/STR, SP relative: data
				rp_ic = insn[10:8];
			end else if (insn[15:12] == 4'b1100 ||
			             (insn[15:12] == 4'b1101 && insn[11])) begin
				// STMIA / LDMIA: base
				rp_ia = insn[10:8];
			end
		end else begin
			// ARM: Rn, Rm, Rs, Rd -- every field an ARM read comes from
			rp_ia = insn[19:16];
			rp_ib = insn[3:0];
			rp_ic = insn[11:8];
			rp_id = insn[15:12];
			if (insn[27:26] == 2'b00 && !insn[25] && insn[4] &&
			    (insn[7:5] == 3'b101 || insn[7:5] == 3'b110 ||
			     insn[7:5] == 3'b111)) begin
				// halfword / signed / doubleword transfers read the pair Rd,
				// Rd+1, and Rd+1 is the one index that is not an insn field
				rp_ic = insn[15:12] + 4'd1;
			end
		end
	end
	S_BLK: rp_ia = blk_idx;
	default: begin rp_ia = 4'd0; rp_ib = 4'd0; rp_ic = 4'd0; rp_id = 4'd0; end
	endcase
end

wire [31:0] thumb_sp_off = {23'd0, insn[8], insn[7:0]} << 2;

//------------------------------------------------------------------
// CP15 read value (MRC) and the address/opcode fields shared with MCR
//------------------------------------------------------------------
wire        cp15_sel = (insn[11:8] == 4'hF);
wire        cp15_rd  =  insn[20];
wire  [3:0] cp15_crn = insn[19:16];
wire  [2:0] cp15_op2 = insn[7:5];

reg [31:0] cprd;
always @(*) begin
	case (cp15_crn)
	// c0 is read-only: opcode_2 0 is the main ID, 1 the cache type
	4'h0:    cprd = (cp15_op2 == 3'd0) ? CP15_ID :
	                (cp15_op2 == 3'd1) ? CP15_CACHETYPE : 32'd0;
	// c7 maintenance is write-only
	4'h7:    cprd = 32'd0;
	// c1 opcode_2 1 is the auxiliary control register
	4'h1:    cprd = (cp15_op2 == 3'd1) ? cp15_aux : cp15_r[1];
	default: cprd = cp15_r[cp15_crn];
	endcase
end

//------------------------------------------------------------------
// The machine
//------------------------------------------------------------------
integer rk;
// set by the first halfword of a Thumb BLX and consumed by the second
reg bl_pending;   // seen the high half of a Thumb BL/BLX pair

always @(posedge clk) begin
	if (reset) begin
		pc       <= boot_pc;
		n <= 1'b0; z <= 1'b0; c <= 1'b0; v <= 1'b0; q <= 1'b0;
		i <= 1'b1; f <= 1'b1; t <= 1'b0;
		mode     <= 5'h13;               // SVC
		regs[13] <= boot_sp;
		regs[14] <= 32'd0;
		r13_b[3] <= boot_sp;
		r14_b[3] <= 32'd0;
		for (rk = 0; rk < 16; rk = rk + 1) cp15_r[rk] <= 32'd0;
		cp15_r[1] <= CP15_RESET_CTRL;
		cp15_aux <= 32'd0;
		state    <= S_FETCH;
		bus_rd   <= 1'b0;
		bus_wr   <= 1'b0;
		blk_run  <= 1'b0;
		blk_list <= 16'd0;
		blk_usr  <= 1'b0;
		blk_restore <= 1'b0;
		swap_en  <= 1'b0;
		swap_phase <= 1'b0;
		wb_en    <= 1'b0;
		dw_run   <= 1'b0;
		dw_phase <= 1'b0;
		f_valid  <= 1'b0;
		bl_pending <= 1'b0;
		hle_go   <= 1'b0;
	end else if (ce) begin
		case (state)

		//--------------------------------------------------------
		// instruction fetch
		//--------------------------------------------------------
		S_FETCH: begin
			// An interrupt is taken between instructions, so its link value is
			// the address of the instruction that does not get executed plus
			// four -- the same number in either state, which is why a handler
			// returns with SUBS PC,LR,#4.  `pc` has not been advanced for the
			// instruction that was about to be fetched, so LR = pc + 4.
			if (fiq && !f) begin
				spsr_fiq  <= cpsr_w;
				r14_b[1]  <= pc + 32'd4;
				regs[14]  <= pc + 32'd4;
				`SWAP8(5'h11)
				mode      <= 5'h11;
				f <= 1'b1; i <= 1'b1; t <= 1'b0;
				pc <= vbase + 32'h0000_001C;
			end else if (irq && !i) begin
				spsr_irq  <= cpsr_w;
				r14_b[2]  <= pc + 32'd4;
				regs[14]  <= pc + 32'd4;
				`SWAP8(5'h12)
				mode      <= 5'h12;
				i <= 1'b1; t <= 1'b0;
				pc <= vbase + 32'h0000_0018;
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
					// the SVC bank was set up at the trap, so the core's own
					// exception return is exactly the way back out
					`EXC_RET(r14_b[3])
				end else begin
					// not in the bank: vector as before, high or low
					pc <= vbase + 32'h0000_0008;
					state <= S_FETCH;
				end
			end
		end

		//--------------------------------------------------------
		// decode + execute
		//--------------------------------------------------------
		S_EXEC: begin
			wb_en   <= 1'b0;
			blk_run <= 1'b0;
			dw_run  <= 1'b0;

			if (insn_thumb) begin
				//====================================================
				// Thumb
				//====================================================
				if (insn[15:13] == 3'b000 && insn[12:11] != 2'b11) begin
					// ---- 1. LSL/LSR/ASR immediate ----
					tidx  = {2'd0, insn[2:0]};
					t32   = rp_a;
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
					t32  = rp_a;
					t32b = insn[10] ? {29'd0, insn[8:6]} : rp_b;
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
					t32  = rp_a;
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
					t32   = rp_a;
					t32b  = rp_b;
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
					t32  = rp_a;
					t32b = rp_b;
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
					t32   = rp_a + rp_b;
					ea    <= t32;
					dst     <= {2'd0, insn[2:0]};
					wdata_r <= rp_c;
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
					t32  = rp_a + {24'd0, insn[10:6]};
					ea   <= t32;
					dst   <= {2'd0, insn[2:0]};
					wdata_r <= rp_c;
					mload   <= insn[11];
					msz     <= insn[12] ? 2'd0 : 2'd2;
					msigned <= 1'b0;
					state   <= S_MEM;

				end else if (insn[15:12] == 4'b1000) begin
					// ---- 9. LDRH/STRH, imm5 scaled by two ----
					ea      <= rp_a + {23'd0, insn[10:6], 1'b0};
					dst     <= {2'd0, insn[2:0]};
					wdata_r <= rp_c;
					msz     <= 2'd1;
					mload   <= insn[11];
					msigned <= 1'b0;
					mrot    <= 1'b0;
					state   <= S_MEM;

				end else if (insn[15:12] == 4'b1001) begin
					// ---- 10. LDR/STR, SP relative ----
					ea      <= r13_b[cur_m] + {22'd0, insn[7:0], 2'b00};
					dst     <= {1'b0, insn[10:8]};
					wdata_r <= rp_c;
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
					blk_usr  <= 1'b0;
					blk_restore <= 1'b0;
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
					blk_usr  <= 1'b0;
					blk_restore <= 1'b0;
					blk_run  <= 1'b1;
					wb_en    <= 1'b1;
					wb_reg   <= 5'd13;
					wb_val   <= r13_b[cur_m] + thumb_sp_off;
					state    <= S_BLK;

				end else if (insn[15:8] == 8'b10111110) begin
					// ---- 13c. BKPT (ARMv5T): a breakpoint is a prefetch abort,
					//           linked past the breakpoint (pc is already A+2 for
					//           this halfword, so +2 makes LR = A+4 as on hardware)
					`PABT(pc + 32'd2)

				end else if (insn[15:12] == 4'b1100) begin
					// ---- 14. STMIA ----
					blk_list <= insn[7:0];
					blk_addr <= rp_a;
					blk_ld   <= 1'b0;
					blk_pc_hit <= 1'b0;
					blk_usr  <= 1'b0;
					blk_restore <= 1'b0;
					blk_run  <= 1'b1;
					wb_en    <= 1'b1;
					wb_reg   <= {2'd0, insn[10:8]};
					wb_val   <= rp_a +
					            {24'd0, popcnt16(insn[7:0]), 2'b00};
					state    <= S_BLK;

				end else if (insn[15:8] == 8'b11011111) begin
					// ---- SWI ---- the call runs on the HLE bank, with the SVC
					// bank set up as if the exception had been taken
					spsr_svc <= cpsr_w;
					r14_b[3] <= pc;
					regs[14] <= pc;
					mode     <= 5'h13;
					i        <= 1'b1;
					t        <= 1'b0;
					hle_num  <= insn[7:0];
					hle_go   <= 1'b1;
					state    <= S_SWI;

				end else if (insn[15:12] == 4'b1101 && insn[11]) begin
					// ---- 15. LDMIA ----
					blk_list <= insn[7:0];
					blk_addr <= rp_a;
					blk_ld   <= 1'b1;
					blk_pc_hit <= 1'b0;
					blk_usr  <= 1'b0;
					blk_restore <= 1'b0;
					blk_run  <= 1'b1;
					wb_en    <= 1'b1;
					wb_reg   <= {2'd0, insn[10:8]};
					wb_val   <= rp_a +
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
					// ---- 18. BL/BLX (high half). ARMv5T's Thumb BL and BLX
					//          share this halfword (11110 S imm10) and differ
					//          only in the low one (11111 = BL, 11101 = BLX),
					//          so this half only stages the branch base in r14
					//          -- the branch itself happens in the low half.
					regs[14] <= pc + 32'd2 + {{9{insn[10]}}, insn[10:0], 12'd0};
					bl_pending <= 1'b1;
					state <= S_FETCH;

				end else if (insn[15:11] == 5'b11111 || insn[15:11] == 5'b11101) begin
					// ---- 19. BL (low half 11111) / BLX (low half 11101)
					// both branch to r14 + imm11*2 and link the return address
					// (the instruction after the pair, which is where `pc`
					// already points) into r14. BLX enters ARM state, so its
					// target is word aligned and its offset is completed
					// before the alignment is applied.
					if (bl_pending) begin
						if (insn[15:11] == 5'b11101) begin
							pc <= (regs[14] + {20'd0, insn[10:0], 1'b0}) & 32'hFFFF_FFFC;
							t  <= 1'b0;
						end else begin
							pc <= regs[14] + {20'd0, insn[10:0], 1'b0};
						end
						regs[14] <= pc | 32'd1;
					end else begin
						// a low halfword with no BL/BLX high halfword before it
						`UND
					end
					bl_pending <= 1'b0;
					state <= S_FETCH;

				end else state <= S_FETCH;
			end else begin
				//====================================================
				// ARM
				//====================================================
				// BLX (immediate) lives in the unconditional space (cond = 1111)
				// and is the one instruction there this core executes, so it is
				// tested before the condition field. H (bit 24) is the offset's
				// bit 1 and is 0 for an ARM-state target, which is what an
				// assembler emits for it.
				if (insn[31:28] == 4'hF && insn[27:25] == 3'b101) begin
					regs[14] <= pc;
					pc       <= pc + 32'd4 + {{6{insn[23]}}, insn[23:0], 2'b00} +
					            {26'd0, insn[24], 1'b0};
					t        <= 1'b1;
					state    <= S_FETCH;

				end else if (!cond_ok) begin
					// cond = 1111 with anything else: PLD and the rest of the
					// hint space. A hint is allowed to do nothing.
					state <= S_FETCH;

				end else if (insn[27:26] == 2'b00) begin
					if (!insn[25] && insn[4]) begin
						// ---- multiply group, where bit 4 is always set:
						//      1001 MUL/MLA/long multiply/SWP, 1011/1101/1111
						//      the halfword, signed and doubleword transfers,
						//      0001 CLZ, 0101 the QADD family, 0111 BKPT
						case (insn[7:5])
						3'b100: begin
							if (insn[27:23] == 5'b00010) begin
								// SWP / SWPB: read, then write back
								t32a       = rp_a;
								ea         <= t32a;
								msz        <= insn[22] ? 2'd0 : 2'd2;
								mload      <= 1'b1;
								msigned    <= 1'b0;
								// SWP reads rotated but writes unrotated (GBATEK)
								mrot       <= !insn[22] && (t32a[1:0] != 2'b00);
								swap_en    <= 1'b1;
								swap_phase <= 1'b0;
								swap_src   <= rp_b;
								state      <= S_MEM;
							end else if (insn[23]) begin
								// ---- long multiply: bit 23 separates UMULL/UMLAL/
								// SMULL/SMLAL from MUL/MLA, and only these four set
								// the flags (from the whole 64-bit result)
								t32e = rp_b;
								t32f = rp_c;
								if (insn[22]) t64 = $signed(t32e) * $signed(t32f);
								else          t64 = {32'd0, t32e} * {32'd0, t32f};
								if (insn[21])
									t64 = t64 + {rp_a, rp_d};
								if (insn[20]) begin
									n <= t64[63];
									z <= (t64 == 64'd0);
								end
								`WREG(insn[15:12], t64[31:0])
								`WREG(insn[19:16], t64[63:32])
								state <= S_FETCH;
							end else begin
								// ---- MUL / MLA ----
								t64 = rp_b * rp_c;
								if (insn[21]) t64 = t64 + {32'd0, rp_d};
								if (insn[20]) begin
									n <= t64[31];
									z <= (t64[31:0] == 32'd0);
								end
								`WREG(insn[19:16], t64[31:0])
								state <= S_FETCH;
							end
						end
						3'b101, 3'b110, 3'b111: begin
							// ---- halfword, signed and doubleword transfers ----
							// (bits 7:4 = 1011 / 1101 / 1111). Bit 22 reverses the
							// data-processing sense of the immediate flag: here set
							// means the 8-bit immediate offset, clear a register.
							t32  = insn[22] ? {24'd0, insn[11:8], insn[3:0]}
							                : rp_b;
							t32b = rp_a;
							t32c = insn[23] ? (t32b + t32) : (t32b - t32);
							t32d = insn[24] ? t32c : t32b;
							ea      <= t32d;
							wb_en   <= insn[24] ? insn[21] : 1'b1;
							wb_reg  <= insn[19:16];
							wb_val  <= t32c;
							if (insn[6] && !insn[20]) begin
								// ---- LDRD / STRD (ARMv5TE): bit 20 is 0 for this
								// pair, which is what tells them from LDRSB (1101
								// with bit 20 set) and LDRSH (1111 with bit 20 set).
								// Rd must be even, and r15 is never allowed; an odd
								// Rd is UNPREDICTABLE and the core takes the
								// undefined vector for it.
								if (insn[12] || insn[15:12] == 4'hE) begin
									`UND
								end								else begin
									dw_run   <= 1'b1;
									dw_phase <= 1'b0;
									dw_ld    <= !insn[5];   // 1101 loads, 1111 stores
									dw_rd    <= insn[15:12];
									dw_addr  <= {t32d[31:2], 2'b00};
									// a store sends the pair on the two beats, a
									// load collects them into r15:12 and r15:12+1
									dw_lo    <= rp_d;
									dw_hi    <= rp_c;
									state    <= S_MEM;
								end
							end else begin
								// ---- LDRH/STRH/LDRSB/LDRSH ----
								dst     <= insn[15:12];
								wdata_r <= rp_d;
								msz     <= (insn[6] && !insn[5]) ? 2'd0 : 2'd1;
								msigned <= insn[6];
								mload   <= insn[20];
								mrot    <= 1'b0;
								state   <= S_MEM;
							end
						end
						3'b000, 3'b001: begin
							// ---- the 0001 group (ARMv5T): BX (0001 0010 .. 0001 Rm),
							//      BLX (register, 0001 0010 .. 0011 Rm) and CLZ
							//      (0001 0110 Rd 1111 0000 0001 Rm). They share bits
							//      27:23 with the PSR transfers and with SWP, so the
							//      discriminator is insn[7:4]: 0001 for BX/CLZ, 0011
							//      for BLX. BX must not fall through to the group
							//      above, which is why it is decoded here rather
							//      than in the main branch chain.
							if (insn[23:20] == 4'b0010 && insn[11:8] == 4'hF &&
							    insn[7:4] == 4'b0001) begin
								// BX: branch and interwork, without linking
								t32 = rp_b;
								pc  <= t32 & 32'hFFFF_FFFE;
								t   <= t32[0];
								state <= S_FETCH;
							end else if (insn[23:20] == 4'b0010 && insn[11:8] == 4'hF &&
							             insn[7:4] == 4'b0011) begin
								// BLX (register): link, then the same branch
								regs[14] <= pc;
								t32 = rp_b;
								pc  <= t32 & 32'hFFFF_FFFE;
								t   <= t32[0];
								state <= S_FETCH;
							end else if (insn[23:20] == 4'b0110 && insn[11:8] == 4'hF &&
							             insn[7:4] == 4'b0001) begin
								// ---- CLZ (ARMv5T) ----
								`WREG(insn[15:12], {26'd0, count_lead_zeros(rp_b)})
								state <= S_FETCH;
							end else
								`UND
						end
						3'b010: begin
							// ---- QADD/QSUB/QDADD/QDSUB (ARMv5TE): 0001 0x0x Rd Rn
							//      0000 0101 Rm, with Rm in bits 3:0 and its
							//      partner Rn in bits 19:16. Saturation sets the
							//      sticky Q flag, which only MSR can clear.
							if (insn[11:8] == 4'h0 &&
							    (insn[23:20] == 4'h0 || insn[23:20] == 4'h2 ||
							     insn[23:20] == 4'h4 || insn[23:20] == 4'h6)) begin
								t32  = rp_b;     // Rm
								t32b = rp_a;   // Rn
								c_tmp = 1'b0;
								if (insn[22]) begin          // QDADD/QDSUB double Rn
									// by 8:0 /* 2*Rn saturates when its top two bits
									// differ */
									if (t32b[31] != t32b[30]) begin
										t32b  = t32b[31] ? 32'h8000_0000 : 32'h7FFF_FFFF;
										c_tmp = 1'b1;
									end else
										t32b = {t32b[30:0], 1'b0};
								end
								if (insn[21]) begin          // QSUB/QDSUB
									wide  = {1'b0, t32} - {1'b0, t32b};
									v_tmp = (t32[31] ^ t32b[31]) & (t32[31] ^ wide[31]);
								end else begin               // QADD/QDADD
									wide  = {1'b0, t32} + {1'b0, t32b};
									v_tmp = (t32[31] == t32b[31]) & (wide[31] != t32[31]);
								end
								// a saturating add or subtract pins the result at
								// infinity on the side the sign of Rm points to
								if (v_tmp) t32c = t32[31] ? 32'h8000_0000 : 32'h7FFF_FFFF;
								else       t32c = wide[31:0];
								q <= q | v_tmp | c_tmp;
								`WREG(insn[15:12], t32c)
								state <= S_FETCH;
							end else
								`UND
						end
						default: begin
							// ---- BKPT (ARMv5): 0001 0010 imm12 0111 imm4. It is a
							// debug exception, taken through the prefetch abort.
							if (insn[7:5] == 3'b011 && insn[23:20] == 4'b0010 &&
							    insn[31:28] == 4'hE)
								`PABT(pc)
							else
								`UND
						end
						endcase

					end else if (!insn[25] && insn[7] && !insn[4]) begin
						// ---- ARMv5TE halfword media instructions. Bits 7:4 are
						//      1xy0 — x (bit 5) picks Rm's half, y (bit 6) Rs's —
						//      and bits 23:20 select which of the four forms it is.
						t32e = rp_b;                     // Rm
						t32f = rp_c;                    // Rs
						t32  = insn[5] ? {16'd0, t32e[31:16]} : {16'd0, t32e[15:0]};
						t32b = insn[6] ? {16'd0, t32f[31:16]} : {16'd0, t32f[15:0]};
						case (insn[23:20])
						4'h0: begin
							// SMLAxy: Rd = Rn + (Rm_x * Rs_y), with Rd in bits 19:16
							// and the accumulate operand Rn in bits 15:12 (the
							// media encodings put Rd where a data-processing
							// instruction puts Rn). No flags, no saturation: the
							// result just wraps.
							t64  = $signed(t32[15:0]) * $signed(t32b[15:0]);
							t32c = t64[31:0] + rp_d;
							`WREG(insn[19:16], t32c)
							state <= S_FETCH;
						end
						4'h2: begin
							// SMLAWy (bit 5 clear) and SMULWy (bit 5 set): the full
							// Rm times Rs's selected half, keeping the top 32 bits.
							// Rd is bits 19:16 and SMLAWy accumulates from 15:12.
							t64  = $signed(t32e) * $signed(t32b[15:0]);
							t32c = t64[47:16];
							if (insn[5]) `WREG(insn[19:16], t32c)
							else         `WREG(insn[19:16], t32c + rp_d)
							state <= S_FETCH;
						end
						4'h4: begin
							// SMLALxy: the 64-bit accumulate. It is the one media
							// instruction that touches flags (N and Z).
							t64 = $signed(t32[15:0]) * $signed(t32b[15:0]);
							t64 = t64 + {rp_a, rp_d};
							n <= t64[63];
							z <= (t64 == 64'd0);
							`WREG(insn[15:12], t64[31:0])
							`WREG(insn[19:16], t64[63:32])
							state <= S_FETCH;
						end
						4'h6: begin
							// SMULxy: Rd (bits 19:16) = Rm_x * Rs_y
							t64 = $signed(t32[15:0]) * $signed(t32b[15:0]);
							`WREG(insn[19:16], t64[31:0])
							state <= S_FETCH;
						end
						default: `UND
						endcase

					end else if (!insn[25] && !insn[6] && !insn[5] &&
					             (insn[27:23] == 5'b00010 ||
					              insn[27:23] == 5'b00110) &&
					             (insn[21:20] == 2'b00 || insn[21:20] == 2'b10)) begin
						// ---- MRS / MSR (register and immediate) ----
						if (insn[21:20] == 2'b00) begin
							`WREG(insn[15:12], insn[22] ? cur_spsr() : cpsr_w)
						end else
							psr_write(rp_b, insn[19:16], insn[22]);
						state <= S_FETCH;

					end else if (insn[27:23] == 5'b00110 && insn[25] &&
					             insn[21] && !insn[20]) begin
						// ---- MSR (immediate): 0011 0R10 field_mask 1111 rot imm8.
						//      It shares bits 27:26 with data processing (and with
						//      the compare group in particular), where it would
						//      otherwise be executed as a TEQ, so it is recognised
						//      before that branch. The value is the rotated 8-bit
						//      immediate.
						psr_write(imm32, insn[19:16], insn[22]);
						state <= S_FETCH;

					end else begin
						// ---- data processing ----
						t32  = dp_out;
						tidx = insn[15:12];
						if (insn[24:23] == 2'b10) begin
							// TST / TEQ / CMP / CMN: flags only, Rd is unused
							n <= t32[31];
							z <= (t32 == 32'd0);
							c <= dp_c;
							v <= dp_v;
							state <= S_FETCH;
						end else if (insn[20]) begin
							if (tidx == 5'd15)
								`EXC_RET(t32)   // exception return: CPSR <- SPSR
							else begin
								n <= t32[31];
								z <= (t32 == 32'd0);
								c <= dp_c;
								v <= dp_v;
								`WREG(tidx, t32)
								state <= S_FETCH;
							end
						end else begin
							if (tidx == 5'd15) pc <= t32;
							else               `WREG(tidx, t32)
							state <= S_FETCH;
						end
					end

				end else if (insn[27:26] == 2'b01) begin
					// ---- single data transfer ----
					// bit 25 set means a register offset, clear means the 12-bit
					// immediate (the opposite of data processing)
					t32  = insn[25] ? op2 : {20'd0, insn[11:0]};
					t32b = rp_a;
					t32c = insn[23] ? (t32b + t32) : (t32b - t32);
					t32d = insn[24] ? t32c : t32b;
					ea      <= t32d;
					wb_en   <= insn[24] ? insn[21] : 1'b1;
					wb_reg  <= insn[19:16];
					wb_val  <= t32c;
					dst     <= insn[15:12];
					wdata_r <= rp_d;
					msz     <= insn[22] ? 2'd0 : 2'd2;
					msigned <= 1'b0;
					mload   <= insn[20];
					// an unaligned word load comes back rotated (ARMv5 keeps the
					// ARMv4 behaviour here; ARMv6 is what changed it)
					mrot    <= (!insn[22]) && (t32d[1:0] != 2'b00);
					state   <= S_MEM;
				end else if (insn[27:26] == 2'b10 && !insn[25]) begin
					// ---- block transfer ----
					// bit 25 clear separates LDM/STM (100 P U S W L) from B/BL
					// (101 L), which share bits 27:26
					blk_list <= insn[15:0];
					t32      = rp_a;
					t32b     = (insn[15:0] == 16'd0) ? 32'd64
					                                : {24'd0, popcnt16(insn[15:0]), 2'b00};
					if (insn[24])
						blk_addr <= insn[23] ? (t32 + 32'd4) : (t32 - t32b);
					else
						blk_addr <= insn[23] ? t32 : (t32 - (t32b - 32'd4));
					blk_ld     <= insn[20];
					blk_pc_hit <= 1'b0;
					blk_run    <= 1'b1;
					// S (bit 22) on an LDM whose list holds R15 is an exception
					// return, with the load itself using the current registers;
					// otherwise S means the user-mode bank.
					blk_restore <= insn[22] && insn[20] && insn[15];
					blk_usr     <= insn[22] && !(insn[20] && insn[15]);
					// only W writes the base back: LDM without "!" keeps it
					wb_en     <= insn[21];
					wb_reg    <= insn[19:16];
					wb_val    <= insn[23] ? (t32 + t32b) : (t32 - t32b);
					state     <= S_BLK;

				end else if (insn[27:25] == 3'b111 && insn[4]) begin
					// ---- coprocessor data transfer: MCR / MRC ----
					// bits 27:25 = 111 with bit 4 set (110 with bit 4 clear is
					// the LDC/STC block group, and 110 without is MCRR/MRRC).
					// The DS's ARM9 has one coprocessor, CP15, and it is the
					// only one this core answers to: the coprocessor number
					// (bits 11:8) must be 1111. CP15 is privileged, so in
					// user mode every access to it is undefined, and MCR/MRC
					// with R15 as the register is UNPREDICTABLE (the ARM ARM
					// says so) and is treated as undefined here too.
					if (cp15_sel && mode != 5'h10 && insn[15:12] != 4'hF) begin
						if (cp15_rd) begin
							// MRC: c0 is the identification space (read
							// only) and c7 is write-only maintenance, both
							// of which `cprd` above already accounts for
							`WREG(insn[15:12], cprd)
						end else begin
							// MCR: keep the register whole. A write to the
							// read-only c0 is dropped, c1 opcode_2 1 is the
							// auxiliary control register, and a maintenance
							// write to c7 invalidates the fetch buffer so
							// code that was just patched or flushed is
							// re-read from memory.
							if (cp15_crn == 4'h1 && cp15_op2 == 3'd1)
								cp15_aux <= rp_d;
							else if (cp15_crn != 4'h0)
								cp15_r[cp15_crn] <= rp_d;
							if (cp15_crn == 4'h7) f_valid <= 1'b0;
						end
						state <= S_FETCH;
					end else `UND

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
						// the offset is relative to the instruction address plus
						// eight, and `pc` is already past it by four
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
						t        <= 1'b0;
						hle_num  <= insn[23:16];
						hle_go   <= 1'b1;
						state    <= S_SWI;
					end else
						// everything else — including every coprocessor that is
						// not CP15, which the DS ARM9 does not have
						`UND
				end

			end
		end

		//--------------------------------------------------------
		// one bus transaction
		//--------------------------------------------------------
		S_MEM: begin
			if (dw_run) begin
				// LDRD/STRD: two word beats on consecutive addresses
				bus_addr  <= dw_phase ? (dw_addr + 32'd4) : dw_addr;
				bus_be    <= 4'b1111;
				bus_wdata <= dw_phase ? dw_hi : dw_lo;
				bus_rd    <= dw_ld;
				bus_wr    <= ~dw_ld;
				state     <= S_MW;
			end else begin
				// A load reads the word-aligned word unless the access is a
				// byte or halfword on the halfword-mapped I/O block.
				if (mload && !(is_io_region && msz != 2'd2)) begin
					bus_addr <= {ea[31:2], 2'b00};
					bus_be   <= 4'b1111;
				end else begin
					// A store force-aligns its address: GBATEK's DS alignment
					// page is explicit that the low bits are ignored and the
					// access goes to the rounded-down address, with no rotation
					// of the data. A byte keeps the address, because the byte
					// lanes are selected from it.
					bus_addr <= (msz == 2'd2) ? {ea[31:2], 2'b00} :
					            (msz == 2'd1) ? {ea[31:1], 1'b0} : ea;
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
		end

		S_MW: begin
			if (bus_ready) begin
				bus_rd <= 1'b0;
				// a store may have changed the word the buffer holds
				if (bus_wr) f_valid <= 1'b0;
				bus_wr <= 1'b0;
				if (dw_run) begin
					if (!dw_phase) begin
						if (dw_ld) dw_lo <= bus_rdata;
						dw_phase <= 1'b1;
						state    <= S_MEM;      // second word
					end else begin
						dw_run <= 1'b0;
						if (wb_en) `WREG(wb_reg, wb_val)
						if (dw_ld) begin
							`WREG(dw_rd, dw_lo)
							`WREG(dw_rd + 4'd1, bus_rdata)
						end
						state <= S_FETCH;
					end
				end else if (blk_run) begin
					if (blk_ld) begin
						if (blk_idx == 4'd15) begin
							blk_pc_hit <= 1'b1;
							blk_pc_val <= bus_rdata;
						end else if (blk_usr) begin
							`WUSR({1'b0, blk_idx}, bus_rdata)
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
							// A misaligned LDRH/LDRSH force-aligns, and the DS
							// does not rotate it (that is the GBA's ARM7). The I/O
							// block answers the addressed halfword itself.
							t32d = (ea[1] && !is_io_region) ? bus_rdata[31:16]
							                              : bus_rdata[15:0];
							t32 = msigned ? {{16{t32d[15]}}, t32d[15:0]}
							              : {16'd0, t32d[15:0]};
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
				if (blk_pc_hit) begin
					// an LDM with S=1 and R15 in the list is an exception
					// return, not just a jump
					if (blk_restore) `EXC_RET(blk_pc_val)
					else             pc <= blk_pc_val;
				end
				blk_run <= 1'b0;
				state   <= S_FETCH;
			end else begin
				bus_addr  <= blk_addr;
				// STM with R15 in the list stores the address of the
				// instruction after it, which is what pc_ahead holds
				bus_wdata <= blk_usr ? rread_user(blk_idx)
				                     : ((blk_idx == 4'd15) ? pc_ahead
				                                           : rp_a);
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

// The macros above are `undef'd rather than left defined: arm7_core.sv has a
// macro of the same name with a deliberately different body (its r8..r12 write
// does not reach the user bank), and a definition that leaked across the two
// files would silently pick the wrong one. Naming both here keeps each core
// self-contained when they are compiled together, which the whole-top lint is.
`undef WREG
`undef WUSR
`undef SWAP8
`undef UND
`undef PABT
`undef EXC_RET

// The SPSR banks are only read inside psr_get(), and Verific's function-body
// read analysis does not follow those readers, so Quartus calls the banks
// "assigned a value but never read" (warning 10036). Reading them here states
// the fact; the branch cannot be taken and synthesises to nothing. Measured on
// a throwaway module with the same shape: 5 such warnings without this, 0 with.
wire _unused_spsr = &{1'b0, spsr_abt, spsr_fiq, spsr_irq, spsr_svc, spsr_und};
always @(*) if (_unused_spsr) begin end

endmodule
