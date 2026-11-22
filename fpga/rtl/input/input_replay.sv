//============================================================================
// NDS MiSTer Test — input recorder and replayer
//
// M6's replay row, without the memory half of savestates: the DS is
// deterministic frame to frame, so the only thing that has to be stored to
// reproduce a run is what the player did. One word per frame carries the
// whole input image the cores see --
//
//   [42]    hinge closed (EXTKEYIN bit 7)
//   [41:30] microphone level, 12 bits
//   [29]    stylus down
//   [28:21] stylus Y (0..191)
//   [20:12] stylus X (0..255)
//   [11:0]  KEYINPUT image, active low
//
// -- sampled at `frame`, the first active pixel of a frame, which is also
// where the reset is released. `live` is the mapped pad; `out` is what the
// machine gets, so with mode Off the recorder is a one-cycle pipe and the
// core behaves exactly as it did.
//
// Mode 1 records at the next frame; mode 2 plays the log from its start, one
// word per frame, then hands the live input back. The log is *not* cleared by
// `reset`, which is the core's reset: set Play, reset the core, and the run
// replays from the first frame. Set Record and reset to start a log at boot.
// A power-on leaves it empty (count = 0), and selecting Record again clears
// it. The memory is one dual-port block RAM, written once per frame while
// recording and read one word ahead while playing so the first replayed
// frame is already the first recorded one.
//
// What it cannot reproduce is anything else seeded from outside the run:
// the RTC row set to Host, a real BIOS that reads that clock at boot, or a
// fresh `.sav`. With RTC source Internal and the same ROM/save starting
// point, the frame the DS gets is the same one the recording saw.
//============================================================================
`timescale 1ns / 1ps

module input_replay #(
	// 8192 frames is about 2 minutes 17 seconds at the DS's 59.83 Hz, and
	// 48 bits each is 39 M10K blocks at the part's 10,240 bits per block.
	parameter DEPTH = 8192
) (
	input             clk,
	input             reset,        // core reset: keeps the log, stops I/O
	input             frame,        // one-cycle pulse at the first pixel
	input       [1:0] mode,         // 0 off, 1 record, 2 play
	input      [47:0] live,         // the mapped pad
	output reg [47:0] out,          // what the machine sees
	output reg        recording,
	output reg        playing,
	output reg [15:0] count = 16'd0, // frames in the log (survives reset)
	output reg [15:0] pos           // frames replayed so far
);

localparam OFF = 2'd0, REC = 2'd1, PLAY = 2'd2;

reg [47:0] mem [0:DEPTH-1];
reg [47:0] q;              // the word prefetched for the next frame
reg [15:0] wr, rd;
reg        primed;
reg  [1:0] mode_d;

always @(posedge clk) begin
	if (reset) begin
		// the log and its length survive: a reset is how a replay starts
		out       <= live;
		recording <= 1'b0;
		playing   <= 1'b0;
		wr        <= 16'd0;
		rd        <= 16'd0;
		primed    <= 1'b0;
		pos       <= 16'd0;
		mode_d    <= OFF;
	end else begin
		mode_d <= mode;

		if (mode != mode_d) begin
			// entering either running mode starts at the top of the log
			wr     <= 16'd0;
			rd     <= 16'd0;
			primed <= 1'b0;
			pos    <= 16'd0;
			recording <= (mode == REC);
			playing   <= (mode == PLAY) && (count != 16'd0);
			if (mode == REC) count <= 16'd0;
		end else if (mode == OFF) begin
			recording <= 1'b0;
			playing   <= 1'b0;
			primed    <= 1'b0;
		end

		if (recording) begin
			out <= live;
			if (frame) begin
				mem[wr] <= live;
				if (wr + 16'd1 >= DEPTH) begin
					count     <= DEPTH;
					recording <= 1'b0;   // full: stop, keep the log
				end else begin
					wr    <= wr + 16'd1;
					count <= wr + 16'd1;
				end
			end
		end else if (playing) begin
			if (!primed) begin
				// one read before the first frame, so that frame plays
				// the word recorded first rather than a frame late
				q      <= mem[rd];
				rd     <= rd + 16'd1;
				primed <= 1'b1;
				out    <= live;
			end else if (frame) begin
				out <= q;
				pos <= pos + 16'd1;
				if (rd < count) begin
					q  <= mem[rd];
					rd <= rd + 16'd1;
				end else begin
					playing <= 1'b0;
				end
			end
		end else begin
			out <= live;
		end
	end
end

endmodule
