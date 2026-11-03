//============================================================================
// NDS MiSTer Test — cartridge save file (load)
//
// Drives save_file the way the HPS does, with the real save_spi behind it:
//
//   load   a download whose ioctl_file_ext is ".sav" writes both bytes of
//          every word into the chip's RAM, in order
//   ignore a download with any other extension writes nothing at all
//   ceiling a .sav longer than the chip's 64 KB is dropped past the window,
//          not folded back onto the bytes already loaded
//
//   iverilog -g2012 -o /tmp/tb_savefile tb/tb_save_file.sv \
//            rtl/cart/save_file.sv rtl/cart/save_spi.sv
//   vvp /tmp/tb_savefile
//============================================================================
`timescale 1ns / 1ps

module tb_save_file;

reg clk = 0;
always #10 clk = ~clk;

reg reset = 1;

// save_file side of the HPS pipe
reg         ioctl_download = 0;
reg  [26:0] ioctl_addr = 0;
reg  [15:0] ioctl_dout = 0;
reg         ioctl_wr = 0;
reg  [31:0] ioctl_file_ext = 32'hFFFF_FFFF;

wire        ld_we;
wire [15:0] ld_addr;
wire  [7:0] ld_byte;
wire        chip_wrote;

// chip side
reg  [2:0] cfg = 3'd1;          // EEPROM 512K (M95512): 16-bit addresses, 64 KB
reg        cs_n = 1, slot = 0;
reg  [7:0] din = 8'h00;
wire [7:0] dout, chip_status;
wire       resp, present;

save_spi u_chip (
	.clk(clk), .reset(reset), .cfg(cfg),
	.cs_n(cs_n), .din(din), .slot(slot),
	.dout(dout), .resp(resp),
	.status_o(chip_status), .present(present),
	.ld_we(ld_we), .ld_addr(ld_addr), .ld_byte(ld_byte),
	.wrote(chip_wrote)
);

save_file u_file (
	.clk(clk), .reset(reset),
	.ioctl_download(ioctl_download), .ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout), .ioctl_wr(ioctl_wr),
	.ioctl_file_ext(ioctl_file_ext),
	.ld_we(ld_we), .ld_addr(ld_addr), .ld_byte(ld_byte)
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
// SPI byte driver, the same framing the other save benches use
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

task rd1;
	input  [15:0] a;
	output [7:0]  d;
	begin
		beg_txn;
		xfer(8'h03, r0);
		xfer(a[15:8], r0);
		xfer(a[7:0],  r0);
		xfer(8'h00, d);
		end_txn;
	end
endtask

// one download word: the HPS presents it with ioctl_wr for a cycle
task word;
	input [26:0] a;
	input [15:0] d;
	begin
		@(negedge clk);
		ioctl_addr = a;
		ioctl_dout = d;
		ioctl_wr   = 1;
		@(negedge clk);
		ioctl_wr   = 0;
		repeat (2) @(negedge clk);
	end
endtask

reg [7:0] b0, b1, b2, b3;

initial begin
	reset = 1;
	repeat (3) @(negedge clk);
	reset = 0;
	repeat (3) @(negedge clk);

	// ---------------------------------------------------------- .sav load
	ioctl_file_ext = 32'h2E73_6176;      // ".sav"
	ioctl_download = 1;
	word(27'd0, 16'h2211);
	word(27'd2, 16'h4433);
	@(negedge clk);
	ioctl_download = 0;
	repeat (4) @(negedge clk);

	rd1(16'h0000, b0);
	rd1(16'h0001, b1);
	rd1(16'h0002, b2);
	rd1(16'h0003, b3);
	check("SAVE FILE: a .sav load lands in the chip",
	      b0 === 8'h11 && b1 === 8'h22 && b2 === 8'h33 && b3 === 8'h44);

	// ---------------------------------------------------------- other files
	ioctl_file_ext = 32'h2E6E_6473;      // ".nds"
	ioctl_download = 1;
	word(27'h10, 16'hAAAA);
	@(negedge clk);
	ioctl_download = 0;
	repeat (4) @(negedge clk);
	rd1(16'h0010, b0);
	check("SAVE FILE: a download that is not .sav is ignored", b0 === 8'hFF);

	// ---------------------------------------------------------- 64 KB ceiling
	// a 512 KB save must not fold its tail back onto the bytes already loaded
	ioctl_file_ext = 32'h2E73_6176;      // ".sav" again
	ioctl_download = 1;
	word(27'h10000, 16'hDEAD);
	@(negedge clk);
	ioctl_download = 0;
	repeat (4) @(negedge clk);
	rd1(16'h0000, b0);
	rd1(16'h0001, b1);
	check("SAVE FILE: a .sav past 64 KB is dropped, not wrapped",
	      b0 === 8'h11 && b1 === 8'h22);

	if (errors == 0) $display("TB SAVE FILE PASS");
	else             $display("TB SAVE FILE FAIL (%0d errors)", errors);
	$finish;
end

endmodule
