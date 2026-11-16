//============================================================================
// NDS MiSTer -- slot-2 32 MB expansion pak, backed by DDR3
//
// The 8 and 16 MB paks fit in the 32 MB SDRAM module, on main_bus's is_exp
// path. The 32 MB pak does not: it is 16M halfwords by itself, more than
// the whole SDRAM module, and its window runs from 0x09000000 to
// 0x0AFFFFFF. So it lives in DDR3 beside the cart ROM, past the four cart
// slots, and NDS.sv routes its transactions here instead of to
// mem_arbiter. main_bus keeps presenting its usual held halfword request,
// so the bus state machine never learns which memory answered.
//
// DDR3 is slow and shared, so the shim keeps a line and fetches ahead:
//
//   slot 0  the last line a bus access used
//   slot 1  the line after it, fetched while the bus was idle
//
// A line holds four halfwords, and main_bus asks for two of them per 32-bit
// access, so the second half costs no line. The prefetch only runs with no
// request pending, and a hit during a prefetch is served without the port,
// so prefetching cannot make an access slower than no cache at all. It
// waits for the bus to be quiet first: firing at the first free cycle
// would put a fetch in front of the next real access, and take a line from
// the cart, to gain nothing while the port is already busy.
//
// Writes are collected instead of sent one halfword at a time. A 32-bit
// store arrives as two halfword beats, so the shim holds the first and
// merges the second into it, and one line goes out for the pair. The
// buffer is written out before anything that would read the line, before a
// write to a different line, and on its own when the bus goes quiet, so a
// store that is never followed by anything else still reaches DDR3. Writes
// go through to the memory (it is the truth) and are also applied to a
// cached copy, so a read after a write sees it without a fetch.
//============================================================================
module exp_ddr (
	input             clk,
	input             reset,

	// ---- from main_bus: a held halfword request ----
	input             req,
	input             wr,
	input      [23:0] hw,        // halfword offset inside the pak
	input      [15:0] wdata,
	input       [1:0] be,        // be[0] is the low byte, be[1] the high
	output reg        done,      // pulse while the access is served
	output reg [15:0] rdata,

	// ---- DDR3 (ddr_arb's second requester) ----
	output reg        d_req,
	output reg        d_wr,
	output reg [28:0] d_addr,
	output reg [63:0] d_din,
	output reg  [7:0] d_be,
	input             d_ack,
	input      [63:0] d_dout,
	input             d_busy
);

// Line 0x200_0000 is 256 MB into the DDR3: a cart slot addresses 256 MB at
// most, so nothing staged as a ROM can reach the pak's lines.
localparam [28:0] EXP_LINE_BASE = 29'h200_0000;

localparam [3:0] E_IDLE = 4'd0, E_WAIT = 4'd1, E_DONE = 4'd2,
                 E_HOLD = 4'd3, E_PFWAIT = 4'd4, E_FLUSH = 4'd5;
reg [3:0] st = E_IDLE;

reg [23:0] last_hw = 24'd0;
reg        served  = 1'b0;      // one access served in this hold window

wire [24:0] byte_off = {hw, 1'b0};
wire [21:0] line_idx = byte_off[24:3];
wire  [2:0] lane     = byte_off[2:0];

// the two bytes of the halfword, placed at their lane inside the line
wire [7:0] lane_be = (be[0] ? (8'h01 << lane)          : 8'h00) |
                     (be[1] ? (8'h01 << (lane + 3'd1)) : 8'h00);

wire [63:0] dout_sh = d_dout >> {lane, 3'b000};

// this beat's bytes, in their own place in the line: two beats to the same
// line are merged, so each one's data has to stay where it belongs
reg [63:0] beat_dat;
always @* begin
	beat_dat = 64'd0;
	if (be[0]) beat_dat[{lane, 3'b000} +: 8] = wdata[7:0];
	if (be[1]) beat_dat[{lane + 3'd1, 3'b000} +: 8] = wdata[15:8];
end

//------------------------------------------------------------------
// the line kept from the last access, and the one fetched ahead of it
//------------------------------------------------------------------
reg [63:0] cl0_dat = 64'd0, cl1_dat = 64'd0;
reg [21:0] cl0_idx = 22'd0, cl1_idx = 22'd0;
reg        cl0_val = 1'b0,  cl1_val = 1'b0;

wire hit0 = cl0_val && (cl0_idx == line_idx);
wire hit1 = cl1_val && (cl1_idx == line_idx);
wire hit  = hit0 || hit1;
wire [63:0] hit_dat = hit0 ? cl0_dat : cl1_dat;
wire [63:0] hit_sh  = hit_dat >> {lane, 3'b000};

// a cached line with these bytes written into it
function [63:0] apply_bytes;
	input [63:0] line;
	input [21:0] idx;
	input [21:0] want;
	input [63:0] dat;
	input  [7:0] b;
	integer k;
	begin
		apply_bytes = line;
		if (idx == want)
			for (k = 0; k < 8; k = k + 1)
				if (b[k]) apply_bytes[k*8 +: 8] = dat[k*8 +: 8];
	end
endfunction

//------------------------------------------------------------------
// the write being collected: one line's worth of bytes
//------------------------------------------------------------------
reg        pw_val = 1'b0;
reg [21:0] pw_idx = 22'd0;
reg [63:0] pw_dat = 64'd0;
reg  [7:0] pw_be  = 8'h00;

// a second beat to the same line joins the first; anything else -- a read,
// another line, overlapping bytes -- means the buffer goes out first
wire merge_ok = pw_val && (pw_idx == line_idx) && ((pw_be & lane_be) == 8'h00);
wire must_flush = pw_val && req && !merge_ok && (!served || hw != last_hw);

//------------------------------------------------------------------
// is this access continuing a walk through the pak?
//------------------------------------------------------------------
reg [21:0] prev_idx = 22'd0;
reg        prev_val = 1'b0;
wire seq_ok = !prev_val || (line_idx == prev_idx) ||
              (line_idx == prev_idx + 22'd1);

// pending prefetch: the line after the one just served. It waits for the
// bus to go quiet first: firing at the first free cycle would put a fetch
// in front of the next real access, and take a line from the cart, to gain
// nothing when the access pattern is already keeping the port busy.
reg        pf_want = 1'b0;
reg [21:0] pf_idx  = 22'd0;
reg  [3:0] quiet   = 4'd0;      // consecutive cycles with no request
localparam [3:0] PF_QUIET = 4'd8;

always @(posedge clk) begin
	if (reset) begin
		st      <= E_IDLE;
		last_hw <= 24'd0;
		served  <= 1'b0;
		done    <= 1'b0;
		rdata   <= 16'h0000;
		d_req   <= 1'b0;
		d_wr    <= 1'b0;
		d_addr  <= 29'd0;
		d_din   <= 64'd0;
		d_be    <= 8'h00;
		cl0_val <= 1'b0;
		cl1_val <= 1'b0;
		prev_val <= 1'b0;
		pf_want <= 1'b0;
		quiet   <= 4'd0;
		pw_val  <= 1'b0;
		pw_be   <= 8'h00;
	end else begin
		done <= 1'b0;
		if (!req) served <= 1'b0;
		quiet <= req ? 4'd0 : (quiet == 4'd15 ? 4'd15 : quiet + 4'd1);

		case (st)
		E_IDLE: begin
			if (must_flush || (pw_val && !req && quiet >= PF_QUIET)) begin
				// the collected write goes out ahead of whatever comes next
				d_req  <= 1'b1;
				d_wr   <= 1'b1;
				d_addr <= EXP_LINE_BASE + {7'd0, pw_idx};
				d_din  <= pw_dat;
				d_be   <= pw_be;
				st     <= E_FLUSH;
			end else if (req && (!served || hw != last_hw)) begin
				last_hw  <= hw;
				served   <= 1'b1;
				prev_idx <= line_idx;
				prev_val <= 1'b1;
				if (wr) begin
					// collect it; the bus is answered without the port
					pw_val <= 1'b1;
					pw_idx <= line_idx;
					pw_dat <= merge_ok ? (pw_dat | beat_dat) : beat_dat;
					pw_be  <= merge_ok ? (pw_be | lane_be) : lane_be;
					st     <= E_DONE;
				end else if (hit) begin
					// served from the cache, no port traffic. Only a line in
					// slot 0 leaves the other slot free to prefetch into: an
					// access served from slot 1 is using the prefetched line
					// itself, and fetching on from there would evict the line
					// still in use.
					rdata   <= hit_sh[15:0];
					pf_want <= hit0 && seq_ok;
					pf_idx  <= line_idx + 22'd1;
					st      <= E_DONE;
				end else begin
					d_req  <= 1'b1;
					d_wr   <= 1'b0;
					d_addr <= EXP_LINE_BASE + {7'd0, line_idx};
					d_be   <= 8'hFF;
					st     <= E_WAIT;
				end
			end else if (!req && !pw_val && pf_want) begin
				if (cl1_val && cl1_idx == pf_idx) begin
					pf_want <= 1'b0;      // already here: nothing to fetch
				end else if (quiet >= PF_QUIET) begin
					d_req  <= 1'b1;
					d_wr   <= 1'b0;
					d_addr <= EXP_LINE_BASE + {7'd0, pf_idx};
					d_be   <= 8'hFF;
					st     <= E_PFWAIT;
				end
			end
		end

		E_WAIT: if (d_ack) begin
			d_req <= 1'b0;
			cl0_dat <= d_dout;
			cl0_idx <= line_idx;
			cl0_val <= 1'b1;
			cl1_val <= 1'b0;   // the old prefetch is behind us now
			pf_want <= seq_ok;
			pf_idx  <= line_idx + 22'd1;
			rdata <= dout_sh[15:0];
			st    <= E_DONE;
		end

		// the collected write, landing: the cached copy of that line
		// follows it, so a read that hits afterwards still sees the store
		E_FLUSH: if (d_ack) begin
			d_req   <= 1'b0;
			cl0_dat <= apply_bytes(cl0_dat, cl0_idx, pw_idx, pw_dat, pw_be);
			cl1_dat <= apply_bytes(cl1_dat, cl1_idx, pw_idx, pw_dat, pw_be);
			pw_val  <= 1'b0;
			pw_be   <= 8'h00;
			st      <= E_IDLE;
		end

		E_DONE: begin
			done <= 1'b1;
			st   <= E_HOLD;
		end

		// The bus holds req across both halfwords of a 32-bit access, so a
		// new beat is also a new address: either end of that ends the hold.
		E_HOLD: if (!req || hw != last_hw) st <= E_IDLE;

		E_PFWAIT: begin
			// a real access still gets served: a read that hits needs no
			// port, so it is answered while the prefetch is in flight
			if (req && (!served || hw != last_hw) && !wr && hit) begin
				last_hw  <= hw;
				served   <= 1'b1;
				prev_idx <= line_idx;
				prev_val <= 1'b1;
				rdata    <= hit_sh[15:0];
				done     <= 1'b1;
			end
			if (d_ack) begin
				d_req   <= 1'b0;
				cl1_dat <= d_dout;
				cl1_idx <= pf_idx;
				cl1_val <= 1'b1;
				pf_want <= 1'b0;
				st      <= E_IDLE;
			end
		end

		default: st <= E_IDLE;
		endcase
	end
end

endmodule
