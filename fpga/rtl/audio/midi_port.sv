//============================================================================
// NDS MiSTer Test — MIDI port for MT-32-pi
//
// The DS puts an SPI/IR port at 0x04000150 on the ARM9 side (AUXSPICNT /
// AUXSPIDATA). Nothing in the emulation drives it yet — the ARM cores are
// stubs — so this module provides the two halves a MIDI link needs:
//
//   * the UART. MIDI serial is 8N1 at 31.25 kbaud, which is exactly 1536
//     ticks of a 48 kHz strobe, so the bit clock is a divide of the sample
//     clock rather than a separate PLL. TX shifts out of a 16-byte queue;
//     RX recovers bytes by sampling each bit at its centre (0.5 bit after a
//     falling start edge, then once per bit), with a two-flop synchroniser
//     on the pin because MT-32-pi clocks that line from its own domain.
//
//   * the register decode. AUXSPICNT bit 13 selects direction (0 = write to
//     the device, 1 = read from it); bit 0 reads back "busy" while a byte is
//     still queued or shifting. 0x0400015A returns the oldest byte waiting in
//     an 8-deep receive FIFO. MT-32-pi (and any MIDI device) can send a whole
//     running-status message back to back — 3 bytes minimum, plus controller
//     dumps — so the receiver has to hold more than one byte or a CPU that is
//     busy for a couple of byte times silently loses them.
//
// Because no game code runs yet, the OSD can switch on a small internal
// stream (0x90/0x80 note on/off pairs through a C major arpeggio). That is
// what makes MT-32-pi audible today: enable it, and the port plays a phrase
// into the Pi while the DS side stays silent. Once the ARM7 runs, the same
// queue carries whatever the game writes, unchanged.
//============================================================================
module midi_port (
	input             clk,
	input             reset,
	input             tick_48k,      // one-cycle strobe at 48 kHz

	// AUX port, forwarded by main_bus (0x04000150..0x0400015A)
	input             wr,            // one-cycle write strobe
	input             rd,            // one-cycle read strobe
	input      [15:0] addr,          // io_addr (0x0150 / 0x0154 / 0x015A)
	input      [15:0] wdata,
	output reg [15:0] rdata,

	// serial side
	output            tx,            // 31.25 kbaud, idle high
	output            tx_busy,
	input             rx,

	// internal demo stream
	input             demo_en,
	input             demo_restart
);

	// 31.25 kbaud at 48 kHz: exactly 1536 sample ticks per bit.
	localparam [10:0]  BIT_TICKS = 11'd1536;
	parameter  [15:0] DEMO_GAP   = 16'd14400;   // 300 ms between demo bytes

	//------------------------------------------------------------------
	// registers as the CPU sees them
	//------------------------------------------------------------------
	// spicnt[15:1] is software-owned (bit 13 = direction, 0 = write to the
	// device); bit 0 is hardware status, so the two are kept apart.
	reg  [14:0] spicnt = 15'd0;
	wire        dir_out = ~spicnt[12];      // 0 = write, 1 = read

	wire sel_cnt  = (addr[7:1] == 7'h28);   // 0x0150 / 0x0152
	wire sel_data = (addr[7:1] == 7'h2A);   // 0x0154 / 0x0156
	wire sel_rx   = (addr[7:1] == 7'h2D);   // 0x015A

	//------------------------------------------------------------------
	// transmit queue
	// 16 entries is more than any single register write needs and covers a
	// demo phrase byte-spacing apart; the CPU polls bit 0 when it cares.
	//------------------------------------------------------------------
	reg  [7:0] q_mem [0:15];
	reg  [4:0] q_wr = 5'd0;
	reg  [4:0] q_rd = 5'd0;
	wire [4:0] q_n     = q_wr - q_rd;
	wire       q_empty = (q_n == 5'd0);
	wire       q_full  = (q_n == 5'd16);

	//------------------------------------------------------------------
	// internal demo stream
	//------------------------------------------------------------------
	reg  [4:0]  demo_idx  = 5'd0;
	reg [15:0]  demo_cnt  = DEMO_GAP;
	reg         demo_fire = 1'b0;
	reg  [7:0]  demo_hold = 8'h00;

	// A C major arpeggio on channel 1, as note-on / note-off pairs, three
	// bytes per message: status, note, velocity. 24 bytes round the phrase;
	// the OSD switch is what a MIDI device gets to hear with no game code.
	function [7:0] demo_byte_of;
		input [4:0] e;
		begin
			case (e)
			5'd0:  demo_byte_of = 8'h90;   // C4 on
			5'd1:  demo_byte_of = 8'h3C;
			5'd2:  demo_byte_of = 8'h64;
			5'd3:  demo_byte_of = 8'h80;   // C4 off
			5'd4:  demo_byte_of = 8'h3C;
			5'd5:  demo_byte_of = 8'h40;
			5'd6:  demo_byte_of = 8'h90;   // E4 on
			5'd7:  demo_byte_of = 8'h40;
			5'd8:  demo_byte_of = 8'h64;
			5'd9:  demo_byte_of = 8'h80;   // E4 off
			5'd10: demo_byte_of = 8'h40;
			5'd11: demo_byte_of = 8'h40;
			5'd12: demo_byte_of = 8'h90;   // G4 on
			5'd13: demo_byte_of = 8'h43;
			5'd14: demo_byte_of = 8'h64;
			5'd15: demo_byte_of = 8'h80;   // G4 off
			5'd16: demo_byte_of = 8'h43;
			5'd17: demo_byte_of = 8'h40;
			5'd18: demo_byte_of = 8'h90;   // C5 on
			5'd19: demo_byte_of = 8'h48;
			5'd20: demo_byte_of = 8'h64;
			5'd21: demo_byte_of = 8'h80;   // C5 off
			5'd22: demo_byte_of = 8'h48;
			5'd23: demo_byte_of = 8'h40;
			default: demo_byte_of = 8'h80;
			endcase
		end
	endfunction

	always @(posedge clk) begin
		demo_fire <= 1'b0;
		if (reset || demo_restart || !demo_en) begin
			demo_cnt  <= DEMO_GAP;
			demo_idx  <= 5'd0;
			demo_fire <= 1'b0;
		end else if (tick_48k) begin
			if (demo_cnt == 16'd0) begin
				demo_cnt  <= DEMO_GAP;
				demo_fire <= 1'b1;
				demo_hold <= demo_byte_of(demo_idx);
				demo_idx  <= (demo_idx == 5'd23) ? 5'd0 : demo_idx + 5'd1;
			end else begin
				demo_cnt <= demo_cnt - 16'd1;
			end
		end
	end

	wire push_bus  = wr && sel_data && dir_out && !q_full;
	wire push_demo = demo_fire && demo_en && !q_full;
	wire [7:0] push_byte = push_bus ? wdata[7:0] : demo_hold;

	//------------------------------------------------------------------
	// transmitter: start bit, 8 data bits LSB first, stop bit
	//------------------------------------------------------------------
	reg  [9:0] tx_sh = 10'h3FF;     // {stop, data[7:0], start}
	reg  [3:0] tx_bit = 4'd0;
	reg        tx_run = 1'b0;
	reg        tx_level = 1'b1;
	reg [10:0] tx_cnt = 11'd0;

	assign tx      = tx_level;
	assign tx_busy = tx_run;

	wire tx_start = !tx_run && !q_empty;
	wire [7:0] tx_next = q_mem[q_rd[3:0]];

	always @(posedge clk) begin
		if (reset) begin
			tx_run   <= 1'b0;
			tx_level <= 1'b1;
			tx_cnt   <= 11'd0;
			q_wr     <= 5'd0;
			q_rd     <= 5'd0;
		end else begin
			if (push_bus || push_demo) begin
				q_mem[q_wr[3:0]] <= push_byte;
				q_wr <= q_wr + 5'd1;
			end

			if (!tx_run) begin
				if (tx_start) begin
					tx_sh    <= {1'b1, tx_next, 1'b0};
					tx_level <= 1'b0;             // start bit
					tx_bit   <= 4'd0;
					tx_cnt   <= 11'd0;
					tx_run   <= 1'b1;
					q_rd     <= q_rd + 5'd1;
				end
			end else if (tick_48k) begin
				if (tx_cnt != BIT_TICKS - 11'd1) begin
					tx_cnt <= tx_cnt + 11'd1;
				end else begin
					tx_cnt <= 11'd0;
					if (tx_bit == 4'd9) begin
						tx_level <= 1'b1;         // stop bit held
						tx_run   <= 1'b0;
					end else begin
						tx_level <= tx_sh[1];
						tx_sh    <= {1'b1, tx_sh[9:1]};
						tx_bit   <= tx_bit + 4'd1;
					end
				end
			end
		end
	end

	//------------------------------------------------------------------
	// receiver
	//------------------------------------------------------------------
	reg rx_s1 = 1'b1, rx_s2 = 1'b1, rx_q = 1'b1;
	always @(posedge clk) begin
		rx_s1 <= rx;
		rx_s2 <= rx_s1;
		rx_q  <= rx_s2;
	end
	wire rx_fall = rx_q & ~rx_s2;

	reg  [7:0] rx_sh    = 8'h00;
	reg        rx_done  = 1'b0;   // one-cycle strobe: a byte just completed
	reg        rx_act   = 1'b0;
	reg  [3:0] rx_bitn  = 4'd0;   // 0 = start, 1..8 = data, 9 = stop
	reg [10:0] rx_cnt   = 11'd0;

	localparam [10:0] HALF_TICKS = BIT_TICKS >> 1;

	always @(posedge clk) begin
		if (reset) begin
			rx_act  <= 1'b0;
			rx_done <= 1'b0;
		end else begin
			rx_done <= 1'b0;

			if (!rx_act) begin
				if (rx_fall) begin
					// a start edge: sample the middle of each bit from here
					rx_act  <= 1'b1;
					rx_bitn <= 4'd0;
					rx_cnt  <= HALF_TICKS - 11'd1;
				end
			end else if (tick_48k) begin
				if (rx_cnt != 11'd0) begin
					rx_cnt <= rx_cnt - 11'd1;
				end else begin
					rx_cnt <= BIT_TICKS - 11'd1;
					if (rx_bitn == 4'd0) begin
						// middle of the start bit: still low, or it was a glitch
						if (rx_s2) rx_act <= 1'b0;
						else       rx_bitn <= 4'd1;
					end else if (rx_bitn <= 4'd8) begin
						rx_sh   <= {rx_s2, rx_sh[7:1]};   // LSB first
						rx_bitn <= rx_bitn + 4'd1;
					end					else begin
						// stop bit; keep the byte even if the sender is early
						rx_act  <= 1'b0;
						rx_done <= 1'b1;
					end
				end
			end
		end
	end

	//------------------------------------------------------------------
	// receive FIFO (8 bytes)
	//
	// A read pops the oldest byte; with the FIFO empty the register holds
	// zero and the read is a no-op. Bytes arriving with the FIFO full are
	// dropped rather than overwriting one still waiting — 8 bytes is 2.6 ms
	// of wire time at 31.25 kbaud, far longer than a MIDI message.
	//------------------------------------------------------------------
	reg  [7:0] rxq_mem [0:7];
	reg  [3:0] rxq_w = 4'd0;
	reg  [3:0] rxq_r = 4'd0;
	wire [3:0] rxq_n    = rxq_w - rxq_r;
	wire       rxq_empty = (rxq_n == 4'd0);
	wire       rxq_full  = (rxq_n == 4'd8);

	always @(posedge clk) begin
		if (reset) begin
			rxq_w <= 4'd0;
			rxq_r <= 4'd0;
		end else begin
			if (rx_done && !rxq_full) begin
				rxq_mem[rxq_w[2:0]] <= rx_sh;
				rxq_w <= rxq_w + 4'd1;
			end
			if (rd && sel_rx && !rxq_empty) rxq_r <= rxq_r + 4'd1;
		end
	end

	//------------------------------------------------------------------
	// register reads and the AUXSPICNT write
	//------------------------------------------------------------------
	always @(*) begin
		rdata = 16'h0000;
		if (sel_cnt)      rdata = {spicnt, tx_busy | ~q_empty};
		else if (sel_rx)  rdata = {8'h00, rxq_empty ? 8'h00 : rxq_mem[rxq_r[2:0]]};
	end

	always @(posedge clk) begin
		if (reset) spicnt <= 15'd0;
		else if (wr && sel_cnt) spicnt <= wdata[15:1];
	end

endmodule

