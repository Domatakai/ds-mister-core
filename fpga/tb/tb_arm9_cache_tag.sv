//============================================================================
// NDS MiSTer Test — the cache tags and line state
//
//   iverilog -g2012 -o /tmp/tb_cache_tag tb/tb_arm9_cache_tag.sv \
//            rtl/cpu/arm9_cache_tag.sv
//   vvp /tmp/tb_cache_tag
//
// Two copies of the module: the data cache's geometry (32 sets, 22 tag
// bits, dirty state) and the instruction cache's (64 sets, 21 tag bits, no
// dirty state). Accesses are pulses, as the core presents them, and every
// result is read from the module's own outputs -- last_hit, last_way,
// last_valid, hits, misses and dirty_any -- so nothing here is a re-check of
// arithmetic the bench did itself.
//
//   * with the cache's enable bit clear an access misses and no line is
//     filled; with it set the first access fills a line and the second to
//     the same 32-byte line hits
//   * a store marks the line it lands on dirty, a clean by address clears
//     just that line, and test-and-clean answers from dirty_any and clears
//     every dirty bit at once
//   * invalidate-all empties the whole cache (the walk over the sets), and
//     invalidate-by-address leaves the other lines alone
//   * the by-index forms take the way in the low bits and the set above it
//   * a locked way is never chosen as a victim, and an access to a fifth
//     line in a fully locked set is not cached at all
//   * the instruction geometry fills and hits, and its dirty output stays
//     low whatever happens
//============================================================================
`timescale 1ns / 1ps

module tb_arm9_cache_tag;

reg clk = 0;
always #10 clk = ~clk;

reg  reset = 1;
reg  enable = 0;
reg  acc = 0;
reg  [31:0] acc_addr = 0;
reg  acc_wr = 0;
reg  mnt = 0;
reg  [3:0] mnt_cmd = 0;
reg  [31:0] mnt_arg = 0;
reg  [1:0] lock_way = 0;
reg  lock_en = 0;

wire        d_dirty, i_dirty;
wire        d_hit, i_hit;
wire        d_probe_hit, i_probe_hit;
wire [1:0]  d_probe_way, i_probe_way;
wire [1:0]  d_way, i_way;
wire [3:0]  d_valid, i_valid;
wire [15:0] d_hits, d_misses, i_hits, i_misses;

arm9_cache_tag #(.SETS(32), .SETB(5), .TAGW(22), .DIRTY(1)) dtag (
	.clk(clk), .ce(1'b1), .reset(reset), .enable(enable),
	.alloc(enable),
	.snoop(1'b0), .snoop_addr(32'd0),
	.acc(acc), .acc_addr(acc_addr), .acc_wr(acc_wr),
	.mnt(mnt), .mnt_cmd(mnt_cmd), .mnt_arg(mnt_arg),
	.lock_way(lock_way), .lock_en(lock_en),
	.dirty_any(d_dirty), .hit_now(d_probe_hit), .way_now(d_probe_way),
	.last_hit(d_hit), .last_way(d_way),
	.last_valid(d_valid), .hits(d_hits), .misses(d_misses)
);

arm9_cache_tag #(.SETS(64), .SETB(6), .TAGW(21), .DIRTY(0)) itag (
	.clk(clk), .ce(1'b1), .reset(reset), .enable(enable),
	.alloc(enable),
	.snoop(1'b0), .snoop_addr(32'd0),
	.acc(acc), .acc_addr(acc_addr), .acc_wr(acc_wr),
	.mnt(mnt), .mnt_cmd(mnt_cmd), .mnt_arg(mnt_arg),
	.lock_way(lock_way), .lock_en(lock_en),
	.dirty_any(i_dirty), .hit_now(i_probe_hit), .way_now(i_probe_way),
	.last_hit(i_hit), .last_way(i_way),
	.last_valid(i_valid), .hits(i_hits), .misses(i_misses)
);

localparam [3:0] M_INVALL = 4'd1, M_INVLINE = 4'd2, M_CLEAN = 4'd3,
                 M_CLEANINV = 4'd4, M_CLEANIDX = 4'd5, M_CLEANINVIDX = 4'd6,
                 M_TESTCLEAN = 4'd7, M_TESTINV = 4'd8;

integer errors = 0;
task check;
	input [8*54:1] name;
	input          cond;
	begin
		if (cond !== 1'b1) begin
			$display("FAIL %0s", name);
			errors = errors + 1;
		end else
			$display("ok   %0s", name);
	end
endtask

// one access: issue a pulse, let the compare and the fill happen
task access;
	input [31:0] addr;
	input        wr;
	begin
		@(negedge clk);
		acc = 1; acc_addr = addr; acc_wr = wr;
		@(negedge clk);
		acc = 0;
		@(negedge clk);
	end
endtask

// one maintenance command, and a wait long enough for a whole-cache walk
// (64 sets) plus the two-cycle issue
task command;
	input [3:0]  cmd;
	input [31:0] arg;
	begin
		@(negedge clk);
		mnt = 1; mnt_cmd = cmd; mnt_arg = arg;
		@(negedge clk);
		mnt = 0; mnt_cmd = 0;
		repeat (70) @(negedge clk);
	end
endtask

initial begin
	repeat (4) @(posedge clk);
	reset = 0;
	repeat (4) @(posedge clk);

	// ------------------------------------------- 1. disabled = observe only
	access(32'h0200_0000, 1'b0);
	check("disabled: the access misses", d_hit === 1'b0);
	check("disabled: nothing is valid", d_valid === 4'b0000);
	access(32'h0200_0000, 1'b0);
	check("disabled: the same line misses again", d_hit === 1'b0);
	check("disabled: two misses counted", d_misses === 16'd2);
	check("disabled: no dirty line", d_dirty === 1'b0);

	// ------------------------------------------- 2. fill and hit
	enable = 1;
	access(32'h0200_0000, 1'b0);
	check("enabled: the first access misses", d_hit === 1'b0);
	check("enabled: it fills way 0", d_way === 2'd0);
	access(32'h0200_0018, 1'b0);
	check("enabled: the same 32-byte line hits", d_hit === 1'b1);
	check("enabled: the hit is way 0", d_way === 2'd0);
	check("enabled: one line valid", d_valid == 4'b0001);
	check("enabled: one hit counted", d_hits === 16'd1);
	access(32'h0200_0400, 1'b0);
	check("next line in the same set misses", d_hit === 1'b0);
	check("next line fills the next way", d_way === 2'd1);
	// last_valid is the set's state as the access compared it, so the two
	// filled ways show up on the access after the second one
	access(32'h0200_0000, 1'b0);
	check("two lines valid", d_valid == 4'b0011);
	check("the first line still hits", d_hit === 1'b1);

	// ------------------------------------------- 3. dirty and clean
	access(32'h0200_0004, 1'b1);
	check("a store hits the line", d_hit === 1'b1);
	check("the stored line is dirty", d_dirty === 1'b1);
	command(M_CLEAN, 32'h0200_0000);
	check("clean by address clears it", d_dirty === 1'b0);
	access(32'h0200_0004, 1'b1);
	check("a second store dirties it again", d_dirty === 1'b1);
	command(M_TESTCLEAN, 32'h0);
	check("test and clean leaves nothing dirty", d_dirty === 1'b0);
	access(32'h0200_0004, 1'b0);
	check("test and clean kept the line", d_hit === 1'b1);

	// ------------------------------------------- 4. invalidate
	command(M_INVLINE, 32'h0200_0000);
	access(32'h0200_0000, 1'b0);
	check("invalidate by address dropped that line", d_hit === 1'b0);
	access(32'h0200_0400, 1'b0);
	check("the other line in the set survived", d_hit === 1'b1);
	command(M_INVALL, 32'h0);
	access(32'h0200_0400, 1'b0);
	check("invalidate-all dropped the whole cache", d_hit === 1'b0);
	check("and no line is valid", d_valid === 4'b0000);
	command(M_INVALL, 32'h0);
	access(32'h0200_0400, 1'b0);
	check("a second invalidate-all does not resurrect it", d_hit === 1'b0);

	// ------------------------------------------- 5. by index
	access(32'h0200_0100, 1'b0);           // set 8, way 0
	check("index test: the line filled", d_hit === 1'b0);
	access(32'h0200_0104, 1'b1);
	check("index test: the store dirtied it", d_dirty === 1'b1);
	// way 0 in bits 1:0, set 8 above them
	command(M_CLEANIDX, 32'h0000_0020);
	check("clean by index cleared way 0 of set 8", d_dirty === 1'b0);
	access(32'h0200_0104, 1'b0);
	check("clean by index kept the line valid", d_hit === 1'b1);
	command(M_CLEANINVIDX, 32'h0000_0020);
	access(32'h0200_0104, 1'b0);
	check("clean and invalidate by index dropped it", d_hit === 1'b0);

	// ------------------------------------------- 6. lockdown
	command(M_INVALL, 32'h0);
	access(32'h0200_0000, 1'b0);           // set 0, way 0
	access(32'h0200_0400, 1'b0);           // set 0, way 1
	access(32'h0200_0800, 1'b0);           // set 0, way 2
	access(32'h0200_0C00, 1'b0);           // set 0, way 3
	access(32'h0200_0000, 1'b0);
	check("lockdown test: four ways filled", d_valid === 4'b1111);
	lock_en = 1; lock_way = 2'd1;
	access(32'h0200_1000, 1'b0);
	check("a fenced access is not cached", d_hit === 1'b0);
	check("no way was overwritten", d_valid === 4'b1111);
	lock_way = 2'd0;
	access(32'h0200_1400, 1'b0);
	check("with one way free the fence lets it in", d_hit === 1'b0);
	lock_en = 0;

	// ------------------------------------------- 7. the instruction geometry
	command(M_INVALL, 32'h0);
	access(32'h0200_2000, 1'b0);
	check("I: the first access misses", i_hit === 1'b0);
	access(32'h0200_2004, 1'b0);
	check("I: the same line hits", i_hit === 1'b1);
	check("I: one way valid", i_valid == 4'b0001);
	access(32'h0200_2004, 1'b1);
	check("I: a store on a hit leaves no dirty state", i_dirty === 1'b0);
	access(32'h0200_2020, 1'b0);           // set 1 (64 sets: bit 5..10)
	check("I: a different set misses", i_hit === 1'b0);
	command(M_INVALL, 32'h0);
	access(32'h0200_2004, 1'b0);
	check("I: invalidate-all dropped it", i_hit === 1'b0);

	// ------------------------------------------- 8. the probe outputs
	// hit_now and way_now are what the core decides on before it goes to the
	// bus, so they have to be right in the cycle the address is presented and
	// not a cycle later, which is what the registered last_hit gives.
	command(M_INVALL, 32'h0);
	enable = 1;
	access(32'h0200_0800, 1'b0);
	@(negedge clk);
	acc = 1; acc_addr = 32'h0200_0810; acc_wr = 0;
	#1;
	check("probe: the line reports a hit in its own cycle",
	      d_probe_hit === 1'b1);
	check("probe: and names the way", d_probe_way === 2'd0);
	acc_addr = 32'h0200_0900;
	#1;
	check("probe: a line that is not there misses",
	      d_probe_hit === 1'b0);
	check("probe: and offers the free way as the victim",
	      d_probe_way === 2'd0);
	@(negedge clk);
	acc = 0;

	$display("  %0d checks", d_hits + d_misses + i_hits + i_misses);
	if (errors == 0) $display("TB ARM9 CACHE TAG PASS");
	else             $display("TB ARM9 CACHE TAG FAIL: %0d error(s)", errors);
	$finish;
end

endmodule
