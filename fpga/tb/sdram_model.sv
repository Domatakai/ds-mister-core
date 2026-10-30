//============================================================================
// sdram_model — behavioural 16-bit SDRAM device with protocol checking
//
// Small model of the DE10-Nano's SDRAM chip as `sdram_ctrl` drives it:
// 4 banks x 8 rows x 512 columns (32 KB of halfwords, enough to exercise
// row handling), CL=3, burst length 1, byte masks through DQM, auto-
// precharge through A10.
//
// It is deliberately strict — it fails the simulation on protocol
// violations the controller must never commit:
//
//   * ACTIVE to a row while a different row is open in that bank
//     (needs PRECHARGE first)
//   * READ/WRITE while the bank has no open row
//   * READ/WRITE closer than tRCD (2 clocks) to the ACTIVE
//   * AUTO REFRESH with any bank open (needs PRECHARGE ALL first)
//
// and it counts commands, so a bench can assert that a sequential run
// really reuses the open row (one ACTIVE, N reads) instead of reopening
// it every access.
//
// Commands are latched on the chip clock (SDRAM_CLK, the inverted system
// clock), read data appears CL clocks later, writes are sampled on the
// command clock with DQM as an active-high byte mask.
//============================================================================
module sdram_model #(
	parameter ROW_BITS = 3       // rows kept distinct (8 here, more in big benches)
) (
	input             sclk,      // chip clock (sdram_ctrl's SDRAM_CLK)
	input      [12:0] a,
	input      [1:0]  ba,
	inout      [15:0] dq,
	input      [1:0]  dqm,       // {DQMH, DQML}: 1 = masked
	input      [3:0]  op,        // {nCS, nCAS, nRAS, nWE}
	input             cke
);

localparam OP_NOP  = 4'b0111,
           OP_READ = 4'b0101,
           OP_WRIT = 4'b0100,
           OP_PRE  = 4'b0010,
           OP_REF  = 4'b0001,
           OP_LMR  = 4'b0000,
           OP_ACT  = 4'b0110;

localparam CL = 3;
localparam TRCD = 2;

// 4 banks x 2^ROW_BITS rows x 512 columns
localparam MEMW = 11 + ROW_BITS;
reg [15:0] mem [0:(1 << MEMW) - 1];
reg [12:0] orow [0:3];
reg        open [0:3];
reg [3:0]  since_act [0:3];

integer n_act = 0, n_pre = 0, n_ref = 0, n_read = 0, n_write = 0, n_lmr = 0;
integer errs = 0;

// read-data pipeline: a command latched here surfaces on DQ CL clocks
// later (one entry per clock of latency plus the launch entry)
reg [16:0] dqp [0:CL];

assign dq = dqp[CL][16] ? dqp[CL][15:0] : 16'hzzzz;

function [MEMW-1:0] midx;
	input [1:0]  bank;
	input [12:0] row;
	input [8:0]  col;
	begin
		midx = {bank, row[ROW_BITS-1:0], col};
	end
endfunction

task err;
	input [8*48:1] what;
	begin
		errs = errs + 1;
		$display("SDRAM MODEL ERROR: %0s (time %0t)", what, $time);
	end
endtask

integer k, b;
integer col;
reg [15:0] word;
reg [15:0] merged;

always @(posedge sclk) begin
	// default: no data on the bus
	dqp[0] <= 17'h0_0000;
	for (k = 1; k <= CL; k = k + 1) dqp[k] <= dqp[k-1];

	for (b = 0; b < 4; b = b + 1)
		if (open[b] && since_act[b] != 4'hF) since_act[b] <= since_act[b] + 1;

	if (!cke) begin
		// clock disabled: ignore everything
	end else begin
		case (op)
		OP_ACT: begin
			if (open[ba] && orow[ba] != a) begin
				err("ACT to another row without PRECHARGE");
			end
			open[ba]      <= 1'b1;
			orow[ba]      <= a;
			since_act[ba] <= 4'd0;
			n_act         <= n_act + 1;
		end

		OP_READ: begin
			if (!open[ba]) err("READ with the bank precharged");
			else if (since_act[ba] < TRCD) err("READ inside tRCD");
			col  = a[8:0];
			word = mem[midx(ba, orow[ba], col)];
			n_read <= n_read + 1;
			dqp[0] <= {1'b1, word};
			if (a[10]) begin   // auto-precharge at the end of the access
				open[ba] <= 1'b0;
				n_pre    <= n_pre + 1;
			end
		end

		OP_WRIT: begin
			if (!open[ba]) err("WRITE with the bank precharged");
			else if (since_act[ba] < TRCD) err("WRITE inside tRCD");
			col = a[8:0];
			merged = mem[midx(ba, orow[ba], col)];
			if (dqm[0] == 1'b0) merged[7:0]  = dq[7:0];
			if (dqm[1] == 1'b0) merged[15:8] = dq[15:8];
			mem[midx(ba, orow[ba], col)] <= merged;
			n_write <= n_write + 1;
			if (a[10]) begin
				open[ba] <= 1'b0;
				n_pre    <= n_pre + 1;
			end
		end

		OP_PRE: begin
			if (a[10]) begin
				for (b = 0; b < 4; b = b + 1) open[b] <= 1'b0;
			end else begin
				open[ba] <= 1'b0;
			end
			n_pre <= n_pre + 1;
		end

		OP_REF: begin
			if (open[0] || open[1] || open[2] || open[3])
				err("REFRESH with an open row");
			n_ref <= n_ref + 1;
		end

		OP_LMR: begin
			n_lmr <= n_lmr + 1;
		end

		OP_NOP: ;

		default: err("undefined command");
		endcase
	end
end

// the bench may write expectations straight into the device
task poke;
	input [1:0]  bank;
	input [12:0] row;
	input [8:0]  col;
	input [15:0] data;
	begin
		mem[midx(bank, row, col)] = data;
	end
endtask

task clear;
	begin
		for (k = 0; k < (1 << MEMW); k = k + 1) mem[k] = 16'h0000;
		for (b = 0; b < 4; b = b + 1) begin
			open[b] = 1'b0;
			orow[b] = 13'd0;
			since_act[b] = 4'hF;
		end
		n_act = 0; n_pre = 0; n_ref = 0; n_read = 0; n_write = 0; n_lmr = 0;
		errs = 0;
	end
endtask

endmodule
