//============================================================================
// NDS MiSTer Test — nds_spi bench
//
// Drives SPICNT/SPIDATA the way the ARM7 does: select a device, write a byte,
// poll the busy bit, read the received byte. Checks the three devices GBATEK
// puts on the bus — the HLE firmware flash (ID, status, the synthesised user
// settings with their CRC, the OSD language row and the CRC that follows
// it, program/erase through the shadow RAM), the touchscreen (X, Y,
// released, microphone) and the power management device.
//============================================================================
`timescale 1ns/1ps

module tb_spi;

	reg        clk = 0;
	reg        reset = 1;
	reg        acc = 0, we = 0;
	reg [15:0] addr = 0, wdata = 0;
	wire [15:0] rdata;
	reg [8:0]  touch_x = 9'd0;
	reg [7:0]  touch_y = 8'd0;
	reg        touch_down = 0;
	reg [11:0] mic_in = 12'h400;
	reg [2:0]  lang = 3'd0;
	wire       irq;
	integer    li;
	reg [7:0]  seq [0:255];      // a continuous-read burst from the flash

	always #10 clk = !clk;

	nds_spi dut (
		.clk(clk), .reset(reset),
		.acc(acc), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata),
		.touch_x(touch_x), .touch_y(touch_y), .touch_down(touch_down),
		.mic_in(mic_in), .lang(lang), .irq(irq)
	);

	// the language code the OSD row asks for: menu order, so English is 0
	function [7:0] exp_lang(input integer i);
		case (i)
		0: exp_lang = 8'h01;   // English
		1: exp_lang = 8'h00;   // Japanese
		2: exp_lang = 8'h02;   // French
		3: exp_lang = 8'h03;   // German
		4: exp_lang = 8'h04;   // Italian
		default: exp_lang = 8'h05;   // Spanish
		endcase
	endfunction

	// CRC16-CCITT over the first n bytes of a `fw_seq` burst, as GBATEK
	// specifies it for the user-settings block
	function [15:0] crc16(input integer n);
		integer i, b;
		reg [15:0] c;
		begin
			c = 16'hFFFF;
			for (i = 0; i < n; i = i + 1) begin
				c = c ^ ({8'd0, seq[i]} << 8);
				for (b = 0; b < 8; b = b + 1)
					c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
			end
			crc16 = c;
		end
	endfunction

	integer errors = 0;
	task check;
		input [1023:0] name;
		input          ok;
		begin
			if (ok) $display("ok   %0s", name);
			else begin $display("FAIL %0s", name); errors = errors + 1; end
		end
	endtask

	task wr16;
		input [15:0] a, d;
		begin
			@(negedge clk);
			addr = a; wdata = d; we = 1; acc = 1;
			@(negedge clk);
			we = 0; acc = 0;
			@(posedge clk); #1;
		end
	endtask

	task rd16;
		input  [15:0] a;
		output [15:0] d;
		begin
			@(negedge clk);
			addr = a; we = 0; acc = 1;
			#1 d = rdata;
			@(negedge clk);
			acc = 0;
			@(posedge clk); #1;
		end
	endtask

	// one byte on the bus, with the device already selected
	task xfer;
		input  [7:0] din;
		output [7:0] dout;
		reg [15:0] v;
		integer    guard;
		begin
			wr16(16'h01C2, {8'h00, din});
			guard = 0;
			rd16(16'h01C0, v);
			while (v[7] && guard < 64) begin
				rd16(16'h01C0, v);
				guard = guard + 1;
			end
			rd16(16'h01C2, v);
			dout = v[7:0];
		end
	endtask

	task select_dev;
		input [1:0] d;
		begin
			// bit 15 enable, bit 11 chipselect hold, bits 9-8 device select
			wr16(16'h01C0, 16'h8800 | ({14'd0, d} << 8));
			wr16(16'h01C0, 16'h8800 | ({14'd0, d} << 8));
		end
	endtask

	reg [7:0] rx;

	// release the chip select and start a fresh command on the firmware
	task fw_reset;
		begin
			wr16(16'h01C0, 16'h8000);        // hold cleared: deselect
			select_dev(2'd1);
		end
	endtask
	reg [7:0] b0, b1, b2, b3;

	// one READ command, then n bytes straight off the part (the pointer
	// walks by itself, which is what a burst read is)
	task fw_seq;
		input [17:0] a;
		input integer n;
		integer i;
		begin
			fw_reset;
			xfer(8'h03, rx);
			xfer({6'd0, a[17:16]}, rx);
			xfer(a[15:8], rx);
			xfer(a[7:0], rx);
			for (i = 0; i < n; i = i + 1) xfer(8'h00, seq[i]);
		end
	endtask

	// send a command plus address bytes to the firmware, then read n data bytes
	task fw_read;
		input [17:0] a;
		input integer n;
		integer i;
		begin
			fw_reset;
			xfer(8'h03, rx);
			xfer({6'd0, a[17:16]}, rx);
			xfer(a[15:8], rx);
			xfer(a[7:0], rx);
			for (i = 0; i < n; i = i + 1) begin
				xfer(8'h00, rx);
				$display("   fw[%h] = %h", a + i, rx);
				if (i == 0) b0 = rx;
				if (i == 1) b1 = rx;
			end
		end
	endtask

	initial begin
		repeat (4) @(posedge clk);
		reset = 0;
		repeat (2) @(posedge clk);

		//=============================================================
		// 1. SPICNT readback and the busy bit
		//=============================================================
		fw_reset;
		begin : cnt_probe
			reg [15:0] cw;
			rd16(16'h01C0, cw);
			check("SPICNT reads back enable and device select",
			      cw[15] === 1'b1 && cw[9:8] === 2'd1);
			check("and is idle before a transfer", cw[7] === 1'b0);
		end

		fw_busy_probe : begin
			reg [15:0] v;
			integer n;
			wr16(16'h01C2, 16'h009F);
			rd16(16'h01C0, v);
			check("a transfer sets SPICNT busy", v[7] === 1'b1);
			n = 0;
			while (v[7] && n < 64) begin
				rd16(16'h01C0, v);
				n = n + 1;
			end
			check("busy clears when the byte is through", v[7] === 1'b0 && n <= 16);
		end

		//=============================================================
		// 2. firmware identification and status
		//=============================================================
		fw_reset;                        // the probe left the part in its ID stream
		xfer(8'h9F, rx);
		xfer(8'h00, b0);
		xfer(8'h00, b1);
		xfer(8'h00, b2);
		check("RDID returns the ST M45PE20 id", b0 === 8'h20 && b1 === 8'h40 && b2 === 8'h12);

		fw_reset;
		xfer(8'h05, rx);
		xfer(8'h00, b0);
		check("RDSR reads idle, write-protected latch clear", b0 === 8'h00);

		fw_reset;
		xfer(8'h06, rx);                 // WREN
		fw_reset;
		xfer(8'h05, rx);
		xfer(8'h00, b0);
		check("WREN sets the write-enable latch", b0[1] === 1'b1);

		//=============================================================
		// 3. the HLE user settings
		//=============================================================
		fw_reset;
		fw_read(18'h3FE00, 2);
		check("user settings block 0 reports version 5", b0 === 8'h05);

		fw_reset;
		xfer(8'h03, rx); xfer(8'h03, rx); xfer(8'hFE, rx); xfer(8'h64, rx);
		xfer(8'h00, b0); xfer(8'h00, b1);
		$display("   lang = %h %h", b0, b1);
		check("the language field is English with settings marked valid",
		      b0 === 8'h01 && b1 === 8'hEC);

		// every OSD language choice must land in the block *and* keep the
		// CRC16-CCITT that protects it valid, in both settings copies
		for (li = 0; li < 6; li = li + 1) begin
			lang = li[2:0];
			repeat (2) @(posedge clk);

			fw_seq(18'h3FE00, 116);
			check("the OSD language reaches the settings block",
			      seq[8'h64] === exp_lang(li) && seq[8'h65] === 8'hEC);
			check("and the CRC over 0x00..0x6F follows it",
			      {seq[8'h73], seq[8'h72]} === crc16(8'h70));

			fw_seq(18'h3FF00, 116);
			check("the second settings copy carries the same pair",
			      seq[8'h64] === exp_lang(li) &&
			      {seq[8'h73], seq[8'h72]} === crc16(8'h70));
		end

		lang = 3'd0;
		repeat (2) @(posedge clk);
		fw_seq(18'h3FE00, 116);
		check("back to English, unchanged",
		      seq[8'h64] === 8'h01 && {seq[8'h73], seq[8'h72]} === crc16(8'h70));

		fw_reset;
		xfer(8'h03, rx); xfer(8'h03, rx); xfer(8'hFE, rx); xfer(8'h06, rx);
		xfer(8'h00, b0); xfer(8'h00, b1);
		check("the nickname reads back as NDS",
		      b0 === 8'h4E && b1 === 8'h00);

		fw_reset;
		xfer(8'h03, rx); xfer(8'h03, rx); xfer(8'hFE, rx); xfer(8'h58, rx);
		xfer(8'h00, b0); xfer(8'h00, b1);
		$display("   calib = %h %h", b0, b1);
		check("the touch calibration matches the TSC model", b0 === 8'h0E && b1 === 8'h01);

		// beyond the modelled window the part looks erased
		fw_reset;
		xfer(8'h03, rx); xfer(8'h00, rx); xfer(8'h00, rx); xfer(8'h10, rx);
		xfer(8'h00, b0);
		check("reads outside the settings window are erased", b0 === 8'hFF);

		//=============================================================
		// 4. erase and program through the shadow RAM
		//=============================================================
		// A flash page must be erased before anything can be programmed into
		// it: programming only clears bits, so 5Ah into a 00h byte stays 00h
		// (which is what the real part does).
		fw_reset;
		xfer(8'h06, rx);                       // WREN
		xfer(8'hDB, rx);                       // page erase
		xfer(8'h03, rx); xfer(8'hFE, rx); xfer(8'h00, rx);
		fw_reset;
		fw_read(18'h3FE10, 1);
		check("a page erase clears the block", b0 === 8'hFF);
		fw_reset;
		fw_read(18'h3FE64, 1);
		check("the erase cleared the settings block", b0 === 8'hFF);

		fw_reset;
		xfer(8'h05, rx);                       // the erase cleared it
		xfer(8'h00, b0);
		check("erasing cleared the write-enable latch", b0[1] === 1'b0);

		fw_reset;
		xfer(8'h06, rx);                       // WREN
		xfer(8'h02, rx);                       // page program
		xfer(8'h03, rx); xfer(8'hFE, rx); xfer(8'h10, rx);
		xfer(8'h5A, rx);
		fw_reset;
		fw_read(18'h3FE10, 1);
		check("a programmed byte reads back", b0 === 8'h5A);

		fw_reset;
		xfer(8'h05, rx);
		xfer(8'h00, b0);
		check("programming held the busy bit until it finished", b0[0] === 1'b0);
		check("and cleared the write-enable latch", b0[1] === 1'b0);

		// programming cannot set a bit that has already been cleared
		fw_reset;
		xfer(8'h06, rx);
		xfer(8'h02, rx);
		xfer(8'h03, rx); xfer(8'hFE, rx); xfer(8'h10, rx);
		xfer(8'hFF, rx);
		fw_reset;
		fw_read(18'h3FE10, 1);
		check("programming only clears bits", b0 === 8'h5A);

		//=============================================================
		// 5. touchscreen
		//=============================================================
		touch_down = 1'b1;
		touch_x = 9'd100;
		touch_y = 8'd50;
		repeat (2) @(posedge clk);

		select_dev(2'd2);
		xfer(8'h95, rx);                       // Y: start|001|0|1|01, 12-bit, single-ended
		xfer(8'h00, b0);
		xfer(8'h00, b1);
		check("the touchscreen reports the stylus Y position",
		      ((({b0[6:0], b1[7:3]}) === 12'h3BC)));

		select_dev(2'd2);
		xfer(8'hD5, rx);                       // X, 12-bit, single-ended
		xfer(8'h00, b0);
		xfer(8'h00, b1);
		check("and the X position", ((({b0[6:0], b1[7:3]}) === 12'h678)));
		check("the reply begins with the dummy zero bit", b0[7] === 1'b0);

		wr16(16'h01C0, 16'h8000);            // release between command sequences
		select_dev(2'd2);
		touch_down = 1'b0;
		repeat (2) @(posedge clk);
		select_dev(2'd2);
		xfer(8'hD5, rx);
		xfer(8'h00, b0); xfer(8'h00, b1);
		check("a released panel reads 000h for X", ({b0[6:0], b1[7:3]}) === 12'h000);
		select_dev(2'd2);
		xfer(8'h95, rx);
		xfer(8'h00, b0); xfer(8'h00, b1);
		check("and FFFh for Y", ({b0[6:0], b1[7:3]}) === 12'hFFF);

		mic_in = 12'hC00;
		repeat (2) @(posedge clk);
		select_dev(2'd2);
		xfer(8'hE5, rx);                       // AUX / microphone
		xfer(8'h00, b0); xfer(8'h00, b1);
		check("the microphone channel follows its input",
		      ({b0[6:0], b1[7:3]}) === 12'hC00);
		mic_in = 12'h123;
		repeat (2) @(posedge clk);
		select_dev(2'd2);
		xfer(8'hE5, rx);
		xfer(8'h00, b0); xfer(8'h00, b1);
		check("and carries the whole 12-bit level",
		      ({b0[6:0], b1[7:3]}) === 12'h123);
		mic_in = 12'h400;

		//=============================================================
		// 6. power management
		//=============================================================
		wr16(16'h01C0, 16'h8000);
		select_dev(2'd0);
		xfer(8'h80, rx);                       // index 0, read
		xfer(8'h00, b0);
		check("powerman register 0 has both backlights on", b0[3:2] === 2'b11);

		select_dev(2'd0);
		xfer(8'h80, rx);
		xfer(8'h00, b0);
		check("and the sound amplifier enabled", b0[0] === 1'b1);

		wr16(16'h01C0, 16'h8000);
		select_dev(2'd0);
		xfer(8'h81, rx);                       // index 1, read: battery
		xfer(8'h00, b0);
		check("the battery reads good", b0[0] === 1'b0);

		wr16(16'h01C0, 16'h8000);
		select_dev(2'd0);
		xfer(8'h02, rx);                       // index 2, write: microphone amp
		xfer(8'h01, rx);
		wr16(16'h01C0, 16'h8000);
		select_dev(2'd0);
		xfer(8'h82, rx);
		xfer(8'h00, b0);
		check("a powerman write round-trips", b0[0] === 1'b1);

		//=============================================================
		// 7. transfer IRQ
		//=============================================================
		wr16(16'h01C0, 16'hC000);             // enable + IRQ enable, device 0
		begin : irq_probe
			integer seen;
			seen = 0;
			wr16(16'h01C2, 16'h0080);
			repeat (12) begin
				@(posedge clk); #1;
				if (irq) seen = 1;
			end
			check("SPICNT.14 raises the SPI interrupt", seen === 1'b1);
		end

		if (errors == 0) $display("TB SPI PASS");
		else             $display("TB SPI FAIL (%0d errors)", errors);
		$finish;
	end

endmodule
