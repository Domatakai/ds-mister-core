//============================================================================
// NDS MiSTer Test — SDRAM arbiter (three masters, fixed priority)
//
//   master A: main_bus RAM window  (CPU main RAM, round-robin server)
//   master B: cart_slot save path (SRAM/EEPROM/Flash, M4)
//   master C: vram_arbiter         (2D engines + CPU VRAM, M2)
//
// Priority: save > VRAM > bus window. Saves are tiny, latency-sensitive
// bursts that must never be starved; VRAM traffic is periodic per-scanline
// fetch bursts from the engines that would glitch the picture if starved;
// CPU main-RAM traffic tolerates extra cycles. One outstanding request at
// a time; the granted master sees its `*_ready` pulse when read data is
// valid or a write is committed.
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
	output reg       vram_ready,

	// toward sdram_ctrl
	output reg       sdram_req,
	output reg       sdram_wr,
	output reg [24:0] sdram_addr,
	output reg [15:0] sdram_wdata,
	output reg [1:0] sdram_be,
	input            sdram_rd_done, // read data valid
	input            sdram_wr_done, // write committed
	input     [15:0] sdram_rdata
);

localparam S_IDLE = 2'd0, S_BUSY = 2'd1, S_HOLD = 2'd2;
localparam OWN_BUS = 2'd0, OWN_SAVE = 2'd1, OWN_VRAM = 2'd2;

reg [1:0] state = S_IDLE;
reg [1:0] owner = OWN_BUS;
reg       pending = 0; // waiting for sdram_rd/wr_done
reg [24:0] last_addr = 0; // address of the granted op (multi-beat detect)
reg        last_wr = 0;

always @(posedge clk) begin
	bus_ready   <= 0;
	save_ready  <= 0;
	vram_ready  <= 0;

	case (state)
	S_IDLE: begin
		if (save_req) begin
			owner      <= OWN_SAVE;
			sdram_req  <= 1;
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
			sdram_wr   <= bus_wr;
			sdram_addr <= bus_addr;
			sdram_wdata<= bus_wdata;
			sdram_be   <= bus_be;
			pending    <= 1;
			state      <= S_BUSY;
			last_addr  <= bus_addr;
			last_wr    <= bus_wr;
		end
	end

	S_BUSY: begin
		sdram_req <= 0; // single-cycle accept pulse
		if (pending && (sdram_rd_done || sdram_wr_done)) begin
			pending <= 0;
			case (owner)
			OWN_SAVE: save_ready <= 1;
			OWN_VRAM: vram_ready <= 1;
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
		default:  if (!bus_req  || bus_addr  != last_addr  || bus_wr  != last_wr)
		              state <= S_IDLE;
		endcase
	end

	default: state <= S_IDLE;
	endcase

	if (reset) begin
		state <= S_IDLE;
		sdram_req <= 0; sdram_wr <= 0;
		bus_ready <= 0; save_ready <= 0; vram_ready <= 0;
		pending <= 0; owner <= OWN_BUS;
	end
end

endmodule
