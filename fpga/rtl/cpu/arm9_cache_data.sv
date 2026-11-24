//============================================================================
// NDS MiSTer Test — a cache's data array
//
// The storage half of a cache: every way of every set, every word of a line,
// behind one write port and one read port. What it does not hold is any idea
// of what is in it -- which line of which set and way is valid, and which is
// dirty, lives in rtl/cpu/arm9_cache_tag.sv, and this module is indexed by
// what that one says.
//
// Geometry follows CP15_CACHETYPE, 32-byte lines and four ways: 32 sets and
// 4 KB for the data cache, 64 sets and 8 KB for the instruction cache. The
// line's words are at address bits 4:2, so a fill walks eight of them and a
// store lands on one.
//
// The read port is registered, deliberately: an array read in the access's
// own cycle is an asynchronous read, and Quartus answers an asynchronous
// read of a 4,096-word array by building it out of registers (the tags took
// 3,157 flops that way and 2,413 ALMs with them).
//
// A registered read is necessary for block RAM and not sufficient, which the
// first fit of this module proved: with the read and the write in one always
// block and a 16-bit index into a 1,024-word array, the whole thing came out
// as 21,824 logic elements, and the design stopped fitting the device by
// 1,415 LABs. The two conditions this now keeps are that the read and the
// write are separate always blocks, so there are visibly two ports, and that
// the index is exactly as wide as the array, so the address is provably in
// range.
//
// The price is a cycle: whoever reads this has to present an address and
// take the word on the next edge. The tags are the exception on purpose --
// a maintenance command has to see the store that preceded it, and the tag
// compare is small enough to afford being asynchronous.
//
// Byte lanes are four byte-wide arrays rather than one word-wide array with
// a byte enable, because a byte of a line has to be writable without
// reading the word first: a store to a line the cache holds writes only the
// lanes it addresses, and the rest of the word is whatever the fill put
// there. Reading a word is one read from each of the four.
//
// There is no reset here and no initial state. A cache's contents are
// undefined until something fills them, and what makes a word meaningful is
// a valid bit somewhere else; a reset that cleared 12 KB of block RAM would
// be a reset that clears every bit of it every time.
//============================================================================
`timescale 1ns / 1ps

module arm9_cache_data #(
	parameter SETS  = 32,       // 32 for the data cache, 64 for the I cache
	parameter SETB  = 5,        // log2(SETS)
	parameter WORDS = 8         // 32-byte lines, one word each
) (
	input               clk,
	input               ce,
	// the read port: an address now, the word on the next enabled edge
	input      [SETB-1:0] rd_set,
	input      [1:0]    rd_way,
	input      [2:0]    rd_word,
	output reg  [31:0]  rd_data,
	// the write port: one word of one line, byte lanes selected
	input               wr,
	input      [SETB-1:0] wr_set,
	input      [1:0]    wr_way,
	input      [2:0]    wr_word,
	input      [31:0]  wr_data,
	input      [3:0]   wr_be
);

	localparam DEPTH = SETS * 4 * WORDS;
	localparam IW    = $clog2(DEPTH);

	// one array per byte lane, so a byte store is one array write
	(* ramstyle = "M10K" *) reg [7:0] lane0 [0:DEPTH-1];
	(* ramstyle = "M10K" *) reg [7:0] lane1 [0:DEPTH-1];
	(* ramstyle = "M10K" *) reg [7:0] lane2 [0:DEPTH-1];
	(* ramstyle = "M10K" *) reg [7:0] lane3 [0:DEPTH-1];

	// a line is one contiguous run of WORDS, ways above sets. The index is
	// exactly as wide as the array: an index wider than DEPTH is an index
	// Quartus cannot prove in range, and it answers by building the array
	// out of registers instead of block RAM.
	function [31:0] index (input [1:0] way, input [SETB-1:0] set,
	                       input [2:0] word);
		begin
			index = (way * SETS + set) * WORDS + word;
		end
	endfunction

	wire [IW-1:0] rd_idx = index(rd_way, rd_set, rd_word);
	wire [IW-1:0] wr_idx = index(wr_way, wr_set, wr_word);

	// the write port and the read port are separate always blocks on purpose:
	// one write port and one read port in one block is a pattern Quartus reads
	// as a single-port memory with a bypass, and it answers that by building
	// registers. Two blocks are two ports, and two ports of this shape are
	// what an M10K is.
	always @(posedge clk) begin
		if (ce && wr) begin
			if (wr_be[0]) lane0[wr_idx] <= wr_data[7:0];
			if (wr_be[1]) lane1[wr_idx] <= wr_data[15:8];
			if (wr_be[2]) lane2[wr_idx] <= wr_data[23:16];
			if (wr_be[3]) lane3[wr_idx] <= wr_data[31:24];
		end
	end

	always @(posedge clk) begin
		if (ce) begin
			rd_data <= {lane3[rd_idx], lane2[rd_idx],
			            lane1[rd_idx], lane0[rd_idx]};
		end
	end

endmodule
