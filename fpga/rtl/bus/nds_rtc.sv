//============================================================================
// NDS MiSTer Test — real-time clock (Seiko S-35180, DS 4000138h)
//
// The DS does not expose the RTC as a register file: 4000138h is a three-wire
// GPIO port the ARM7 bit-bangs (GBATEK, *DS Real-Time Clock*):
//
//   bit 0  data I/O      bit 4  data direction (0 = read, 1 = write)
//   bit 1  clock out     bit 5  clock direction (write)
//   bit 2  select out    bit 6  select direction (write)
//
// Chip select high starts a command byte, transferred LSB first, eight clocks
// per byte. Command bits: 0 = 0, 1 = 1, 2 = 1, 3 = 0 (DSi extended command
// when set), 4-6 = command number, 7 = parameter direction (0 write,
// 1 read). Parameters follow, one byte at a time, over the same bus.
//
//   0  status register 1     4  alarm 1 (dow, hour, minute)
//   1  status register 2     5  alarm 2 (dow, hour, minute)
//   2  date and time, 7 bytes (year, month, day, dow, hour, minute, second)
//   3  time, 3 bytes (hour, minute, second)
//   6  clock adjustment      7  free register
//
// A read therefore shifts out a *snapshot*, taken when the command byte
// completes — the real part latches the registers at that point, so a seconds
// rollover in the middle of the seven-byte date read cannot tear it. Writes
// shift a byte in and are committed as a set when chip select drops.
//
// Time itself is BCD counters driven by a one-second enable. The DS's part is
// battery-backed and free-running; here they start at a fixed date from reset
// and any date/time the game writes becomes the setting, so the "set the
// clock" path round-trips exactly.
//
// Not modelled: the alarm comparison and the /INT output (nothing this core
// targets arms the RTC alarm), and the DSi extended register set.
//============================================================================
module nds_rtc (
	input             clk,
	input             reset,

	input             sec_tick,   // one-cycle enable, once per second

	// 4000138h, ARM7 only
	input             wr,
	input      [15:0] wdata,
	output reg [15:0] rdata,

	output            irq         // /INT to the ARM7 SIO input
);

	//------------------------------------------------------------------
	// port register
	//------------------------------------------------------------------
	reg data_wr  = 1'b0;      // value the ARM7 drives on the data line
	reg data_dir = 1'b0;      // 0 = read, 1 = write
	reg sck      = 1'b0;      // bit 1
	reg cs       = 1'b0;      // bit 2

	//------------------------------------------------------------------
	// time counters, BCD like the part
	//------------------------------------------------------------------
	reg [7:0] sec = 8'h00;
	reg [7:0] min = 8'h00;
	reg [7:0] hr  = 8'h12;
	reg [7:0] day = 8'h26;
	reg [7:0] mon = 8'h10;
	reg [7:0] yr  = 8'h26;
	reg [2:0] dow = 3'd1;

	// configurable registers
	reg       mode24 = 1'b1;      // status 1 bit 1
	reg [1:0] gp     = 2'b00;     // status 1 bits 2-3
	reg       intr1  = 1'b0;      // status 1 bit 4
	reg       intr2  = 1'b0;      // status 1 bit 5
	reg       p_low  = 1'b0;      // status 1 bit 6
	reg       p_off  = 1'b0;      // status 1 bit 7
	reg [7:0] stat2  = 8'h00;
	reg [7:0] alarm1_dow = 8'h80, alarm1_hr = 8'h80, alarm1_min = 8'h80;
	reg [7:0] alarm2_dow = 8'h80, alarm2_hr = 8'h80, alarm2_min = 8'h80;
	reg [7:0] clk_adj = 8'h00;
	reg [7:0] free_r  = 8'h00;

	//------------------------------------------------------------------
	// BCD helpers
	//------------------------------------------------------------------
	function [7:0] bcd_inc(input [7:0] v);
		bcd_inc = (v[3:0] == 4'd9) ? {v[7:4] + 4'd1, 4'd0} : (v + 8'd1);
	endfunction

	// 2000..2099: the BCD year's low nibble steps in fours, so yr[3:0]%4 detects
	// the leap years (00, 04, 08 ... 96)
	wire       leap = (yr[3:0] % 4'd4 == 4'd0);
	wire [7:0] dim  =
		(mon == 8'h02) ? (leap ? 8'h29 : 8'h28) :
		(mon == 8'h04 || mon == 8'h06 || mon == 8'h09 || mon == 8'h11) ? 8'h30
		                                                              : 8'h31;

	//------------------------------------------------------------------
	// One clocked block for the whole part
	//------------------------------------------------------------------
	// The counters below and the port/transfer state share a single
	// `always @(posedge clk)` (further down, after the helpers it uses). They
	// are not separable: `sec` and the rest are written both by the one-second
	// tick and by a command parameter commit (`apply_byte`), and the port bits
	// (data_wr/sck/cs/data_dir) by both the ARM7's register writes and this
	// module's reset. Driving the same regs from two clocked blocks is a
	// simulation-only fiction — Icarus silently keeps whichever assignment ran
	// last in its event ordering, Quartus refuses the design outright
	// (Error 10028/10029 on 19 nets). With one block the tick is placed last,
	// so a tick and a parameter commit in the same cycle always resolve the
	// same way rather than racing.

	//------------------------------------------------------------------
	// command / parameter transfer
	//------------------------------------------------------------------
	reg [2:0]  bit_i   = 3'd0;      // bit within the current byte
	reg [2:0]  byte_i  = 3'd0;      // parameter byte being transferred
	reg [7:0]  sh      = 8'd0;      // shift-in register, first bit lands in bit 0
	reg        is_read = 1'b0;
	reg [2:0]  cmd     = 3'd0;
	reg [63:0] snap    = 64'd0;     // parameter snapshot, byte 0 in bits 7:0
	reg [5:0]  pos     = 6'd0;      // bit within the snapshot
	reg        data_in = 1'b0;      // what the ARM7 reads on bit 0
	reg        active  = 1'b0;      // a command byte has been received
	reg [7:0]  wbuf [0:6];

	// status register 1 as the port reports it
	wire [7:0] stat1 = {p_off, p_low, intr2, intr1, gp, mode24, 1'b0};

	// hour as the selected mode reports it (12-hour: 00h..11h plus a PM flag,
	// and 12 o'clock is 00h — GBATEK)
	// 12-hour readback: bit 6 is PM, bits 0-5 the hour, and 12 o'clock is 00h.
	// (The concatenation must be eight bits wide � a ninth bit silently drops
	// the PM flag and shifts the hour.)
	wire [7:0] hr12 = (hr >= 8'h12) ? (hr - 8'h12) : hr;
	wire [7:0] hr_out = mode24 ? hr : {hr >= 8'h12, hr12[5:0]};

	// (`pack_val`, the parameter byte the port shifts out, is the combinational
	// mux after `cmd_now` below: it is not a function because the front end
	// does not credit a function's read of these signals and reports each of
	// them as 10036. The netlist is the same either way -- 262 registers with
	// the mux and with a forced port read of `stat1` -- so the mux only makes
	// the warning list honest.

	// commit one parameter byte of a write command
	task apply_byte;
		input [2:0] c;
		input [2:0] i;
		input [7:0] d;
		begin
			case (c)
			3'd0: begin
				if (d[0]) begin            // bit 0: reset the part to defaults
					mode24 <= 1'b1;
					gp     <= 2'b00;
				end else begin
					mode24 <= d[1];
					gp     <= d[3:2];
				end
			end
			3'd1: stat2 <= d;
			3'd2: begin
				case (i)
				3'd0: yr  <= d;
				3'd1: mon <= d[4:0];
				3'd2: day <= d[5:0];
				3'd3: dow <= d[2:0];
				3'd4: hr  <= mode24 ? {2'b00, d[5:0]} :
				            (d[6] ? ({1'b0, d[4:0]} + 8'h12) : {2'b00, d[5:0]});
				3'd5: min <= d[6:0];
				default: sec <= d[6:0];
				endcase
			end
			3'd3: begin
				case (i)
				3'd0: hr  <= mode24 ? {2'b00, d[5:0]} :
				            (d[6] ? ({1'b0, d[4:0]} + 8'h12) : {2'b00, d[5:0]});
				3'd1: min <= d[6:0];
				default: sec <= d[6:0];
				endcase
			end
			3'd4: case (i)
			      3'd0: alarm1_dow <= d;
			      3'd1: alarm1_hr  <= d;
			      default: alarm1_min <= d;
			      endcase
			3'd5: case (i)
			      3'd0: alarm2_dow <= d;
			      3'd1: alarm2_hr  <= d;
			      default: alarm2_min <= d;
			      endcase
			3'd6: clk_adj <= d;
			3'd7: free_r  <= d;
			default: ;
			endcase
		end
	endtask

	// the byte formed by this clock edge, LSB first
	wire [7:0]  in_byte  = {data_wr, sh[7:1]};
	wire [2:0]  cmd_now  = in_byte[6:4];
	reg  [63:0] pack_val;
	always @(*) begin
		case (cmd_now)
		3'd0: pack_val = {56'd0, stat1};
		3'd1: pack_val = {56'd0, stat2};
		3'd2: pack_val = {8'd0, sec, min, hr_out, {5'd0, dow}, day, mon, yr};
		3'd3: pack_val = {40'd0, sec, min, hr_out};
		3'd4: pack_val = {40'd0, alarm1_min, alarm1_hr, alarm1_dow};
		3'd5: pack_val = {40'd0, alarm2_min, alarm2_hr, alarm2_dow};
		3'd6: pack_val = {56'd0, clk_adj};
		default: pack_val = {56'd0, free_r};
		endcase
	end

	wire [63:0] pack_now = pack_val;

	// The ARM7 moves the port by writing 4000138h: the bit it sends is the data
	// bit it wrote last, and the edge is the clock bit it writes now. Detecting
	// the edge on the write itself (rather than a cycle later on a registered
	// copy of the clock) keeps the transfer in step with the bus.
	wire rise = wr && !sck && wdata[1] && (cs || wdata[2]);
	wire fall = wr &&  sck && !wdata[1] && cs;

	integer k;

	always @(posedge clk) begin
		if (reset) begin
			// transfer state
			bit_i <= 3'd0; byte_i <= 3'd0; sh <= 8'd0;
			data_in <= 1'b0; snap <= 64'd0;
			is_read <= 1'b0; cmd <= 3'd0; active <= 1'b0; pos <= 6'd0;
			data_wr <= 1'b0; data_dir <= 1'b0; sck <= 1'b0; cs <= 1'b0;
			// counters and configuration: the S-35180's own defaults
			sec <= 8'h00; min <= 8'h00; hr <= 8'h12;
			day <= 8'h26; mon <= 8'h10; yr <= 8'h26; dow <= 3'd1;
			mode24 <= 1'b1; gp <= 2'b00;
			intr1 <= 1'b0; intr2 <= 1'b0; p_low <= 1'b0; p_off <= 1'b0;
			stat2 <= 8'h00;
			alarm1_dow <= 8'h80; alarm1_hr <= 8'h80; alarm1_min <= 8'h80;
			alarm2_dow <= 8'h80; alarm2_hr <= 8'h80; alarm2_min <= 8'h80;
			clk_adj <= 8'h00; free_r <= 8'h00;
		end else begin
			// ---- port writes ----
			if (wr) begin
				data_wr  <= wdata[0];
				sck      <= wdata[1];
				cs       <= wdata[2];
				data_dir <= wdata[4];
			end

			// ---- chip select released: commit a write, or just end a read ----
			if (wr && cs && !wdata[2]) begin
				if (active && !is_read)
					for (k = 0; k < 7; k = k + 1)
						if (k < byte_i)
							apply_byte(cmd, k[2:0], wbuf[k]);
				bit_i  <= 3'd0;
				byte_i <= 3'd0;
				pos    <= 6'd0;
				active <= 1'b0;
			end

			// ---- clock rising edge ----
			if (rise) begin
				if (!active) begin
					sh <= in_byte;
					if (bit_i == 3'd7) begin
						// the command byte is complete
						active  <= 1'b1;
						cmd     <= cmd_now;
						is_read <= in_byte[7];
						snap    <= pack_now;
						data_in <= 1'b0;
						pos     <= 6'd0;
						bit_i   <= 3'd0;
						byte_i  <= 3'd0;
					end else
						bit_i <= bit_i + 3'd1;
				end else if (is_read) begin
					// counters only: the data line moves on the falling edge
					if (bit_i == 3'd7) begin
						bit_i  <= 3'd0;
						byte_i <= byte_i + 3'd1;
					end else
						bit_i <= bit_i + 3'd1;
				end else begin
					sh <= in_byte;
					if (bit_i == 3'd7) begin
						wbuf[byte_i] <= in_byte;
						byte_i <= byte_i + 3'd1;
						bit_i  <= 3'd0;
					end else
						bit_i <= bit_i + 3'd1;
				end
			end

			// ---- clock falling edge: present the next output bit ----
			if (fall && active && is_read) begin
				data_in <= snap[pos];
				if (pos < 6'd63)
					pos <= pos + 6'd1;
			end

			// ---- one-second tick: the BCD counters ----
			// Last in the block on purpose: a parameter write committed in the
			// same cycle as a tick is overwritten by the tick, which is what
			// the hardware does (the counters keep running while the port is
			// being bit-banged) and, unlike the old split blocks, it is the
			// same answer every time.
			if (sec_tick) begin
				if (sec == 8'h59) begin
					sec <= 8'h00;
					if (min == 8'h59) begin
						min <= 8'h00;
						if (hr == 8'h23) begin
							hr  <= 8'h00;
							dow <= (dow == 3'd6) ? 3'd0 : (dow + 3'd1);
							if (day == dim) begin
								day <= 8'h01;
								if (mon == 8'h12) begin
									mon <= 8'h01;
									yr  <= bcd_inc(yr);
								end else
									mon <= bcd_inc(mon);
							end else
								day <= bcd_inc(day);
						end else
							hr <= bcd_inc(hr);
					end else
						min <= bcd_inc(min);
				end else
					sec <= bcd_inc(sec);
			end
		end
	end

	//------------------------------------------------------------------
	// port read
	//------------------------------------------------------------------
	always @(*) begin
		rdata    = 16'd0;
		rdata[0] = data_dir ? data_wr : data_in;
		rdata[1] = sck;
		rdata[2] = cs;
		rdata[4] = data_dir;
	end

	// nothing here raises /INT today
	assign irq = 1'b0;

endmodule
