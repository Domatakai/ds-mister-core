//============================================================================
// NDS MiSTer Test — FLASH save data path
//
// Drives the emulated 45PE40V6/45PE80V6 at the byte level and checks the M4
// data path: a blank part reads FFh, a page program reads back, the 256-byte
// page wraps a write that crosses its end, an erase without WREN does nothing,
// a 4 KB sector erase clears its own sector and leaves the next one alone, a
// chip erase clears the whole backed window, and an address above the 64 KB
// backed window reads FFh and drops what is programmed there.
//
//   iverilog -g2012 -o /tmp/tb_flash tb/tb_flash_save.sv rtl/cart/save_spi.sv
//   vvp /tmp/tb_flash
//============================================================================
`timescale 1ns / 1ps

module tb_flash_save;

reg clk = 0;
always #10 clk = ~clk;

reg        reset = 1;
reg  [2:0] cfg = 3'd3;          // FLASH 512K (45PE40V6)

wire        resp, present;
wire [7:0]  dout, chip_status;
reg         cs_n = 1;
reg         slot = 0;
reg  [7:0]  din = 8'h00;

save_spi u_chip (
	.clk(clk), .reset(reset), .cfg(cfg),
	.cs_n(cs_n), .din(din), .slot(slot),
	.dout(dout), .resp(resp),
	.status_o(chip_status), .present(present)
);

integer errors = 0;
task check;
	input [8*52:1] name;
	input          cond;
	begin
		if (!cond) begin
			$display("FAIL %0s", name);
			errors = errors + 1;
		end else
			$display("ok   %0s", name);
	end
endtask

//------------------------------------------------------------------
// byte-level driver, the same framing tb_save_probe uses
//------------------------------------------------------------------
reg [7:0] r0;

task xfer;
	input  [7:0] b;
	output [7:0] r;
	integer guard;
	begin
		@(negedge clk);
		din  = b;
		slot = 1;
		@(negedge clk);
		slot = 0;
		guard = 0;
		while (!resp && guard < 16) begin
			@(negedge clk);
			guard = guard + 1;
		end
		r = dout;
		@(negedge clk);
	end
endtask

task beg_txn;
	begin
		@(negedge clk);
		cs_n = 0;
		@(negedge clk);
	end
endtask

task end_txn;
	begin
		@(negedge clk);
		cs_n = 1;
		repeat (3) @(negedge clk);
	end
endtask

task addr24;
	input [23:0] a;
	begin
		xfer(a[23:16], r0);
		xfer(a[15:8],  r0);
		xfer(a[7:0],   r0);
	end
endtask

task wren;
	begin
		beg_txn;
		xfer(8'h06, r0);
		end_txn;
	end
endtask

task wait_ready;
	integer guard;
	begin
		guard = 0;
		while (chip_status[0] && guard < 200000) begin
			@(negedge clk);
			guard = guard + 1;
		end
	end
endtask

task program2;
	input [23:0] a;
	input [7:0]  b0;
	input [7:0]  b1;
	begin
		wren;
		beg_txn;
		xfer(8'h02, r0);
		addr24(a);
		xfer(b0, r0);
		xfer(b1, r0);
		end_txn;
		wait_ready;
	end
endtask

task program1;
	input [23:0] a;
	input [7:0]  b;
	begin
		program2(a, b, 8'hFF);
		// the second byte went to the next address; rewrite it below where
		// it matters, so callers that care program a pair instead
	end
endtask

task rd1;
	input  [23:0] a;
	output [7:0]  d;
	begin
		beg_txn;
		xfer(8'h03, r0);
		addr24(a);
		xfer(8'h00, d);
		end_txn;
	end
endtask

task rd2;
	input  [23:0] a;
	output [7:0]  d0;
	output [7:0]  d1;
	begin
		beg_txn;
		xfer(8'h03, r0);
		addr24(a);
		xfer(8'h00, d0);
		xfer(8'h00, d1);
		end_txn;
	end
endtask

task erase_range;
	input [7:0]  cmd;
	input [23:0] a;
	begin
		beg_txn;
		xfer(cmd, r0);
		if (cmd != 8'hC7 && cmd != 8'h60) addr24(a);
		end_txn;
		wait_ready;
	end
endtask

reg [7:0] d0, d1, s;

initial begin
	reset = 1;
	repeat (3) @(negedge clk);
	reset = 0;
	repeat (3) @(negedge clk);

	// ---------------------------------------------------------- blank part
	rd1(24'h000010, d0);
	check("FLASH: a blank part reads FFh", d0 === 8'hFF);

	// ---------------------------------------------------------- page program
	program2(24'h000100, 8'hA5, 8'h5A);
	rd2(24'h000100, d0, d1);
	check("FLASH: a programmed page reads back", d0 === 8'hA5 && d1 === 8'h5A);

	// ---------------------------------------------------------- page wrap
	// two bytes at 1FFh: the second must wrap inside the 256-byte page to 100h
	program2(24'h0001FF, 8'h11, 8'h22);
	rd1(24'h0001FF, d0);
	rd1(24'h000100, d1);
	check("FLASH: page program wraps inside its 256-byte page",
	      d0 === 8'h11 && d1 === 8'h22);

	// ---------------------------------------------------------- erase needs WREN
	erase_range(8'h20, 24'h000100);        // no WREN first: must do nothing
	rd1(24'h0001FF, d0);
	check("FLASH: an erase without WREN is ignored", d0 === 8'h11);

	// ---------------------------------------------------------- sector erase
	// a byte in the next sector must survive a 4 KB erase of this one
	program2(24'h002000, 8'h7E, 8'hFF);
	wren;
	erase_range(8'h20, 24'h000100);
	rd1(24'h000100, d0);
	rd1(24'h0001FF, d1);
	check("FLASH: 4 KB sector erase clears its sector", d0 === 8'hFF && d1 === 8'hFF);
	rd1(24'h002000, d0);
	check("FLASH: sector erase leaves the next sector alone", d0 === 8'h7E);
	check("FLASH: WIP clears when the erase finishes", chip_status[0] === 1'b0);

	// ---------------------------------------------------------- chip erase
	wren;
	erase_range(8'hC7, 24'h000000);
	rd1(24'h002000, d0);
	check("FLASH: chip erase clears the whole window", d0 === 8'hFF);
	check("FLASH: WIP clears after the chip erase", chip_status[0] === 1'b0);

	// ---------------------------------------------------------- above 64 KB
	wren;
	beg_txn;
	xfer(8'h02, r0);
	addr24(24'h020000);
	xfer(8'h3C, r0);
	end_txn;
	wait_ready;
	rd1(24'h020000, d0);
	check("FLASH: above 64 KB a program is dropped, reads FFh",
	      d0 === 8'hFF);

	// and the identity still answers, so the probe is unaffected
	beg_txn;
	// RDID has no address phase: the first byte after the command is data
	xfer(8'h9F, r0);
	xfer(8'h00, d0);
	xfer(8'h00, d1);
	xfer(8'h00, s);
	end_txn;
	check("FLASH: identity still reads 20 20 13", d0 === 8'h20 && d1 === 8'h20 && s === 8'h13);

	if (errors == 0) $display("TB FLASH SAVE PASS");
	else             $display("TB FLASH SAVE FAIL (%0d errors)", errors);
	$finish;
end

endmodule
