//============================================================================
// NDS MiSTer Test — cart slot testbench
//
//   iverilog -g2012 -o /tmp/tb_cart tb/tb_cart_slot.sv \
//            rtl/cart/cart_slot.sv && vvp /tmp/tb_cart
//
// Drives a simulated .nds download into the line FIFO, models the DDRAM
// handshake (including BUSY periods), then exercises the CPU window read
// bridge: pulse-style requests, data capture, and the pending latch that
// keeps a request alive across DDR busy. Checks 256 Mbit capacity
// detection (header byte 0x80 = 8 -> 128 KB << 8 = 32 MB).
//============================================================================
`timescale 1ns / 1ps

module tb_cart_slot;

reg clk = 0;
always #10 clk = ~clk; // 50 MHz

reg reset = 1;
reg ioctl_download = 0;
reg [26:0] ioctl_addr = 0;
reg [15:0] ioctl_dout = 0;
reg ioctl_wr = 0;
reg [15:0] ioctl_index = 1;

wire ioctl_wait;
wire [7:0] ddr_burstcnt;
wire [28:0] ddr_addr;
wire [63:0] ddr_din;
wire [7:0] ddr_be;
wire ddr_we, ddr_rd;
reg ddr_busy = 0;
reg ddr_dout_ready = 0;
reg [63:0] ddr_dout = 0;

reg win_req = 0;
reg [25:0] win_addr = 0;
wire win_valid;
wire [15:0] win_data;

reg erase_save = 0;
reg [2:0] save_type = 0;
wire save_req, save_wr;
wire [24:0] save_addr;
wire [15:0] save_din;
wire cart_loaded;
wire [27:0] rom_bytes;

cart_slot dut (
	.clk(clk), .reset(reset),
	.ioctl_download(ioctl_download), .ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout), .ioctl_wr(ioctl_wr),
	.ioctl_index(ioctl_index), .ioctl_wait(ioctl_wait),
	.ddr_burstcnt(ddr_burstcnt), .ddr_addr(ddr_addr), .ddr_din(ddr_din),
	.ddr_be(ddr_be), .ddr_we(ddr_we), .ddr_rd(ddr_rd),
	.ddr_busy(ddr_busy), .ddr_dout_ready(ddr_dout_ready), .ddr_dout(ddr_dout),
	.win_req(win_req), .win_addr(win_addr),
	.win_valid(win_valid), .win_data(win_data),
	.erase_save(erase_save), .save_type(save_type),
	.save_req(save_req), .save_wr(save_wr),
	.save_addr(save_addr), .save_din(save_din), .save_done(1'b0),
	.cart_loaded(cart_loaded), .rom_bytes(rom_bytes)
);

//------------------------------------------------------------------
// behavioral DDR3: accepts writes when !busy, returns lines on read
//------------------------------------------------------------------
reg [63:0] mem [0:255];
integer wr_beats = 0;
always @(posedge clk) begin
	if (ddr_we && !ddr_busy) begin
		mem[ddr_addr[7:0]] <= ddr_din;
		wr_beats = wr_beats + 1;
	end
	ddr_dout_ready <= 0;
	if (ddr_rd && !ddr_busy) begin
		ddr_dout <= mem[ddr_addr[7:0]];
		ddr_dout_ready <= 1;
	end
end

integer errors = 0;
task check;
	input [8*40:1] name;
	input cond;
	begin
		if (!cond) begin
			$display("FAIL %0s", name);
			errors = errors + 1;
		end else begin
			$display("ok   %0s", name);
		end
	end
endtask

task send_word;
	input [26:0] a;
	input [15:0] d;
	begin
		@(posedge clk);
		ioctl_addr <= a;
		ioctl_dout <= d;
		ioctl_wr   <= 1;
		@(posedge clk);
		ioctl_wr   <= 0;
	end
endtask

// one-cycle request pulse, then wait for the response
reg [15:0] got;
task win_read;
	input [25:0] a;
	begin
		@(posedge clk);
		win_addr <= a;
		win_req  <= 1;
		@(posedge clk);
		win_req  <= 0;
		wait (win_valid);
		got = win_data;
		@(posedge clk);
	end
endtask

integer i;
initial begin
	for (i = 0; i < 256; i = i + 1) mem[i] = 64'd0;

	repeat (5) @(posedge clk);
	reset = 0;
	repeat (2) @(posedge clk);

	// --- download 8 words = 2 lines: pattern 0x1000+k
	@(posedge clk); ioctl_download <= 1;
	for (i = 0; i < 8; i = i + 1) send_word(i * 2, 16'h1000 + i[15:0]);
	// capacity byte: header 0x80 lives at byte 0x80 (word index 0x40)
	send_word(27'h80, 16'h0008); // 128 KB << 8 = 32 MB = 256 Mbit
	@(posedge clk); ioctl_download <= 0;
	repeat (400) @(posedge clk);

	check("download -> 2 DDR lines", wr_beats == 2);
	check("line 0 packing {w3,w2,w1,w0}",
		mem[0] === {16'h1003, 16'h1002, 16'h1001, 16'h1000});
	check("line 1 packing {w7,w6,w5,w4}",
		mem[1] === {16'h1007, 16'h1006, 16'h1005, 16'h1004});
	check("cart loaded", cart_loaded === 1'b1);
	check("256 Mbit capacity detected", rom_bytes == 28'd33554432);

	// --- window read: byte 4 -> line0 halfword2 = 0x1002
	win_read(26'd4);
	check("window byte 4 -> 0x1002", got === 16'h1002);

	// --- window read: byte 8 -> line1 halfword0 = 0x1004
	repeat (4) @(posedge clk);
	win_read(26'd8);
	check("window byte 8 -> 0x1004", got === 16'h1004);

	// --- busy backpressure: request arrives while DDR is busy; the
	//     pending latch must carry it through and answer correctly.
	repeat (4) @(posedge clk);
	ddr_busy = 1;
	@(posedge clk);
	win_addr <= 26'd0;
	win_req  <= 1;
	@(posedge clk);
	win_req  <= 0;
	repeat (8) @(posedge clk);
	ddr_busy = 0;
	wait (win_valid);
	check("pending request survives DDR busy", win_data === 16'h1000);
	@(posedge clk);

	// --- save master stays idle until M4
	repeat (4) @(posedge clk);
	check("save master idle", save_req === 1'b0 && save_wr === 1'b0);

	if (errors == 0) $display("tb_cart_slot: PASS");
	else             $display("tb_cart_slot: FAIL (%0d errors)", errors);
	$finish;
end

initial begin
	#10_000_000;
	$display("tb_cart_slot: FAIL — timeout");
	$finish;
end

endmodule
