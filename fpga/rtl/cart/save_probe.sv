//============================================================================
// NDS MiSTer Test — AUXSPI save-type probe
//
// GBATEK, *DS Cartridge Backup*, "Detection (by examining hardware
// responses)": a cart's save memory is classified by what it answers on the
// SPI bus, never by the ROM header (Nintendo never put a backup-type byte
// there). This runs that probe against the cart's emulated chip:
//
//   RDSR (05h)  7..4 all ones  -> EEPROM with 8+1-bit addresses (0.5K)
//               7..4 all zero  -> EEPROM/FRAM (16-bit) or FLASH (24-bit)
//               FFh            -> nothing fitted
//   RDID (9Fh)  FFh FFh FFh FFh -> EEPROM or FRAM
//               20h 20h 13h/14h -> FLASH, capacity byte 13h = 4 Mbit
//                                  (512 KB), 14h = 8 Mbit (1 MB)
//   RD (03h)    the address bus is probed for mirrors, which tells an 8 KB
//               part from a 32 KB one from a 64 KB one: an address past the
//               end folds back onto the low address it aliases
//   RDSR again  EEPROM raises WIP while a page programs, FRAM never does --
//               the one bit that separates the two 16-bit families
//
// The probe writes a two-byte signature, reads it back through the candidate
// mirrors and puts the original bytes back, so an existing save image is left
// as it was found. Nothing here trusts the OSD row: the answer is what the
// bus returned, and a chip that cannot be identified reports none.
//============================================================================
module save_probe (
	input             clk,
	input             reset,

	input             start,      // one-cycle pulse: classify the fitted chip

	// byte-level chip bus (see save_spi)
	output reg        cs_n,
	output reg [7:0]  din,
	output reg        slot,
	input      [7:0]  dout,
	input             resp,

	// result
	output reg [2:0]  det_type,   // OSD save-type code: 0 = nothing detected
	output reg        valid,      // a probe has completed since reset
	output reg        done,       // one-cycle pulse when it does
	output reg [7:0]  seen_status,
	output reg [31:0] seen_id,    // RDID bytes, most significant first
	output reg [1:0]  seen_cap    // 0 unknown, 1 8K, 2 32K, 3 64K
);

	localparam [2:0] T_EEP64 = 3'd1, T_EEP8 = 3'd2,
	                 T_FL512 = 3'd3, T_FL1M = 3'd4, T_FRAM = 3'd5;

	localparam [7:0] SIG0 = 8'h5A, SIG1 = 8'hC3;

	//------------------------------------------------------------------
	// byte engine — one command, its address bytes, then N data bytes
	//------------------------------------------------------------------
	localparam [2:0] E_IDLE = 3'd0, E_SLOT = 3'd1, E_WAIT = 3'd2,
	                 E_END = 3'd3, E_DONE = 3'd4;
	localparam [1:0] P_CMD = 2'd0, P_ADDR = 2'd1, P_DATA = 2'd2;

	reg  [2:0]  es = E_IDLE;
	reg  [1:0]  ep = P_CMD;
	reg  [2:0]  acnt = 3'd0;
	reg  [2:0]  dcnt = 3'd0;
	reg  [7:0]  tx = 8'hFF;
	reg  [1:0]  dly = 2'd0;
	reg         got = 1'b0;
	reg         eng_done = 1'b0;

	reg         go = 1'b0;
	reg  [7:0]  op_cmd = 8'hFF;
	reg  [23:0] op_addr = 24'd0;
	reg  [2:0]  op_naddr = 3'd0;
	reg  [2:0]  op_count = 3'd0;
	reg         op_wr = 1'b0;
	reg  [7:0]  op_w0 = 8'hFF;
	reg  [7:0]  op_w1 = 8'hFF;

	reg  [7:0]  rx = 8'hFF;
	reg         rx_v = 1'b0;
	reg  [2:0]  rx_i = 3'd0;
	reg  [1:0]  ep_s = P_CMD;      // phase the answering byte belonged to

	// address byte for the byte about to be sent, and for the one after it
	// (the second is what goes on the wire when the count is decremented)
	reg [7:0] addr_byte, next_byte;
	always @(*) begin
		case (acnt)
		3'd3:    addr_byte = op_addr[23:16];
		3'd2:    addr_byte = op_addr[15:8];
		default: addr_byte = op_addr[7:0];
		endcase
		case (acnt)
		3'd3:    next_byte = op_addr[15:8];
		default: next_byte = op_addr[7:0];
		endcase
	end

	always @(posedge clk) begin
		slot     <= 1'b0;
		rx_v     <= 1'b0;
		eng_done <= 1'b0;

		case (es)
		E_IDLE: begin
			cs_n <= 1'b1;
			if (go) begin
				cs_n  <= 1'b0;
				ep    <= P_CMD;
				acnt  <= op_naddr;
				dcnt  <= op_count;
				rx_i  <= 3'd0;
				tx    <= op_cmd;
				es    <= E_SLOT;
			end
		end
		E_SLOT: begin
			din    <= tx;
			slot   <= 1'b1;
			ep_s   <= ep;
			dly    <= 2'd3;
			got    <= 1'b0;
			es     <= E_WAIT;
		end
		E_WAIT: begin
			// the answer lands two cycles after the slot; four cycles of
			// slot spacing keep the chip's read prefetch ahead of us
			if (resp) begin
				rx   <= dout;
				rx_v <= (ep_s == P_DATA);
				got  <= 1'b1;
			end
			if (dly != 2'd0) dly <= dly - 2'd1;

			if (got && dly == 2'd0) begin
				case (ep)
				P_CMD: begin
					if (acnt != 3'd0) begin
						ep <= P_ADDR;
						tx <= addr_byte;
						es <= E_SLOT;
					end else if (dcnt != 3'd0) begin
						ep <= P_DATA;
						tx <= op_wr ? op_w0 : 8'h00;
						es <= E_SLOT;
					end else begin
						es <= E_END;
					end
				end
				P_ADDR: begin
					if (acnt > 3'd1) begin
						acnt <= acnt - 3'd1;
						tx   <= next_byte;
						es   <= E_SLOT;
					end else if (dcnt != 3'd0) begin
						acnt <= 3'd0;
						ep   <= P_DATA;
						tx   <= op_wr ? op_w0 : 8'h00;
						es   <= E_SLOT;
					end else begin
						es <= E_END;
					end
				end
				default: begin
					if (dcnt > 3'd1) begin
						dcnt <= dcnt - 3'd1;
						rx_i <= rx_i + 3'd1;
						tx   <= op_wr ? ((rx_i == 3'd0) ? op_w1 : 8'hFF) : 8'h00;
						es   <= E_SLOT;
					end else begin
						es <= E_END;
					end
				end
				endcase
			end
		end
		E_END: begin
			cs_n <= 1'b1;
			es   <= E_DONE;
		end
		E_DONE: begin
			eng_done <= 1'b1;
			es       <= E_IDLE;
		end
		default: es <= E_IDLE;
		endcase

		if (reset) begin
			es       <= E_IDLE;
			cs_n     <= 1'b1;
			slot     <= 1'b0;
			eng_done <= 1'b0;
			rx_v     <= 1'b0;
			dly      <= 2'd0;
			got      <= 1'b0;
		end
	end

	//------------------------------------------------------------------
	// script — the GBATEK sequence, one engine operation per step
	//------------------------------------------------------------------
	localparam [3:0] S_IDLE = 4'd0, S_ISSUE = 4'd1, S_WAIT = 4'd2;
	localparam [3:0]
		P_RDSR  = 4'd1, P_RDID = 4'd2, P_RD0 = 4'd3, P_WREN = 4'd4,
		P_WR0   = 4'd5, P_POLL = 4'd6, P_RD8K = 4'd7, P_RD32K = 4'd8,
		P_WREN2 = 4'd9, P_REST = 4'd10, P_POLL2 = 4'd11, P_SETTLE = 4'd12;

	reg  [3:0]  ps = S_IDLE;
	reg  [3:0]  step = P_RDSR;
	reg  [1:0]  bc = 2'd0;        // bytes captured in this step
	reg  [7:0]  b0 = 8'hFF, b1 = 8'hFF;
	reg  [7:0]  id0 = 8'hFF, id1 = 8'hFF, id2 = 8'hFF, id3 = 8'hFF;
	reg  [7:0]  orig0 = 8'hFF, orig1 = 8'hFF;
	reg  [11:0] poll = 12'd0;
	reg         wip_seen = 1'b0;

	// classification, once the measurements are in
	reg [2:0]   verdict;
	always @(*) begin
		if (seen_status == 8'hFF)                    verdict = 3'd0; // open bus
		else if (seen_status[7:4] == 4'hF)           verdict = 3'd0; // 8+1-bit, unmodelled
		else if (id2 != 8'hFF) begin                                  // FLASH
			if      (id2 == 8'h13)                   verdict = T_FL512;
			else if (id2 == 8'h14)                   verdict = T_FL1M;
			else                                     verdict = 3'd0;
		end else begin
			if      (seen_cap == 2'd1)               verdict = wip_seen ? T_EEP8 : 3'd0;
			else if (seen_cap == 2'd2)               verdict = wip_seen ? 3'd0 : T_FRAM;
			else if (seen_cap == 2'd3)               verdict = wip_seen ? T_EEP64 : 3'd0;
			else                                     verdict = 3'd0;
		end
	end

	always @(posedge clk) begin
		go   <= 1'b0;
		done <= 1'b0;

		// capture the data bytes the engine answers with
		if (rx_v) begin
			if (bc == 2'd0) b0 <= rx;
			else            b1 <= rx;
			bc <= bc + 2'd1;
			case (step)
			P_RDID: begin
				case (bc)
				2'd0: id0 <= rx;
				2'd1: id1 <= rx;
				2'd2: id2 <= rx;
				default: id3 <= rx;
				endcase
			end
			P_POLL, P_POLL2: seen_status <= rx;
			default: ;
			endcase
		end

		case (ps)
		S_IDLE: begin
			if (start) begin
				step      <= P_RDSR;
				bc        <= 2'd0;
				seen_cap  <= 2'd0;
				wip_seen  <= 1'b0;
				seen_id   <= 32'hFFFF_FFFF;
				seen_status <= 8'hFF;
				b0        <= 8'hFF;
				b1        <= 8'hFF;
				id0       <= 8'hFF;
				id1       <= 8'hFF;
				id2       <= 8'hFF;
				id3       <= 8'hFF;
				ps        <= S_ISSUE;
			end
		end

		S_ISSUE: begin
			op_wr <= 1'b0;
			op_naddr <= 3'd0;
			op_count <= 3'd0;
			op_addr <= 24'd0;
			case (step)
			P_RDSR: begin
				op_cmd   <= 8'h05;
				op_count <= 3'd1;
				ps <= S_WAIT;
			end
			P_RDID: begin
				op_cmd   <= 8'h9F;
				op_count <= 3'd4;
				ps <= S_WAIT;
			end
			P_RD0: begin
				op_cmd   <= 8'h03;
				op_naddr <= 3'd2;
				op_count <= 3'd2;
				ps <= S_WAIT;
			end
			P_WREN, P_WREN2: begin
				op_cmd <= 8'h06;
				ps <= S_WAIT;
			end
			P_WR0: begin
				op_cmd   <= 8'h02;
				op_wr    <= 1'b1;
				op_naddr <= 3'd2;
				op_count <= 3'd2;
				op_w0    <= SIG0;
				op_w1    <= SIG1;
				ps <= S_WAIT;
			end
			P_REST: begin
				op_cmd   <= 8'h02;
				op_wr    <= 1'b1;
				op_naddr <= 3'd2;
				op_count <= 3'd2;
				op_w0    <= orig0;
				op_w1    <= orig1;
				ps <= S_WAIT;
			end
			P_POLL, P_POLL2: begin
				op_cmd   <= 8'h05;
				op_count <= 3'd1;
				ps <= S_WAIT;
			end
			P_RD8K: begin
				op_cmd   <= 8'h03;
				op_addr  <= 24'h002000;
				op_naddr <= 3'd2;
				op_count <= 3'd2;
				ps <= S_WAIT;
			end
			P_RD32K: begin
				op_cmd   <= 8'h03;
				op_addr  <= 24'h008000;
				op_naddr <= 3'd2;
				op_count <= 3'd2;
				ps <= S_WAIT;
			end
			default: begin
				ps <= S_WAIT;
			end
			endcase
			go <= 1'b1;
			bc <= 2'd0;
			ps <= S_WAIT;
		end

		S_WAIT: begin
			if (eng_done) begin
				ps <= S_ISSUE;
				case (step)
				P_RDSR: begin
					seen_status <= b0;
					if (b0 == 8'hFF)                 step <= P_SETTLE; // no chip
					else if (b0[7:4] == 4'hF)        step <= P_SETTLE; // 8+1-bit
					else                             step <= P_RDID;
				end
				P_RDID: begin
					seen_id <= {id0, id1, id2, id3};
					if (id2 != 8'hFF)                step <= P_SETTLE; // FLASH: ID is the size
					else                             step <= P_RD0;
				end
				P_RD0: begin
					orig0 <= b0;
					orig1 <= b1;
					step  <= P_WREN;
				end
				P_WREN:  step <= P_WR0;
				P_WR0: begin
					poll <= 12'd0;
					step <= P_POLL;
				end
				P_POLL: begin
					if (b0[0]) begin                 // still programming
						wip_seen <= 1'b1;
						if (poll == 12'd2047) step <= P_RD8K;
						else begin
							poll <= poll + 12'd1;
							step <= P_POLL;
						end
					end else begin
						step <= P_RD8K;
					end
				end
				P_RD8K: begin
					if (b0 == SIG0 && b1 == SIG1) seen_cap <= 2'd1;
					step <= (b0 == SIG0 && b1 == SIG1) ? P_WREN2 : P_RD32K;
				end
				P_RD32K: begin
					if (b0 == SIG0 && b1 == SIG1) seen_cap <= 2'd2;
					else                          seen_cap <= 2'd3;
					step <= P_WREN2;
				end
				P_WREN2: step <= P_REST;
				P_REST: begin
					poll <= 12'd0;
					step <= P_POLL2;
				end
				P_POLL2: begin
					if (b0[0] && poll != 12'd2047) begin
						poll <= poll + 12'd1;
						step <= P_POLL2;
					end else begin
						step <= P_SETTLE;
					end
				end
				default: begin                       // P_SETTLE
					det_type <= verdict;
					valid <= 1'b1;
					done  <= 1'b1;
					step  <= P_RDSR;
					ps    <= S_IDLE;
				end
				endcase
			end
		end

		default: ps <= S_IDLE;
		endcase

		if (reset) begin
			ps       <= S_IDLE;
			step     <= P_RDSR;
			go       <= 1'b0;
			done     <= 1'b0;
			bc       <= 2'd0;
			valid    <= 1'b0;
			seen_cap <= 2'd0;
			wip_seen <= 1'b0;
			poll     <= 12'd0;
			seen_id  <= 32'hFFFF_FFFF;
		end
	end


endmodule
