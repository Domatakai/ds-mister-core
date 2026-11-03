//============================================================================
// NDS MiSTer Test — cartridge save file (load from the HPS)
//
// The save chip (save_spi) holds the cart's backup memory, but it is not a
// file: this module takes the file the HPS downloads and writes it into that
// memory. hps_io defines the stream: ioctl_download with ioctl_wr, one 16-bit
// word per write in WIDE mode, ioctl_addr the byte address of the word's low
// byte.
//
// Which downloaded file is the save is not a constant to guess at: the HPS
// reports the file's own extension in ioctl_file_ext, so ".sav" is what this
// module looks for.
//
// The chip only backs the first 64 KB of a FLASH part (see save_spi), so a
// longer .sav loads its first 64 KB and the rest is dropped, which is the
// same documented truncation the chip itself applies.
//
// Writing the save back out is not implemented. It needs a second read port
// on the chip's memory, and that port costs more than the device has left:
// with it the fitter reports 83,984 combinational nodes against a limit of
// 83,820 (170011), and every attempt to share the one port instead either
// left the RAM uninferred (276007) or kept the duplicated RAM's pass-through
// logic anyway. So this build loads saves and does not save them; the write
// direction is the open item, not a hidden failure.
//============================================================================
module save_file (
	input             clk,
	input             reset,

	// HPS download stream (WIDE=1)
	input             ioctl_download,
	input      [26:0] ioctl_addr,
	input      [15:0] ioctl_dout,
	input             ioctl_wr,
	input      [31:0] ioctl_file_ext,

	// save memory write port
	output reg        ld_we,
	output reg [15:0] ld_addr,
	output reg [7:0]  ld_byte
);

	// ".sav" as two 16-bit halves: hps_io fills [31:16] with the extension's
	// first two characters and [15:0] with the next two. ORing 20h folds the
	// case of the three letters for free and leaves '.' alone.
	wire [15:0] e_hi = ioctl_file_ext[31:16] | 16'h2020;
	wire [15:0] e_lo = ioctl_file_ext[15:0]  | 16'h2020;
	wire is_sav = (e_hi == 16'h2E73 && e_lo == 16'h6176) ||
	              (e_hi == 16'h6176 && e_lo == 16'h2E73);
	wire dl     = ioctl_download && is_sav;

	// The chip is backed by 64 KB, so a longer file loads its first 64 KB.
	// Truncating the address here would fold the rest back onto the start and
	// overwrite what was already loaded, so the tail is dropped instead.
	wire in_win = (ioctl_addr[26:16] == 11'd0);

	// one word per ioctl_wr, written as two bytes: the low byte now, the high
	// byte from the queue on the next cycle
	reg        pend = 1'b0;
	reg [15:0] paddr = 16'd0;
	reg  [7:0] pbyte = 8'hFF;

	always @(posedge clk) begin
		ld_we <= 1'b0;

		if (reset) begin
			pend <= 1'b0;
		end else begin
			if (pend) begin
				ld_we   <= 1'b1;
				ld_addr <= paddr;
				ld_byte <= pbyte;
				pend    <= 1'b0;
			end

			if (dl && ioctl_wr && in_win) begin
				ld_we   <= 1'b1;
				ld_addr <= ioctl_addr[15:0];
				ld_byte <= ioctl_dout[7:0];
				pend    <= 1'b1;
				paddr   <= ioctl_addr[15:0] + 16'd1;
				pbyte   <= ioctl_dout[15:8];
			end
		end
	end

endmodule
