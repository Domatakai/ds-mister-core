//============================================================================
// NDS MiSTer Test — SDRAM arbiter (four masters, fixed priority)
//
//   master A: main_bus RAM window  (CPU main RAM, round-robin server)
//   master B: cart_slot save path (SRAM/EEPROM/Flash, M4)
//   master C: vram_arbiter         (2D engines + CPU VRAM, M2)
//   master D: spu sample fetch     (one halfword per channel sample, M4)
//
// Priority: save > VRAM > bus window > SPU. Saves are tiny, latency-
// sensitive bursts that must never be starved; VRAM traffic is periodic
// per-scanline fetch bursts from the engines that would glitch the picture
// if starved; CPU main-RAM traffic tolerates extra cycles. The SPU comes
// last because a sample fetch has a whole sample period of slack — a whole
// 32 kHz period is ~1500 clocks, while even a 64-beat VRAM burst only
// occupies the controller for ~73 — and the masters ahead of it release
// the port between transactions, so a held SPU request wins the first free
// slot. One outstanding request at a time; the granted master sees its
// `*_ready` pulse when read data is valid, a write is committed, or a read
// burst has returned its last beat.
//
// The VRAM master may ask for a linear read burst instead of a single
// access (the 3D frame fetch does: a scanline is 256 halfwords, and paying
// a full round trip for each one is what kept the merge from fitting a
// line period). A burst is granted as one transaction — the arbitration
// decision and the shipping deadline are per burst, not per beat — and its
// beats stream back through `vram_bs_valid`/`vram_bs_data` while the grant
// is held. The stream has no back-pressure: a beat presented on a cycle
// must be consumed on that cycle, which is what the merge pass does.
//============================================================================
module mem_arbiter (
	input            clk,
	input            reset,

	// master A: main bus RAM window
	input            bus_req,
	input            bus_wr,
	input     [24:0] bus_addr,
	input     [15:0] bus_wdata,
	input      [1:0] bus_be,
	output reg       bus_ready,

	// master B: cart save path
	input            save_req,
	input            save_wr,
	input     [24:0] save_addr,
	input     [15:0] save_wdata,
	input      [1:0] save_be,
	output reg       save_ready,

	// master C: VRAM path (vram_arbiter)
	input            vram_req,
	input            vram_wr,
	input     [24:0] vram_addr,
	input     [15:0] vram_wdata,
	input      [1:0] vram_be,
	input            vram_bst,      // the request is a read burst of vram_len
	input      [7:0] vram_len,
	input      [1:0] vram_step,     // address units between burst beats
	output reg       vram_ready,
	output           vram_bs_valid, // burst beats, in address order
	output    [15:0] vram_bs_data,

	// master D: SPU sample fetch (read-only, one halfword per grant)
	input            spu_req,
	input     [24:0] spu_addr,
	output reg       spu_ready,
	output    [15:0] spu_rdata,

	// toward sdram_ctrl
	output reg       sdram_req,
	output reg       sdram_wr,
	output reg [24:0] sdram_addr,
	output reg [15:0] sdram_wdata,
	output reg [1:0] sdram_be,
	output reg       sdram_bst,
	output reg [7:0] sdram_len,
	output reg [1:0] sdram_step,
	input            sdram_rd_done, // read data valid
	input            sdram_wr_done, // write committed
	input            sdram_bst_done,// burst finished, every beat sent
	input            sdram_bs_valid,
	input     [15:0] sdram_bs_data,
	input     [15:0] sdram_rdata
);

localparam S_IDLE = 2'd0, S_BUSY = 2'd1, S_HOLD = 2'd2;
localparam OWN_BUS = 2'd0, OWN_SAVE = 2'd1, OWN_VRAM = 2'd2, OWN_SPU = 2'd3;

reg [1:0] state = S_IDLE;
reg [1:0] owner = OWN_BUS;
reg       pending = 0; // waiting for sdram_rd/wr_done
reg [24:0] last_addr = 0; // address of the granted op (multi-beat detect)
reg        last_wr = 0;

// burst beats belong to the VRAM master that is currently being granted
assign vram_bs_valid = sdram_bs_valid && pending && (owner == OWN_VRAM);
assign vram_bs_data  = sdram_bs_data;

// the SPU's fetched word is simply the controller's read data, valid on its
// spu_ready pulse
assign spu_rdata = sdram_rdata;

always @(posedge clk) begin
	bus_ready   <= 0;
	save_ready  <= 0;
	vram_ready  <= 0;
	spu_ready   <= 0;

	case (state)
	S_IDLE: begin
		if (save_req) begin
			owner      <= OWN_SAVE;
			sdram_req  <= 1;
			sdram_bst  <= 0;
			sdram_wr   <= save_wr;
			sdram_addr <= save_addr;
			sdram_wdata<= save_wdata;
			sdram_be   <= save_be;
			pending    <= 1;
			state      <= S_BUSY;
			last_addr  <= save_addr;
			last_wr    <= save_wr;
		end else if (vram_req) begin
			owner      <= OWN_VRAM;
			sdram_req  <= 1;
			sdram_bst  <= vram_bst;
			sdram_len  <= vram_len;
			sdram_step <= vram_step;
			sdram_wr   <= vram_wr;
			sdram_addr <= vram_addr;
			sdram_wdata<= vram_wdata;
			sdram_be   <= vram_be;
			pending    <= 1;
			state      <= S_BUSY;
			last_addr  <= vram_addr;
			last_wr    <= vram_wr;
		end else if (bus_req) begin
			owner      <= OWN_BUS;
			sdram_req  <= 1;
			sdram_bst  <= 0;
			sdram_wr   <= bus_wr;
			sdram_addr <= bus_addr;
			sdram_wdata<= bus_wdata;
			sdram_be   <= bus_be;
			pending    <= 1;
			state      <= S_BUSY;
			last_addr  <= bus_addr;
			last_wr    <= bus_wr;
		end else if (spu_req) begin
			owner      <= OWN_SPU;
			sdram_req  <= 1;
			sdram_bst  <= 0;
			sdram_wr   <= 0;
			sdram_addr <= spu_addr;
			sdram_wdata<= 16'd0;
			sdram_be   <= 2'b11;
			pending    <= 1;
			state      <= S_BUSY;
			last_addr  <= spu_addr;
			last_wr    <= 1'b0;
		end
	end

	S_BUSY: begin
		sdram_req <= 0; // single-cycle accept pulse
		if (pending && (sdram_rd_done || sdram_wr_done || sdram_bst_done)) begin
			pending <= 0;
			case (owner)
			OWN_SAVE: save_ready <= 1;
			OWN_VRAM: vram_ready <= 1;
			OWN_SPU:  spu_ready  <= 1;
			default:  bus_ready  <= 1;
			endcase
			state <= S_HOLD;
		end
	end

	// Wait for the granted master to drop its request line so a held
	// (rather than pulsed) request is never latched twice. A master
	// that keeps req asserted with a DIFFERENT address is issuing its
	// next beat (32-bit accesses run as two halfword ops) — release
	// immediately so the second beat is granted without deadlock.
	S_HOLD: begin
		case (owner)
		OWN_SAVE: if (!save_req) state <= S_IDLE;
		OWN_VRAM: if (!vram_req || vram_addr != last_addr || vram_wr != last_wr)
		              state <= S_IDLE;
		OWN_SPU:  if (!spu_req || spu_addr != last_addr)
		              state <= S_IDLE;
		default:  if (!bus_req  || bus_addr  != last_addr  || bus_wr  != last_wr)
		              state <= S_IDLE;
		endcase
	end

	default: state <= S_IDLE;
	endcase

	if (reset) begin
		state <= S_IDLE;
		sdram_req <= 0; sdram_wr <= 0; sdram_bst <= 0; sdram_step <= 0;
		bus_ready <= 0; save_ready <= 0; vram_ready <= 0; spu_ready <= 0;
		pending <= 0; owner <= OWN_BUS;
	end
end

endmodule
