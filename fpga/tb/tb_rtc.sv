//============================================================================
// NDS MiSTer Test — nds_rtc bench
//
// Drives the three-wire port exactly as the ARM7 firmware does: write
// 4000138h to move chip select, clock and data, and read bit 0 back after
// raising the clock. Checks the reset date, the 1 Hz counters and their BCD
// rollover, the 12/24-hour readback, the write-then-readback path for the free
// register, the date/time write path, and that a read snapshots the date.
//============================================================================
`timescale 1ns/1ps

module tb_rtc;

	reg        clk = 0;
	reg        reset = 1;
	reg        sec_tick = 0;
	reg        wr = 0;
	reg [15:0] wdata = 0;
	wire [15:0] rdata;
	wire        irq;

	always #10 clk = !clk;

	nds_rtc dut (
		.clk(clk), .reset(reset), .sec_tick(sec_tick),
		.wr(wr), .wdata(wdata), .rdata(rdata), .irq(irq)
	);

	integer errors = 0;
	task check;
		input [1023:0] name;
		input          ok;
		begin
			if (ok) $display("ok   %0s", name);
			else begin $display("FAIL %0s", name); errors = errors + 1; end
		end
	endtask

	// ---- one port write ----
	task port_wr;
		input [15:0] v;
		begin
			@(posedge clk); #1;
			wdata = v; wr = 1;
			@(posedge clk); #1;
			wr = 0;
			$display("   port <= %h (rdata %h)", v, rdata);
		end
	endtask

	// port bit helpers: data = bit0, clock = bit1, select = bit2, dir = bit4
	function [15:0] pv(input data, input sck, input sel, input dir);
		begin
			pv     = 16'd0;
			pv[0]  = data;
			pv[1]  = sck;
			pv[2]  = sel;
			pv[4]  = dir;
		end
	endfunction

	// drive one bit into the device (LSB-first transfers)
	task tx_bit;
		input b;
		begin
			port_wr(pv(b, 1'b0, 1'b1, 1'b1));   // data, clock low
			port_wr(pv(b, 1'b1, 1'b1, 1'b1));   // clock high: device latches
			port_wr(pv(b, 1'b0, 1'b1, 1'b1));   // clock low again
		end
	endtask

	// read one bit: raise the clock, sample bit 0
	task rx_bit;
		output b;
		begin
			port_wr(pv(1'b0, 1'b1, 1'b1, 1'b0));
			b = rdata[0];
			port_wr(pv(1'b0, 1'b0, 1'b1, 1'b0));
		end
	endtask

	task tx_byte;
		input [7:0] b;
		integer i;
		begin
			for (i = 0; i < 8; i = i + 1) tx_bit(b[i]);
		end
	endtask

	task rx_byte;
		output [7:0] b;
		integer i;
		reg bit_v;
		begin
			b = 8'h00;
			for (i = 0; i < 8; i = i + 1) begin
				rx_bit(bit_v);
				b[i] = bit_v;
			end
		end
	endtask

	task cs_up;
		begin
			port_wr(pv(1'b0, 1'b0, 1'b1, 1'b1));
		end
	endtask

	task cs_down;
		begin
			port_wr(pv(1'b0, 1'b0, 1'b0, 1'b1));
			port_wr(pv(1'b0, 1'b0, 1'b0, 1'b1));
		end
	endtask

	// start a command: chip select up, command byte, then parameters
	task cmd_start;
		input [2:0] c;
		input       rd;
		begin
			cs_down;
			cs_up;
			tx_byte({rd, c[2:0], 1'b0, 1'b1, 1'b1, 1'b0});
		end
	endtask

	reg [7:0] b0, b1, b2, b3, b4, b5, b6;

	// read a command's parameter bytes
	task read_params;
		input [2:0] c;
		begin
			cmd_start(c, 1'b1);
			rx_byte(b0);
			rx_byte(b1);
			rx_byte(b2);
			rx_byte(b3);
			rx_byte(b4);
			rx_byte(b5);
			rx_byte(b6);
			cs_down;
			$display("   cmd %0d -> %h %h %h %h %h %h %h", c, b0, b1, b2, b3, b4, b5, b6);
		end
	endtask

	task write_params;
		input [2:0] c;
		input [7:0] v0, v1, v2, v3, v4, v5, v6;
		input integer n;
		begin
			cmd_start(c, 1'b0);
			if (n > 0) tx_byte(v0);
			if (n > 1) tx_byte(v1);
			if (n > 2) tx_byte(v2);
			if (n > 3) tx_byte(v3);
			if (n > 4) tx_byte(v4);
			if (n > 5) tx_byte(v5);
			if (n > 6) tx_byte(v6);
			cs_down;
		end
	endtask

	task tick;
		input integer n;
		integer i;
		begin
			for (i = 0; i < n; i = i + 1) begin
				@(posedge clk); #1; sec_tick = 1;
				@(posedge clk); #1; sec_tick = 0;
			end
			repeat (2) @(posedge clk); #1;
		end
	endtask

	initial begin
		repeat (4) @(posedge clk);
		reset = 0;
		repeat (2) @(posedge clk);

		// ---- 1. reset state ----
		read_params(3'd0);
		check("status 1 reports 24-hour mode", b0[1] === 1'b1);
		check("status 1 has no power-off flag", b0[7] === 1'b0);
		check("and no interrupt flags", b0[5:4] === 2'b00);

		read_params(3'd2);
		check("reset date is 2026-10-26", b0 === 8'h26 && b1 === 8'h10 && b2 === 8'h26);
		check("reset time is 12:00:00", b4 === 8'h12 && b5 === 8'h00 && b6 === 8'h00);
		check("day of week is in range", b3[2:0] <= 3'd6);

		// ---- 2. the counters ----
		tick(61);
		read_params(3'd3);
		check("61 seconds advances to 12:01:01", b0 === 8'h12 && b1 === 8'h01 && b2 === 8'h01);

		tick(59 * 60);
		read_params(3'd3);
		check("59 more minutes advances the hour", b0 === 8'h13 && b1 === 8'h00 && b2 === 8'h01);

		// ---- 3. write then read back: free register and a full date ----
		write_params(3'd7, 8'h5A, 0, 0, 0, 0, 0, 0, 1);
		read_params(3'd7);
		check("free register round-trips", b0 === 8'h5A);

		// 2026-10-31 23:59:59, then one tick must roll into November
		write_params(3'd2, 8'h26, 8'h10, 8'h31, 8'h05, 8'h23, 8'h59, 8'h59, 7);
		read_params(3'd2);
		check("a written date reads back", b0 === 8'h26 && b1 === 8'h10 && b2 === 8'h31);
		check("a written time reads back", b4 === 8'h23 && b5 === 8'h59 && b6 === 8'h59);

		tick(1);
		read_params(3'd2);
		check("midnight rolls the day and month", b2 === 8'h01 && b1 === 8'h11 && b3 === 3'd6);
		check("midnight rolls the time to 00:00:00", b4 === 8'h00 && b5 === 8'h00 && b6 === 8'h00);

		// February in a leap year: 2028-02-28 23:59:59 -> 29th, then 01 March
		write_params(3'd2, 8'h28, 8'h02, 8'h28, 8'h01, 8'h23, 8'h59, 8'h59, 7);
		tick(1);
		read_params(3'd2);
		check("2028 is a leap year: February has 29 days", b2 === 8'h29 && b1 === 8'h02);
		tick(24 * 60 * 60);
		read_params(3'd2);
		check("the 29th rolls into March", b2 === 8'h01 && b1 === 8'h03);

		// ---- 4. 12-hour mode ----
		write_params(3'd3, 8'h14, 8'h30, 8'h00, 0, 0, 0, 0, 3);   // 14:30, still 24h
		write_params(3'd0, 8'h00, 0, 0, 0, 0, 0, 0, 1);          // clear bit 1: 12-hour
		read_params(3'd0);
		check("status 1 follows the hour-mode write", b0[1] === 1'b0);

		read_params(3'd3);
		check("12-hour mode reports 02h with PM", b0 === 8'h42 && b1 === 8'h30);
		write_params(3'd3, 8'h42, 8'h30, 8'h00, 0, 0, 0, 0, 3);   // 02h PM
		write_params(3'd0, 8'h02, 0, 0, 0, 0, 0, 0, 1);           // back to 24-hour
		read_params(3'd3);
		check("02h PM writes back as 14h in 24-hour mode", b0 === 8'h14 && b1 === 8'h30);

		// ---- 5. a read snapshots the date ----
		write_params(3'd3, 8'h00, 8'h00, 8'h00, 0, 0, 0, 0, 3);
		cmd_start(3'd2, 1'b1);
		rx_byte(b0);   // year
		rx_byte(b1);   // month
		rx_byte(b2);   // day
		rx_byte(b3);   // dow
		rx_byte(b4);   // hour
		tick(2);       // seconds roll over in the middle of the read
		rx_byte(b5);   // minute
		rx_byte(b6);   // second
		cs_down;
		check("a read keeps the snapshot across a rollover",
		      b5 === 8'h00 && b6 === 8'h00);

		check("nothing drives /INT", irq === 1'b0);

		if (errors == 0) $display("TB RTC PASS");
		else             $display("TB RTC FAIL (%0d errors)", errors);
		$finish;
	end

endmodule
