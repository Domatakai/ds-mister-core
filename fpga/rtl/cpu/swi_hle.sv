//============================================================================
// NDS MiSTer Test — high-level BIOS SWI bank
//
// The DS BIOS region is empty in this core (it reads back as NOPs), so a game
// that executes an SWI falls through the vector and never returns. This module
// is the replacement: the ARM7 and ARM9 cores trap SWI, hand the function
// number and r0..r3 over, and this engine performs the call through the core's
// own bus master, then hands the results back.
//
// What it implements, in GBATEK's DS/DSi numbering (which is *not* the GBA
// numbering — Halt is 02h on a GBA and 06h here, Div is 06h there and 09h here):
//
//   04h IntrWait          r0 discard, r1 flags; forces IME = 1
//   05h VBlankIntrWait    IntrWait with discard = 1, flags = 1
//   06h Halt              wait until (IE AND IF) is not zero
//   09h Div               r0/r1 -> r0 quotient, r1 remainder, r3 |quotient|
//   0Bh CpuSet            r2[20:0] count, r2[24] fill, r2[26] 16/32-bit
//   0Ch CpuFastSet        r2[20:0] word count, r2[24] fill
//   0Dh Sqrt              r0 -> r0, 16-bit floor
//   11h LZ77UnCompWram    r0 source, r1 destination, 8-bit writes
//   14h RLUnCompWram      r0 source, r1 destination, 8-bit writes
//
// Deliberately not here, and why:
//
//   * 12h and 15h are the DS *ReadByCallback* decompressors — they take
//     function pointers in r2/r3 and call back into the CPU — so they are not
//     the GBA direct-memory VRAM variants and cannot be mirrored in hardware.
//     An SWI 12h/15h falls through to the vector exactly as it always did.
//   * 00h SoftReset, 01h WaitByLoop, the affine/unpack helpers and the ARM7
//     sound driver are outside this bank for now. Same fallback for those.
//
// Division by zero: the real BIOS loops forever. This one returns quotient 0,
// remainder = the numerator, so a stray divide cannot lock the core up.
//
// Memory protocol: one access at a time. `m_req` rises with a complete
// request and stays up until `m_ack`; the core mirrors the request onto its
// master port for that stretch, so the engine never needs to know the bus's
// shape. `m_be`/`m_wlane` put the value in the right byte lanes for the size.
//
// Waiting: Halt and IntrWait poll IE and IF over that same port instead of
// stopping the CPU, because the core cannot suspend inside an exception. A
// game sees the same thing — the instruction after the SWI waits for the
// interrupt — with the one ordering difference that the IRQ is taken once the
// SWI has returned rather than during the wait. IntrWait therefore leaves IF
// alone on the way out: GBATEK puts the acknowledgement in the game's handler.
//============================================================================
module swi_hle (
	input             clk,
	input             reset,
	input             ce,          // the calling core's clock enable

	input             go,          // one cycle: an SWI was executed
	input       [7:0] num,         // the SWI number (instruction bits 23:16)
	input      [31:0] r0, r1, r2, r3,

	// ---- bus conduit toward the core's master port ----
	output reg        m_req = 1'b0,
	output reg        m_wr  = 1'b0,
	output reg  [1:0] m_size = 2'd2,   // 0 byte, 1 halfword, 2 word
	output reg [31:0] m_addr = 32'd0,
	output reg [31:0] m_wdata = 32'd0,
	output     [3:0]  m_be,            // byte enables for this request
	output     [31:0] m_wlane,         // write data placed in its lanes
	input      [31:0] m_rdata,
	input             m_ack,           // one cycle: the access retired

	// ---- completion ----
	output reg        done = 1'b0,     // one cycle: finished (or not ours)
	output reg        handled = 1'b0,  // 0 = not in this bank: vector to 0x08
	output reg [31:0] res0 = 32'd0,    // results, latched with `done`
	output reg [31:0] res1 = 32'd0,
	output reg [31:0] res3 = 32'd0,
	output reg        wr0 = 1'b0,      // which of them to write back
	output reg        wr1 = 1'b0,
	output reg        wr3 = 1'b0,
	output            busy
);

//------------------------------------------------------------------
// SWI numbers (DS/DSi) and the system registers the waits touch
//------------------------------------------------------------------
localparam [7:0] S_INTR   = 8'h04,
                 S_VBLANK = 8'h05,
                 S_HALT   = 8'h06,
                 S_DIV    = 8'h09,
                 S_CPUSET = 8'h0B,
                 S_CPUFST = 8'h0C,
                 S_SQRT   = 8'h0D,
                 S_LZ77   = 8'h11,
                 S_RL     = 8'h14;

localparam [31:0] A_IME = 32'h0400_0208,
                  A_IE  = 32'h0400_0210,
                  A_IF  = 32'h0400_0214;

//------------------------------------------------------------------
// States
//------------------------------------------------------------------
localparam [4:0] H_IDLE   = 5'd0,
                 H_DIV    = 5'd1,  H_RES    = 5'd2,
                 H_SQRT   = 5'd3,
                 H_CS_RD  = 5'd4,  H_CS_WR  = 5'd5,
                 H_CF_FRD = 5'd6,  H_CF_WR  = 5'd7,
                 H_LZ_HDR = 5'd8,  H_LZ_FLG = 5'd9,  H_LZ_GO  = 5'd10,
                 H_LZ_LR  = 5'd11, H_LZ_LW  = 5'd12,
                 H_LZ_H1  = 5'd13, H_LZ_H2  = 5'd14,
                 H_LZ_CR  = 5'd15, H_LZ_CW  = 5'd16,
                 H_RL_HDR = 5'd17, H_RL_FLG = 5'd18,
                 H_RL_LR  = 5'd19, H_RL_LW  = 5'd20,
                 H_RL_RR  = 5'd21, H_RL_RW  = 5'd22,
                 H_IW_IME = 5'd23, H_IW_CLR = 5'd24,
                 H_IW_IE  = 5'd25, H_IW_IF  = 5'd26,
                 H_HLT_IE = 5'd27, H_HLT_IF = 5'd28;

reg  [4:0]  st = H_IDLE;

// `go` is a *request*, not a trigger: a caller holds it up for the whole call
// and drops it when `done` arrives. Dispatching on the level would re-run a
// finished call whenever `go` outlived the completion by a cycle — which is
// exactly what a shared bank does when the next core is granted in the cycle
// the previous one finishes. So the dispatch is the rising edge: one call per
// `go`, however long it is held.
reg         go_d = 1'b0;

// one bus access in flight
reg         a_busy = 1'b0;       // m_req is up
reg         a_done = 1'b0;       // it retired; rd_val holds the answer
reg [31:0]  rd_val = 32'd0;

assign busy = (st != H_IDLE);

//------------------------------------------------------------------
// A request's byte enables and lane placement
//------------------------------------------------------------------
wire [1:0] lane = m_addr[1:0];

assign m_be = (m_size == 2'd0) ? (4'b0001 << lane) :
              (m_size == 2'd1) ? (lane[1] ? 4'b1100 : 4'b0011) : 4'b1111;

assign m_wlane = (m_size == 2'd0) ? (m_wdata << (8 * lane)) :
                 (m_size == 2'd1) ? (lane[1] ? {m_wdata[15:0], 16'h0000}
                                             : {16'h0000, m_wdata[15:0]})
                                  : m_wdata;

// a read's value taken out of the lane the access used
wire [31:0] rd_lane = (m_size == 2'd0) ? (rd_val >> (8 * lane)) :
                      (m_size == 2'd1) ? (lane[1] ? rd_val[31:16] : rd_val[15:0])
                                       : rd_val;

//------------------------------------------------------------------
// One bus access, the shape every state below uses: issue it while the
// state is first visited, consume rd_lane on the visit after the ack
//------------------------------------------------------------------
`define HLE_RD(sz, adr) begin \
		m_size  <= sz; m_addr <= adr; m_wdata <= 32'd0; \
		m_wr    <= 1'b0; m_req <= 1'b1; a_busy <= 1'b1; end
`define HLE_WR(sz, adr, dat) begin \
		m_size  <= sz; m_addr <= adr; m_wdata <= dat; \
		m_wr    <= 1'b1; m_req <= 1'b1; a_busy <= 1'b1; end
`define HLE_IDLE(nxt) begin a_done <= 1'b0; st <= nxt; end

//------------------------------------------------------------------
// working registers
//------------------------------------------------------------------
// divide / square root
reg [31:0] ua, ud, uq, ur;
reg        sgnq, sgnr;
reg [5:0]  bcnt;
reg [31:0] nsrc, rem, root;

// copy / fill
reg [21:0] cnt;
reg  [1:0] csz;
reg [31:0] csrc, cdst, cval;

// decompression
reg [23:0] lsize;
reg [31:0] lwritten;
reg  [7:0] lflags;
reg  [3:0] lbits;
reg [31:0] lsrc, ldst;
reg [31:0] llen, ldisp;
reg [23:0] lrem;                 // bytes still owed by the current run
reg  [7:0] lb0;

// waits
reg        iwdisc;
reg [15:0] iwflags, iw_ie;

wire  [1:0] sq_pair  = nsrc[31:30];
wire [31:0] sq_trial = {root[29:0], 2'b01};
wire        sq_take  = ({rem[29:0], sq_pair} >= sq_trial);
wire [31:0] sq_next  = {root[30:0], sq_take};

// the dispatch below runs in the same cycle the arguments are latched, so it
// reads the ports (r0..r3), not the copies it is writing
wire [31:0] div_nabs = r0[31] ? (~r0 + 32'd1) : r0;
wire [31:0] div_dabs = r1[31] ? (~r1 + 32'd1) : r1;

//------------------------------------------------------------------
// The machine
//------------------------------------------------------------------
always @(posedge clk) begin
	if (reset) begin
		st      <= H_IDLE;
		go_d    <= 1'b0;
		m_req   <= 1'b0;
		m_wr    <= 1'b0;
		m_size  <= 2'd2;
		a_busy  <= 1'b0;
		a_done  <= 1'b0;
		done    <= 1'b0;
		handled <= 1'b0;
		wr0     <= 1'b0;
		wr1     <= 1'b0;
		wr3     <= 1'b0;
		cnt     <= 22'd0;
		bcnt    <= 6'd0;
		lbits   <= 4'd0;
		lsize   <= 24'd0;
		lrem    <= 24'd0;
		lwritten <= 32'd0;
	end else if (ce) begin
		// the request's rising edge is what starts a call
		go_d <= go;
		// one-cycle strobes unless a state raises them again
		done <= 1'b0;
		wr0  <= 1'b0;
		wr1  <= 1'b0;
		wr3  <= 1'b0;

		// a retired access: drop the request and publish the answer
		if (m_ack) begin
			m_req  <= 1'b0;
			a_busy <= 1'b0;
			a_done <= 1'b1;
			rd_val <= m_rdata;
		end

		case (st)

		//----------------------------------------------------------
		// dispatch
		//----------------------------------------------------------
		H_IDLE: begin
			if (go & ~go_d) begin
				a_done <= 1'b0;
				case (num)
				S_DIV: begin
					ud   <= div_dabs;
					ua   <= div_nabs;
					// the zero case keeps |numerator| as the remainder
					ur   <= (r1 == 32'd0) ? div_nabs : 32'd0;
					sgnq <= r0[31] ^ r1[31];
					sgnr <= r0[31];
					uq   <= 32'd0;
					bcnt <= 6'd32;
					handled <= 1'b1;
					// division by zero: quotient 0, remainder the numerator
					st <= (r1 == 32'd0) ? H_RES : H_DIV;
				end
				S_SQRT: begin
					nsrc <= r0;
					root <= 32'd0;
					rem  <= 32'd0;
					bcnt <= 6'd16;
					handled <= 1'b1;
					st <= H_SQRT;
				end
				S_CPUSET, S_CPUFST: begin
					cnt   <= {1'b0, r2[20:0]};
					csz   <= (num == S_CPUFST) ? 2'd2 : (r2[26] ? 2'd2 : 2'd1);
					csrc  <= r0;
					cdst  <= r1;
					handled <= 1'b1;
					if (r2[20:0] == 21'd0) begin
						done <= 1'b1;
						st   <= H_IDLE;
					end else
						st <= r2[24] ? H_CF_FRD : H_CS_RD;
				end
				S_LZ77, S_RL: begin
					lsrc  <= r0;
					ldst  <= r1;
					lwritten <= 32'd0;
					lbits <= 4'd0;
					lflags <= 8'd0;
					lrem  <= 24'd0;
					handled <= 1'b1;
					`HLE_RD(2'd2, r0)
					st <= (num == S_LZ77) ? H_LZ_HDR : H_RL_HDR;
				end
				S_INTR, S_VBLANK: begin
					iwdisc  <= (num == S_VBLANK) ? 1'b1 : r0[0];
					iwflags <= (num == S_VBLANK) ? 16'h0001 : r1[15:0];
					handled <= 1'b1;
					`HLE_WR(2'd1, A_IME, 32'd1)
					st <= H_IW_IME;
				end
				S_HALT: begin
					handled <= 1'b1;
					`HLE_RD(2'd1, A_IE)
					st <= H_HLT_IE;
				end
				default: begin
					// not ours: the core vectors to 0x08 as it always did
					handled <= 1'b0;
					done    <= 1'b1;
					st      <= H_IDLE;
				end
				endcase
			end
		end

		//----------------------------------------------------------
		// Div — 32 restoring steps, one bit each
		//----------------------------------------------------------
		H_DIV: begin
			if ({ur[30:0], ua[31]} >= ud) begin
				ur <= {ur[30:0], ua[31]} - ud;
				uq <= {uq[30:0], 1'b1};
			end else begin
				ur <= {ur[30:0], ua[31]};
				uq <= {uq[30:0], 1'b0};
			end
			ua   <= {ua[30:0], 1'b0};
			bcnt <= bcnt - 6'd1;
			if (bcnt == 6'd1) st <= H_RES;
		end

		H_RES: begin
			res0 <= sgnq ? (~uq + 32'd1) : uq;
			res1 <= sgnr ? (~ur + 32'd1) : ur;
			res3 <= uq;
			wr0  <= 1'b1;
			wr1  <= 1'b1;
			wr3  <= 1'b1;
			done <= 1'b1;
			st   <= H_IDLE;
		end

		//----------------------------------------------------------
		// Sqrt — 16 pairs, digit by digit
		//----------------------------------------------------------
		H_SQRT: begin
			if (sq_take) rem <= {rem[29:0], sq_pair} - sq_trial;
			else         rem <= {rem[29:0], sq_pair};
			root <= sq_next;
			nsrc <= {nsrc[29:0], 2'b00};
			bcnt <= bcnt - 6'd1;
			if (bcnt == 6'd1) begin
				res0 <= sq_next[16:0];
				wr0  <= 1'b1;
				done <= 1'b1;
				st   <= H_IDLE;
			end
		end

		//----------------------------------------------------------
		// CpuSet / CpuFastSet — one element per read and write
		//----------------------------------------------------------
		H_CS_RD: begin
			if (!a_busy && !a_done) `HLE_RD(csz, csrc)
			else if (a_done) begin
				cval <= rd_lane;
				`HLE_IDLE(H_CS_WR)
			end
		end

		H_CS_WR: begin
			if (!a_busy && !a_done) `HLE_WR(csz, cdst, cval)
			else if (a_done) begin
				a_done <= 1'b0;
				csrc <= csrc + (32'd1 << csz);
				cdst <= cdst + (32'd1 << csz);
				cnt  <= cnt - 22'd1;
				if (cnt == 22'd1) begin
					done <= 1'b1;
					st   <= H_IDLE;
				end else
					st <= H_CS_RD;
			end
		end

		H_CF_FRD: begin
			if (!a_busy && !a_done) `HLE_RD(csz, csrc)
			else if (a_done) begin
				cval <= rd_lane;
				`HLE_IDLE(H_CF_WR)
			end
		end

		H_CF_WR: begin
			if (!a_busy && !a_done) `HLE_WR(csz, cdst, cval)
			else if (a_done) begin
				a_done <= 1'b0;
				cdst <= cdst + (32'd1 << csz);
				cnt  <= cnt - 22'd1;
				if (cnt == 22'd1) begin
					done <= 1'b1;
					st   <= H_IDLE;
				end else
					st <= H_CF_WR;
			end
		end

		//----------------------------------------------------------
		// LZ77: header, flag byte, then up to eight blocks
		//----------------------------------------------------------
		H_LZ_HDR: begin
			if (a_done) begin
				a_done <= 1'b0;
				lsize  <= rd_lane[31:8];
				lsrc   <= lsrc + 32'd4;
				if (rd_lane[31:8] == 24'd0 || rd_lane[7:4] != 4'h1) begin
					done <= 1'b1;
					st   <= H_IDLE;
				end else
					st <= H_LZ_FLG;
			end
		end

		H_LZ_FLG: begin
			if (!a_busy && !a_done) `HLE_RD(2'd0, lsrc)
			else if (a_done) begin
				a_done <= 1'b0;
				lflags <= rd_lane[7:0];
				lsrc   <= lsrc + 32'd1;
				lbits  <= 4'd8;
				st     <= H_LZ_GO;
			end
		end

		H_LZ_GO: begin
			// GBATEK: flag bit 7 governs the first block of the eight
			if (lbits == 4'd0)   st <= H_LZ_FLG;  // next flag byte
			else if (lflags[7])  st <= H_LZ_H1;   // compressed
			else                 st <= H_LZ_LR;   // literal
		end

		H_LZ_LR: begin
			if (!a_busy && !a_done) `HLE_RD(2'd0, lsrc)
			else if (a_done) begin
				cval <= rd_lane;
				`HLE_IDLE(H_LZ_LW)
			end
		end

		H_LZ_LW: begin
			if (!a_busy && !a_done) `HLE_WR(2'd0, ldst, cval)
			else if (a_done) begin
				a_done <= 1'b0;
				lsrc <= lsrc + 32'd1;
				ldst <= ldst + 32'd1;
				lwritten <= lwritten + 32'd1;
				lbits <= lbits - 4'd1;
				lflags <= {lflags[6:0], 1'b0};
				if (lwritten + 32'd1 >= {8'd0, lsize}) begin
					done <= 1'b1;
					st   <= H_IDLE;
				end else
					st <= H_LZ_GO;
			end
		end

		H_LZ_H1: begin
			if (!a_busy && !a_done) `HLE_RD(2'd0, lsrc)
			else if (a_done) begin
				a_done <= 1'b0;
				lb0    <= rd_lane[7:0];
				st     <= H_LZ_H2;
			end
		end

		H_LZ_H2: begin
			if (!a_busy && !a_done) `HLE_RD(2'd0, lsrc + 32'd1)
			else if (a_done) begin
				a_done <= 1'b0;
				lrem   <= {20'd0, lb0[7:4]} + 24'd3;
				// GBATEK copies from Dest-Disp-1
				ldisp  <= {19'd0, lb0[3:0], rd_lane[7:0]} + 32'd1;
				lsrc   <= lsrc + 32'd2;
				st     <= H_LZ_CR;
			end
		end

		H_LZ_CR: begin
			if (!a_busy && !a_done) `HLE_RD(2'd0, ldst - ldisp)
			else if (a_done) begin
				cval <= rd_lane;
				`HLE_IDLE(H_LZ_CW)
			end
		end

		H_LZ_CW: begin
			if (!a_busy && !a_done) `HLE_WR(2'd0, ldst, cval)
			else if (a_done) begin
				a_done <= 1'b0;
				ldst <= ldst + 32'd1;
				lrem <= lrem - 24'd1;
				lwritten <= lwritten + 32'd1;
				if (lwritten + 32'd1 >= {8'd0, lsize}) begin
					done <= 1'b1;
					st   <= H_IDLE;
				end else if (lrem == 24'd1) begin
					lbits  <= lbits - 4'd1;
					lflags <= {lflags[6:0], 1'b0};
					st     <= H_LZ_GO;
				end else
					st <= H_LZ_CR;
			end
		end

		//----------------------------------------------------------
		// RL: header, then one flag byte per run
		//----------------------------------------------------------
		H_RL_HDR: begin
			if (a_done) begin
				a_done <= 1'b0;
				lsize  <= rd_lane[31:8];
				lsrc   <= lsrc + 32'd4;
				if (rd_lane[31:8] == 24'd0 || rd_lane[7:4] != 4'h3) begin
					done <= 1'b1;
					st   <= H_IDLE;
				end else
					st <= H_RL_FLG;
			end
		end

		H_RL_FLG: begin
			if (!a_busy && !a_done) `HLE_RD(2'd0, lsrc)
			else if (a_done) begin
				a_done <= 1'b0;
				lflags <= rd_lane[7:0];
				lsrc   <= lsrc + 32'd1;
				if (rd_lane[7]) begin
					// repeated: length is N+3, one byte follows
					lrem <= {17'd0, rd_lane[6:0]} + 24'd3;
					st   <= H_RL_RR;
				end else begin
					// literal: length is N+1 bytes straight out of the source
					lrem <= {17'd0, rd_lane[6:0]} + 24'd1;
					st   <= H_RL_LR;
				end
			end
		end

		H_RL_LR: begin
			if (!a_busy && !a_done) `HLE_RD(2'd0, lsrc)
			else if (a_done) begin
				cval <= rd_lane;
				`HLE_IDLE(H_RL_LW)
			end
		end

		H_RL_LW: begin
			if (!a_busy && !a_done) `HLE_WR(2'd0, ldst, cval)
			else if (a_done) begin
				a_done <= 1'b0;
				lsrc <= lsrc + 32'd1;
				ldst <= ldst + 32'd1;
				lrem <= lrem - 24'd1;
				lwritten <= lwritten + 32'd1;
				if (lwritten + 32'd1 >= {8'd0, lsize}) begin
					done <= 1'b1;
					st   <= H_IDLE;
				end else if (lrem == 24'd1) begin
					st <= H_RL_FLG;
				end else
					st <= H_RL_LR;
			end
		end

		H_RL_RR: begin
			if (!a_busy && !a_done) `HLE_RD(2'd0, lsrc)
			else if (a_done) begin
				a_done <= 1'b0;
				cval <= rd_lane;
				lsrc <= lsrc + 32'd1;
				st   <= H_RL_RW;
			end
		end

		H_RL_RW: begin
			if (!a_busy && !a_done) `HLE_WR(2'd0, ldst, cval)
			else if (a_done) begin
				a_done <= 1'b0;
				ldst <= ldst + 32'd1;
				lrem <= lrem - 24'd1;
				lwritten <= lwritten + 32'd1;
				if (lwritten + 32'd1 >= {8'd0, lsize}) begin
					done <= 1'b1;
					st   <= H_IDLE;
				end else if (lrem == 24'd1) begin
					st <= H_RL_FLG;
				end else
					st <= H_RL_RW;
			end
		end

		//----------------------------------------------------------
		// IntrWait / VBlankIntrWait
		//----------------------------------------------------------
		H_IW_IME: begin      // IME=1 is written: discard old flags if asked
			if (a_done) begin
				a_done <= 1'b0;
				if (iwdisc) begin
					`HLE_WR(2'd1, A_IF, {16'd0, iwflags})   // write 1 to clear
					st <= H_IW_CLR;
				end else
					st <= H_IW_IE;
			end
		end

		H_IW_CLR: begin
			if (a_done) `HLE_IDLE(H_IW_IE)
		end

		H_IW_IE: begin
			if (!a_busy && !a_done) `HLE_RD(2'd1, A_IE)
			else if (a_done) begin
				a_done <= 1'b0;
				iw_ie  <= rd_lane[15:0];
				st     <= H_IW_IF;
			end
		end

		H_IW_IF: begin
			if (!a_busy && !a_done) `HLE_RD(2'd1, A_IF)
			else if (a_done) begin
				a_done <= 1'b0;
				// the waiting flags are left set: the game's handler acks them
				if ((rd_lane[15:0] & iw_ie & iwflags) != 16'd0) begin
					done <= 1'b1;
					st   <= H_IDLE;
				end else
					st <= H_IW_IE;
			end
		end

		//----------------------------------------------------------
		// Halt: (IE AND IF) is what wakes the CPU, IME is don't-care
		//----------------------------------------------------------
		H_HLT_IE: begin
			if (!a_busy && !a_done) `HLE_RD(2'd1, A_IE)
			else if (a_done) begin
				a_done <= 1'b0;
				iw_ie  <= rd_lane[15:0];
				st     <= H_HLT_IF;
			end
		end

		H_HLT_IF: begin
			if (!a_busy && !a_done) `HLE_RD(2'd1, A_IF)
			else if (a_done) begin
				a_done <= 1'b0;
				if ((rd_lane[15:0] & iw_ie) != 16'd0) begin
					done <= 1'b1;
					st   <= H_IDLE;
				end else
					st <= H_HLT_IE;
			end
		end

		default: st <= H_IDLE;
		endcase
	end
end

// `undef'd so the names cannot leak into arm7_core.sv / arm9_core.sv, which
// are compiled alongside this module
`undef HLE_RD
`undef HLE_WR
`undef HLE_IDLE

endmodule
