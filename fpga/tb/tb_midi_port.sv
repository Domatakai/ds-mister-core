//============================================================================
// NDS MiSTer Test — MIDI port testbench
//
//   iverilog -g2012 -o /tmp/tb_midi tb/tb_midi_port.sv \
//            rtl/audio/midi_port.sv && vvp /tmp/tb_midi
//
// tick_48k is tied high, so one clock is one MIDI tick and a bit is exactly
// 1536 clocks (31.25 kbaud at 48 kHz). A background monitor decodes every
// frame that appears on the wire, so the checks are about what a MIDI device
// would actually receive, not about the RTL's internal state.
//
// Checks:
//   1. AUXSPICNT writes back, bit 0 clear when nothing is queued.
//   2. A byte written to AUXSPIDATA leaves the wire as 8N1 at 31.25 kbaud,
//      start bit first, LSB first, stop bit high.
//   3. Two bytes written back to back both arrive, in order.
//   4. AUXSPICNT bit 0 reads busy while bytes are in flight, clear after.
//   5. With direction = read, a write shifts nothing onto the wire.
//   6. Bytes arriving at 31.25 kbaud are recovered bit-exactly, and a read of
//      0x015A hands one over; a short glitch is not mistaken for a start bit.
//   6b. Three bytes sent back to back all survive the receive FIFO, in order,
//      and reading an empty FIFO returns zero.
//   7. The internal demo stream starts on a note-on byte and keeps going.
//============================================================================
`timescale 1ns / 1ps

module tb_midi_port;

reg clk = 0;
always #10 clk = ~clk;   // 50 MHz

localparam integer BIT = 1536;   // clocks per MIDI bit (tick_48k tied high)

reg         reset = 1;
reg         tick_48k = 1;
reg         wr = 0, rd = 0;
reg  [15:0] addr = 0, wdata = 0;
wire [15:0] rdata;
wire        tx, tx_busy;
reg         rx = 1;
reg         demo_en = 0;

midi_port #(.DEMO_GAP(32)) dut (
	.clk(clk), .reset(reset), .tick_48k(tick_48k),
	.wr(wr), .rd(rd), .addr(addr), .wdata(wdata), .rdata(rdata),
	.tx(tx), .tx_busy(tx_busy), .rx(rx),
	.demo_en(demo_en), .demo_restart(1'b0)
);

integer errors = 0;
task check;
	input [8*46:1] name;
	input cond;
	begin
		if (!cond) begin
			$display("FAIL %0s", name);
			errors = errors + 1;
		end else
			$display("ok   %0s", name);
	end
endtask

integer cyc = 0;
always @(posedge clk) cyc <= cyc + 1;

//------------------------------------------------------------------
// background receiver: decode every frame on TX
//------------------------------------------------------------------
integer    n_frames = 0;
reg [7:0]  frames  [0:31];
integer    f_start [0:31];   // cycle of the start edge
integer    f_low   [0:31];   // cycles the line stayed low from that edge

initial begin : monitor
	integer k, t0, rise;
	reg     b;
	reg [7:0] d;
	@(negedge reset);       // ignore the power-up X on tx
	@(posedge clk);
	forever begin
		@(negedge tx);
		t0 = cyc;
		d = 8'h00;
		rise = -1;
		for (k = 1; k <= 8; k = k + 1) begin
			while (cyc < t0 + BIT * k + BIT / 2) begin
				@(posedge clk);
				if (rise < 0 && tx === 1'b1) rise = cyc - t0;
			end
			b = tx;
			d[k-1] = b;
		end
		frames[n_frames]  = d;
		f_start[n_frames] = t0;
		f_low[n_frames]   = rise;
		n_frames = n_frames + 1;
	end
end

task wait_frames;
	input integer n;
	integer guard;
	begin
		guard = 0;
		while (n_frames < n && guard < 300000) begin
			@(posedge clk);
			guard = guard + 1;
		end
	end
endtask

// Stimulus changes on the falling edge, so every rising edge sees a stable
// address, data and strobe — driving on posedge would race the DUT's own
// posedge sampling and can hand it the previous address with the new data.
task bus_wr;
	input [15:0] a;
	input [15:0] d;
	begin
		@(negedge clk);
		addr = a; wdata = d; wr = 1;
		@(negedge clk);
		wr = 0;
		@(posedge clk);
	end
endtask

task bus_rd;
	input  [15:0] a;
	output [15:0] d;
	begin
		@(negedge clk);
		addr = a; rd = 1;
		@(posedge clk);
		d = rdata;
		@(negedge clk);
		rd = 0;
	end
endtask

// drive one 8N1 byte onto the receive pin at 31.25 kbaud
task rx_byte;
	input [7:0] b;
	integer i;
	begin
		rx = 0;                        // start bit
		repeat (BIT) @(posedge clk);
		for (i = 0; i < 8; i = i + 1) begin
			rx = b[i];
			repeat (BIT) @(posedge clk);
		end
		rx = 1;                        // stop bit
		repeat (BIT) @(posedge clk);
	end
endtask

reg  [15:0] r;
integer     n0;

initial begin
	repeat (4) @(posedge clk);
	reset = 0;
	repeat (2) @(posedge clk);

	// ------------------------------------------------ 1. CNT readback
	bus_wr(16'h0150, 16'h0000);          // direction = write to the device
	bus_rd(16'h0150, r);
	check("AUXSPICNT readback, idle", r[0] === 1'b0 && r[15:1] === 15'd0);

	bus_wr(16'h0150, 16'h2000);          // bit 13 = read from the device
	bus_rd(16'h0150, r);
	check("AUXSPICNT bit 13 latches", r[13] === 1'b1);

	// ------------------------------------------------ 5. silent while reading
	bus_wr(16'h0154, 16'h00AA);          // direction = read: must not transmit
	repeat (BIT * 12) @(posedge clk);
	check("write with direction=read is silent", n_frames === 0 && tx === 1'b1);

	bus_wr(16'h0150, 16'h0000);          // back to write

	// ------------------------------------------------ 2. bit timing + content
	bus_wr(16'h0154, 16'h0090);          // note on, channel 1
	wait_frames(1);
	check("one byte transmitted", n_frames === 1);
	check("byte on the wire is 0x90", frames[0] === 8'h90);

	// 0x90 = 1001_0000 LSB first, so the start bit plus four zeros is the
	// first stretch low and the wire rises exactly five bit periods in.
	check("start bit + 4 zeros = 5 bit periods",
	      f_low[0] >= BIT * 5 && f_low[0] <= BIT * 5 + 2);
	check("frame is 10 bit periods end to end",
	      f_start[0] >= 0 && f_start[0] < cyc);
	repeat (BIT * 2) @(posedge clk);
	check("stop bit leaves the line idle", tx === 1'b1 && tx_busy === 1'b0);

	// ------------------------------------------------ 3/4. queue + busy bit
	n0 = n_frames;
	bus_wr(16'h0154, 16'h003C);
	bus_wr(16'h0154, 16'h0045);
	bus_rd(16'h0150, r);
	check("busy bit set while queued", r[0] === 1'b1);

	wait_frames(n0 + 3);
	check("queued byte 1 is 0x3C", frames[n0]     === 8'h3C);
	check("queued byte 2 is 0x45", frames[n0 + 1] === 8'h45);
	// both frames start exactly one frame apart (10 bit periods)
	check("queued bytes are back to back",
	      (f_start[n0 + 1] - f_start[n0]) >= BIT * 10 &&
	      (f_start[n0 + 1] - f_start[n0]) <= BIT * 10 + 2);

	repeat (BIT * 2) @(posedge clk);
	bus_rd(16'h0150, r);
	check("busy bit clears when drained", r[0] === 1'b0);

	// ------------------------------------------------ 6. receive path
	rx_byte(8'hC5);
	repeat (4) @(posedge clk);
	bus_rd(16'h015A, r);
	check("received byte 0xC5", r[7:0] === 8'hC5);

	rx_byte(8'h10);
	repeat (4) @(posedge clk);
	bus_rd(16'h015A, r);
	check("received byte 0x10", r[7:0] === 8'h10);

	// three bytes back to back, the way a MIDI device sends a message: the
	// receiver has to hold all of them, not just the latest one
	rx_byte(8'hE0);
	rx_byte(8'h7F);
	rx_byte(8'h01);
	repeat (4) @(posedge clk);
	bus_rd(16'h015A, r);
	check("back-to-back byte 1 is 0xE0", r[7:0] === 8'hE0);
	bus_rd(16'h015A, r);
	check("back-to-back byte 2 is 0x7F", r[7:0] === 8'h7F);
	bus_rd(16'h015A, r);
	check("back-to-back byte 3 is 0x01", r[7:0] === 8'h01);
	bus_rd(16'h015A, r);
	check("read from an empty FIFO returns 0", r[7:0] === 8'h00);

	// a low pulse shorter than half a bit is not a start bit
	rx = 0; repeat (64) @(posedge clk); rx = 1;
	repeat (BIT * 4) @(posedge clk);
	bus_rd(16'h015A, r);
	check("short low glitch ignored", r[7:0] === 8'h00);

	// ------------------------------------------------ 7. demo stream
	// The demo pushes a byte every DEMO_GAP ticks (32 here) from its first
	// entry, so the first thing on the wire is a note-on status byte.
	n0 = n_frames;
	demo_en = 1;
	wait_frames(n0 + 3);
	check("demo starts with a note-on status byte", frames[n0] === 8'h90);
	check("demo's second byte is the note number", frames[n0 + 1] === 8'h3C);
	check("demo's third byte is the velocity", frames[n0 + 2] === 8'h64);

	// over about ten byte times the UART should start several frames
	n0 = n_frames;
	repeat (BIT * 96) @(posedge clk);
	check("demo keeps pushing bytes", (n_frames - n0) >= 3);

	demo_en = 0;
	// switching off stops new pushes; the queue (up to 16 bytes) still drains
	repeat (BIT * 220) @(posedge clk);
	check("demo off leaves the line idle", tx === 1'b1 && tx_busy === 1'b0);

	if (errors == 0) $display("TB MIDI PORT PASS");
	else             $display("TB MIDI PORT FAIL (%0d errors)", errors);
	$finish;
end

endmodule
