//============================================================================
// tb_arm9_cache_data — the cache's line store
//
// The array is addressed by a set, a way and a word of a line, and it has to
// keep those apart: four ways at one set are four different lines, the eight
// words of a line are eight different words, and the last set of the deepest
// geometry is a real address, not one that wrapped onto set 0. The write
// port takes byte lanes, so a byte store has to leave the other three
// untouched, and the read port is registered, so the word appears one
// enabled edge after the address and not before.
//
// Both geometries are instantiated: the data cache's 32 sets of 5-bit index
// and the instruction cache's 64 of 6, which is where an index that lost a
// bit would show up as a set that aliases.
//============================================================================
`timescale 1ns / 1ps

module tb_arm9_cache_data;

	reg clk = 0, ce = 1;
	reg [4:0]  d_rd_set = 0, d_wr_set = 0;
	reg [1:0]  d_rd_way = 0, d_wr_way = 0;
	reg [2:0]  d_rd_word = 0, d_wr_word = 0;
	reg        d_wr = 0;
	reg [31:0] d_wr_data = 0;
	reg [3:0]  d_wr_be = 4'b1111;
	wire [31:0] d_rd_data;

	reg [5:0]  i_rd_set = 0, i_wr_set = 0;
	reg [1:0]  i_rd_way = 0, i_wr_way = 0;
	reg [2:0]  i_rd_word = 0, i_wr_word = 0;
	reg        i_wr = 0;
	reg [31:0] i_wr_data = 0;
	reg [3:0]  i_wr_be = 4'b1111;
	wire [31:0] i_rd_data;

	arm9_cache_data #(.SETS(32), .SETB(5)) d_array (
		.clk(clk), .ce(ce),
		.rd_set(d_rd_set), .rd_way(d_rd_way), .rd_word(d_rd_word),
		.rd_data(d_rd_data),
		.wr(d_wr), .wr_set(d_wr_set), .wr_way(d_wr_way),
		.wr_word(d_wr_word), .wr_data(d_wr_data), .wr_be(d_wr_be)
	);

	arm9_cache_data #(.SETS(64), .SETB(6)) i_array (
		.clk(clk), .ce(ce),
		.rd_set(i_rd_set), .rd_way(i_rd_way), .rd_word(i_rd_word),
		.rd_data(i_rd_data),
		.wr(i_wr), .wr_set(i_wr_set), .wr_way(i_wr_way),
		.wr_word(i_wr_word), .wr_data(i_wr_data), .wr_be(i_wr_be)
	);

	always #5 clk = ~clk;

	integer checks = 0, fails = 0;

	task check (input [63:0] want, input [63:0] got, input [255:0] what);
		begin
			checks = checks + 1;
			if (want !== got) begin
				fails = fails + 1;
				$display("FAIL %0s: wanted %h, got %h", what, want, got);
			end
		end
	endtask

	// one write into the data cache's array
	task d_store (input [1:0] way, input [4:0] set, input [2:0] word,
	              input [31:0] data, input [3:0] be);
		begin
			@(negedge clk);
			d_wr = 1; d_wr_way = way; d_wr_set = set; d_wr_word = word;
			d_wr_data = data; d_wr_be = be;
			@(negedge clk);
			d_wr = 0;
		end
	endtask

	// address, then the word one edge later
	task d_load (input [1:0] way, input [4:0] set, input [2:0] word,
	             output [31:0] data);
		begin
			@(negedge clk);
			d_rd_way = way; d_rd_set = set; d_rd_word = word;
			@(posedge clk); #1;
			data = d_rd_data;
		end
	endtask

	task i_store (input [1:0] way, input [5:0] set, input [2:0] word,
	              input [31:0] data);
		begin
			@(negedge clk);
			i_wr = 1; i_wr_way = way; i_wr_set = set; i_wr_word = word;
			i_wr_data = data; i_wr_be = 4'b1111;
			@(negedge clk);
			i_wr = 0;
		end
	endtask

	task i_load (input [1:0] way, input [5:0] set, input [2:0] word,
	             output [31:0] data);
		begin
			@(negedge clk);
			i_rd_way = way; i_rd_set = set; i_rd_word = word;
			@(posedge clk); #1;
			data = i_rd_data;
		end
	endtask

	reg [31:0] got;
	integer w;

	initial begin
		$dumpfile("tb_arm9_cache_data.vcd");
		$dumpvars(0, tb_arm9_cache_data);

		//--------------------------------------------------------------
		// a word, read back where it was written
		//--------------------------------------------------------------
		d_store(2'd1, 5'd9, 3'd3, 32'h1234_5678, 4'b1111);
		d_load (2'd1, 5'd9, 3'd3, got);
		check(32'h1234_5678, got, "a word read back");

		//--------------------------------------------------------------
		// the four ways of one set are four lines, not one
		//--------------------------------------------------------------
		for (w = 0; w < 4; w = w + 1)
			d_store(w[1:0], 5'd20, 3'd0, 32'hA000_0000 + w, 4'b1111);
		for (w = 0; w < 4; w = w + 1) begin
			d_load(w[1:0], 5'd20, 3'd0, got);
			check(32'hA000_0000 + w, got, "way keeps its own line");
		end

		//--------------------------------------------------------------
		// the eight words of a line are eight words
		//--------------------------------------------------------------
		for (w = 0; w < 8; w = w + 1)
			d_store(2'd3, 5'd5, w[2:0], 32'h5E00_0000 + w, 4'b1111);
		for (w = 0; w < 8; w = w + 1) begin
			d_load(2'd3, 5'd5, w[2:0], got);
			check(32'h5E00_0000 + w, got, "word of a line");
		end

		//--------------------------------------------------------------
		// byte lanes: one lane written, three left alone
		//--------------------------------------------------------------
		d_store(2'd0, 5'd1, 3'd0, 32'hAABB_CCDD, 4'b1111);
		d_store(2'd0, 5'd1, 3'd0, 32'h0000_1100, 4'b0010);
		d_load (2'd0, 5'd1, 3'd0, got);
		check(32'hAABB_11DD, got, "byte 1 only");

		d_store(2'd0, 5'd1, 3'd1, 32'h1122_3344, 4'b1111);
		d_store(2'd0, 5'd1, 3'd1, 32'h5500_0000, 4'b1000);
		d_load (2'd0, 5'd1, 3'd1, got);
		check(32'h5522_3344, got, "byte 3 only");

		d_store(2'd0, 5'd1, 3'd2, 32'h0000_0000, 4'b1111);
		d_store(2'd0, 5'd1, 3'd2, 32'h0000_00EE, 4'b0001);
		d_load (2'd0, 5'd1, 3'd2, got);
		check(32'h0000_00EE, got, "byte 0 only");

		d_store(2'd0, 5'd1, 3'd3, 32'h0000_0000, 4'b1111);
		d_store(2'd0, 5'd1, 3'd3, 32'h0077_0000, 4'b0100);
		d_load (2'd0, 5'd1, 3'd3, got);
		check(32'h0077_0000, got, "byte 2 only");

		// a write with no lanes enabled changes nothing
		d_store(2'd0, 5'd1, 3'd0, 32'hFFFF_FFFF, 4'b0000);
		d_load (2'd0, 5'd1, 3'd0, got);
		check(32'hAABB_11DD, got, "no lanes, no change");

		// and a write with wr low changes nothing either
		@(negedge clk);
		d_wr_way = 2'd0; d_wr_set = 5'd1; d_wr_word = 3'd0;
		d_wr_data = 32'hFFFF_FFFF; d_wr_be = 4'b1111; d_wr = 0;
		@(negedge clk);
		d_load(2'd0, 5'd1, 3'd0, got);
		check(32'hAABB_11DD, got, "wr low, no change");

		//--------------------------------------------------------------
		// the registered read: the word is the one the address asked for
		// one edge later, and not the one before
		//--------------------------------------------------------------
		d_store(2'd3, 5'd31, 3'd7, 32'h0BAD_F00D, 4'b1111);
		d_store(2'd3, 5'd31, 3'd6, 32'h0BAD_F00E, 4'b1111);
		@(negedge clk);
		d_rd_way = 2'd3; d_rd_set = 5'd31; d_rd_word = 3'd7;
		@(posedge clk); #1;
		check(32'h0BAD_F00D, d_rd_data, "top set, top word");
		@(negedge clk);
		d_rd_word = 3'd6;
		@(posedge clk); #1;
		check(32'h0BAD_F00E, d_rd_data, "address changed, word follows");

		// the deepest address of the geometry is not set 0
		d_store(2'd0, 5'd0, 3'd0, 32'h0BAD_0000, 4'b1111);
		d_store(2'd3, 5'd31, 3'd7, 32'hDEAD_BEEF, 4'b1111);
		d_load (2'd3, 5'd31, 3'd7, got);
		check(32'hDEAD_BEEF, got, "top address holds its own word");
		d_load (2'd0, 5'd0, 3'd0, got);
		check(32'h0BAD_0000, got, "top address does not wrap to 0");

		//--------------------------------------------------------------
		// the instruction cache's geometry: 64 sets, and set 40 is not 8
		//--------------------------------------------------------------
		i_store(2'd1, 6'd40, 3'd2, 32'h1C40_0002);
		i_store(2'd1, 6'd8,  3'd2, 32'h1C08_0002);
		i_load (2'd1, 6'd40, 3'd2, got);
		check(32'h1C40_0002, got, "64-set array, set 40");
		i_load (2'd1, 6'd8,  3'd2, got);
		check(32'h1C08_0002, got, "64-set array, set 8");
		i_store(2'd1, 6'd63, 3'd7, 32'h1C3F_FFFF);
		i_load (2'd1, 6'd63, 3'd7, got);
		check(32'h1C3F_FFFF, got, "64-set array, last word");
		i_load (2'd1, 6'd31, 3'd7, got);
		check(32'h1C3F_FFFF !== got, 1'b1, "set 63 and set 31 differ");

		// the two arrays are separate memories
		d_load(2'd1, 5'd8, 3'd2, got);
		check(32'h1C08_0002 !== got, 1'b1, "arrays do not share cells");

		//--------------------------------------------------------------
		// the enable holds the read port still
		//--------------------------------------------------------------
		d_store(2'd2, 5'd4, 3'd0, 32'h0000_0042, 4'b1111);
		d_load (2'd2, 5'd4, 3'd0, got);
		check(32'h0000_0042, got, "before the held cycle");
		@(negedge clk);
		ce = 0;
		d_rd_way = 2'd2; d_rd_set = 5'd4; d_rd_word = 3'd0;
		d_wr = 1; d_wr_way = 2'd2; d_wr_set = 5'd4; d_wr_word = 3'd0;
		d_wr_data = 32'h0000_0099; d_wr_be = 4'b1111;
		@(negedge clk);
		d_wr = 0; ce = 1;
		#1;
		check(32'h0000_0042, d_rd_data, "ce low: no write, port held");
		d_load(2'd2, 5'd4, 3'd0, got);
		check(32'h0000_0042, got, "ce low: the word is unchanged");

		$display("tb_arm9_cache_data: %0d checks, %0d failed", checks, fails);
		if (fails == 0) $display("TB ARM9 CACHE DATA PASS");
		else             $display("TB ARM9 CACHE DATA FAIL: %0d error(s)", fails);
		$finish;
	end

endmodule
