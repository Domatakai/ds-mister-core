//============================================================================
// NDS MiSTer Test — SPI bus (SPICNT/SPIDATA at 40001C0h/40001C2h)
//
// The ARM7 reaches three devices over one 8-bit SPI bus, selected by
// SPICNT[9:8] (GBATEK, *DS Serial Peripheral Interface Bus*):
//
//   0  power management (Mitsumi)   1  firmware serial flash   2  touchscreen
//
// SPICNT: 0-1 baud, 7 busy, 8-9 device, 10 transfer size, 11 chipselect hold,
// 14 IRQ enable, 15 enable. Writing SPIDATA starts a transfer, MSB first; the
// received byte appears in SPIDATA when busy drops.
//
// Replies are prepared a byte at a time, which is how the parts behave: the
// firmware's ID stream and the touchscreen's conversion both begin with the
// byte *after* their command. The touchscreen's reply is 13 bits (dummy bit
// plus a 12-bit result), so it is generated a bit at a time; the flash and the
// power device answer whole bytes.
//
// **Firmware flash — HLE.**  Games reach the DS firmware here for the user
// settings that follow the cartridge (nickname, alarm, touch calibration,
// language). Rather than carry the owner's 256 KB dump, the two
// user-settings blocks at 0x3FE00/0x3FF00 are synthesised by `fw_default`
// (GBATEK's layout, with valid CRC16s) and writes are shadowed in a 512-byte
// RAM. `lang` — the OSD "Language" row — selects the language halfword and the
// CRC that protects it, which is how a game's text language is chosen. Reads
// anywhere else return FFh, as an erased part does, and the command
// set is the part's: RDID, RDSR, READ, FASTREAD, WREN, WRDI, PP, PW, PE, SE,
// DP, RDP. Erases walk the shadow a byte per clock, so the WIP bit is real.
//
// **Touchscreen — TSC2046.**  Command byte MSB first: start bit 7, channel
// 4-6, 8/12-bit, single/differential. X/Y come from input_mapper's stylus
// position through the same calibration the synthesised firmware advertises, so
// a game's readback and its calibration agree; a released panel reports 000h
// for X and FFFh for Y, per GBATEK.
//
// **Power management.**  Index byte (bit 7 = direction) then a data byte:
// register 0 (amplifiers, backlights, LEDs), 1 (battery status), 2-3
// (microphone amplifier and gain), 4 (brightness/power source on DS-Lite).
//
// The transfer takes one clock per bit, so busy is set for eight (or sixteen)
// clocks; a game polling busy sees it finish well inside its budget.
//============================================================================
module nds_spi (
	input             clk,
	input             reset,

	// 40001C0h / 40001C2h, ARM7 only
	input             acc,
	input             we,
	input      [15:0] addr,
	input      [15:0] wdata,
	output reg [15:0] rdata,

	// OSD "Language" row: the language the synthesised settings report
	input      [2:0]  lang,

	// stylus / microphone state
	input      [8:0]  touch_x,
	input      [7:0]  touch_y,
	input             touch_down,
	input             mic_in,

	output            irq
);

	reg [15:0] cnt  = 16'h0000;
	reg [7:0]  data = 8'h00;

	wire hit_cnt  = (addr == 16'h01C0);
	wire hit_data = (addr == 16'h01C2);

	//------------------------------------------------------------------
	// firmware image (HLE): two user-settings blocks
	//------------------------------------------------------------------
	localparam FW_CMD = 2'd0, FW_ADDR = 2'd1, FW_DATA = 2'd2;
	localparam FW_NONE = 3'd0, FW_ID = 3'd1, FW_STATUS = 3'd2,
	           FW_READ = 3'd3, FW_PROG = 3'd4, FW_ERASE = 3'd5;

	reg  [7:0]   fw_ram [0:511];
	reg  [511:0] fw_written = 512'd0;

	reg  [17:0]  fw_ptr   = 18'd0;
	reg  [2:0]   fw_mode  = FW_NONE;
	reg  [1:0]   fw_phase = FW_CMD;
	reg  [2:0]   fw_abytes = 3'd0;
	reg  [1:0]   fw_idpos = 2'd0;
	reg          fw_wel   = 1'b0;
	reg          fw_wip   = 1'b0;
	reg          fw_dummy = 1'b0;
	// a program byte is handed to the array's one write port a cycle later
	// (the task cannot write it directly: the erase walk writes the same array
	// from a different address, and two write addresses cannot share a block
	// RAM's single write port)
	reg          fw_prog_we   = 1'b0;
	reg  [8:0]   fw_prog_addr = 9'd0;
	reg  [7:0]   fw_prog_byte = 8'hFF;
	reg  [8:0]   eras_addr = 9'd0;   // shadow index being erased
	reg  [8:0]   eras_last = 9'd0;   // last index of the erase window
	reg          eras_go   = 1'b0;
	reg  [6:0]   prog_wait = 7'd0;

	wire [8:0]  fw_idx    = fw_ptr[8:0];
	wire        fw_inwin  = (fw_ptr[17:9] == 9'h1FF);   // 3FE00h..3FFFFh
	wire [7:0]  fw_default_d;

	// The shadow is a RAM, so its read is registered: fw_ram_q is the byte at
	// fw_idx one cycle after the pointer moved. The window flag and the default
	// image are registered alongside it, so all three describe the same address
	// when fw_byte is muxed, and `prep_d` moves the reply one cycle on to meet
	// them. Before this the read was combinational, which kept the 512 bytes in
	// 4,096 flip-flops instead of one 10 Kb block.
	reg  [8:0]  fw_idx_d   = 9'd0;
	reg         fw_inwin_d = 1'b0;
	reg  [7:0]  fw_ram_q   = 8'hFF;
	reg         prep_d     = 1'b0;   // prep, one cycle on

	always @(posedge clk) begin
		fw_idx_d   <= fw_idx;
		fw_inwin_d <= fw_inwin;
		fw_ram_q   <= fw_ram[fw_idx];
	end

	fw_default u_fwdef (.addr(fw_idx_d), .lang(lang), .d(fw_default_d));

	wire [7:0] fw_byte = !fw_inwin_d           ? 8'hFF :
	                     fw_written[fw_idx_d] ? fw_ram_q : fw_default_d;

	wire [7:0] fw_status = {6'd0, fw_wel, fw_wip};

	reg  [7:0] fw_cur = 8'hFF;   // fw_byte, one cycle settled

	// JEDEC ID of the ST part the DS carries (M45PE20, 256 KB)
	function [7:0] fw_idbyte(input [1:0] i);
		case (i)
		2'd0: fw_idbyte = 8'h20;
		2'd1: fw_idbyte = 8'h40;
		default: fw_idbyte = 8'h12;
		endcase
	endfunction

	// The byte this device would put on the line next.
	//
	// Its inputs are passed in rather than read from the registers directly: a
	// zero-argument function that reads module state and is called on the right
	// of a nonblocking assignment crashes Quartus 17.0's Verific elaborator
	// ("Internal Error: Sub-system: VRFX ... verivalue_elab.cpp", on an
	// assertion about case widths — nothing to do with this function's logic,
	// which synthesizes fine once the call is given arguments). The behaviour
	// is identical: the arguments are the same register values the function
	// used to read, and the call site samples them exactly as it did before.
	function [7:0] fw_reply(
		input [1:0] phase,
		input [2:0] mode,
		input [1:0] idpos,
		input       dummy,
		input [7:0] dbyte,
		input [7:0] status
	);
		begin
			fw_reply = 8'h00;
			if (phase == FW_DATA) begin
				case (mode)
				FW_ID:     fw_reply = fw_idbyte(idpos);
				FW_STATUS: fw_reply = status;
				FW_READ:   fw_reply = dummy ? 8'h00 : dbyte;
				default:   fw_reply = 8'h00;
				endcase
			end
		end
	endfunction

	//------------------------------------------------------------------
	// power management
	//------------------------------------------------------------------
	reg [7:0] pm_reg0 = 8'h0F;   // amplifiers on, both backlights on
	reg [7:0] pm_reg1 = 8'h00;   // battery good
	reg [7:0] pm_reg2 = 8'h00;   // microphone amplifier off
	reg [7:0] pm_reg3 = 8'h00;   // microphone gain
	reg [7:0] pm_reg4 = 8'h43;   // DS-Lite: max brightness, no external power
	reg [3:0] pm_index = 4'd0;
	reg       pm_first = 1'b1;   // the next byte is the index register
	reg       pm_dir   = 1'b0;

	// the reply byte as a combinational mux rather than a function: the front
	// end does not credit a function's read of pm_reg*, and reports every one
	// of them as 10036. Same netlist either way (4765 registers).
	// (a continuous assignment, not an always block: this must answer on the
	// first read after reset, before any input has moved)
	wire [7:0] pm_byte = (pm_index == 4'd0) ? pm_reg0 :
	                     (pm_index == 4'd1) ? pm_reg1 :
	                     (pm_index == 4'd2) ? pm_reg2 :
	                     (pm_index == 4'd3) ? pm_reg3 :
	                     (pm_index == 4'd4) ? pm_reg4 : 8'h00;

	//------------------------------------------------------------------
	// touchscreen
	//------------------------------------------------------------------
	wire [11:0] x_adc = touch_down ? (12'h100 + ({3'd0, touch_x} * 12'd14)) : 12'h000;
	wire [11:0] y_adc = touch_down ? (12'h100 + ({4'd0, touch_y} * 12'd14)) : 12'hFFF;
	wire [11:0] aux_adc = mic_in ? 12'hC00 : 12'h400;

	reg [2:0]  ts_ch  = 3'd0;

	// the selected channel's word, read as a mux for the same reason as
	// pm_byte above (x_adc / y_adc / aux_adc were 10036 as function reads)
	wire [11:0] ts_word = (ts_ch == 3'd1) ? y_adc :
	                      (ts_ch == 3'd5) ? x_adc :
	                      (ts_ch == 3'd2) ? 12'h000 :                        // battery sensor, GNDed
	                      (ts_ch == 3'd3) ? (touch_down ? 12'hE00 : 12'hFFF) : // Z1
	                      (ts_ch == 3'd4) ? (touch_down ? 12'h100 : 12'hFFF) : // Z2
	                      (ts_ch == 3'd6) ? aux_adc :                        // microphone
	                      12'h800;                                           // temperature

	//------------------------------------------------------------------
	// transfer engine
	//------------------------------------------------------------------
	localparam D_POWER = 2'd0, D_FW = 2'd1, D_TSC = 2'd2;

	reg [1:0]  dev    = D_FW;
	reg        busy   = 1'b0;
	reg [3:0]  nbits  = 4'd0;     // bits left in this transfer
	reg [3:0]  bitcnt = 4'd0;     // bit within the current byte
	reg [15:0] tx     = 16'h0000;   // MISO: what the device sends
	reg [7:0]  mosi   = 8'h00;      // the byte the master is sending
	reg [7:0]  rx     = 8'h00;      // byte being assembled from MISO (the device)
	reg [7:0]  rxm    = 8'h00;      // byte being assembled from MOSI (the master)

	wire [7:0] rx_full   = {rx[6:0],  tx[15]};   // received byte, last bit included
	wire [7:0] mosi_full = {rxm[6:0], mosi[7]};  // sent byte, last bit included
	reg        irq_r  = 1'b0;
	reg        prep   = 1'b0;    // the device has a reply to latch
	reg        start_pend = 1'b0;
	reg [7:0]  pend_byte = 8'h00;
	reg        ts_cmd  = 1'b1;   // the byte just received was a TSC command

	// Hand one received byte to the selected device.
	//
	// Everything this task touches is a register in the one clocked block
	// below, so every assignment here is nonblocking too: mixing `=` and `<=`
	// on the same net is not allowed (Quartus Error 10110) because the two
	// forms have different intra-cycle visibility, and a design whose
	// behaviour depends on which one a net was written with is not one any
	// simulator and the fitter agree on. The one place that needs the *new*
	// value of something it is writing — the address shift feeding the erase
	// window — reads the shifted bit directly instead (see FW_ADDR).
	task dev_rx;
		input [7:0] b;
		begin
			case (dev)
			D_FW: begin
				if (fw_phase == FW_CMD) begin
					case (b)
					8'h9F: begin fw_mode <= FW_ID; fw_phase <= FW_DATA; fw_idpos <= 2'd0; end
					8'h05: begin fw_mode <= FW_STATUS; fw_phase <= FW_DATA; end
					8'h03: begin fw_mode <= FW_READ; fw_phase <= FW_ADDR; fw_abytes <= 3'd3;
					             fw_ptr <= 18'd0; fw_dummy <= 1'b0; end
					8'h0B: begin fw_mode <= FW_READ; fw_phase <= FW_ADDR; fw_abytes <= 3'd3;
					             fw_ptr <= 18'd0; fw_dummy <= 1'b1; end
					8'h06: begin fw_wel <= 1'b1; fw_mode <= FW_NONE; end
					8'h04: begin fw_wel <= 1'b0; fw_mode <= FW_NONE; end
					8'h02, 8'h0A: begin fw_mode <= FW_PROG; fw_phase <= FW_ADDR;
					                    fw_abytes <= 3'd3; fw_ptr <= 18'd0; end
					8'hDB: begin fw_mode <= FW_ERASE; fw_phase <= FW_ADDR;
					             fw_abytes <= 3'd3; fw_ptr <= 18'd0; eras_last <= 9'd255; end
					8'hD8: begin fw_mode <= FW_ERASE; fw_phase <= FW_ADDR;
					             fw_abytes <= 3'd3; fw_ptr <= 18'd0; eras_last <= 9'd511; end
					8'hB9, 8'hAB: fw_mode <= FW_NONE;    // power down / release
					default: fw_mode <= FW_NONE;
					endcase
				end else if (fw_phase == FW_ADDR) begin
					// 18-bit pointer, one address byte in at the bottom per byte
					fw_ptr <= {fw_ptr[9:0], b};
					if (fw_abytes == 3'd1) begin
						fw_phase <= FW_DATA;
						if (fw_mode == FW_ERASE && fw_wel) begin
							// a page erase covers the 256-byte half the address
							// falls in; a sector erase covers the whole window.
							// The window is chosen from the low address byte that
							// has just shifted in — bit 8 of the new pointer, which
							// is bit 0 of the old one, since the shift is about to
							// land b at the bottom.
							if (eras_last == 9'd255) begin
								eras_addr <= {fw_ptr[0], 8'd0};
								eras_last <= {fw_ptr[0], 8'hFF};
							end else
								eras_addr <= 9'd0;
							eras_go <= 1'b1;
							fw_wip  <= 1'b1;
							fw_wel  <= 1'b0;
						end
					end else
						fw_abytes <= fw_abytes - 3'd1;
				end else begin
					// data phase
					if (fw_mode == FW_PROG) begin
						// page program only clears bits (1 -> 0)
						if (fw_wel && (fw_ptr[17:9] == 9'h1FF)) begin
							fw_prog_we   <= 1'b1;
							fw_prog_addr <= fw_ptr[8:0];
							fw_prog_byte <= fw_cur & b;
							fw_wip   <= 1'b1;
							prog_wait <= 7'd63;
						end
						fw_ptr <= fw_ptr + 18'd1;
					end else if (fw_mode == FW_READ) begin
						if (fw_dummy) fw_dummy <= 1'b0;
						else          fw_ptr   <= fw_ptr + 18'd1;
					end else if (fw_mode == FW_ID)
						fw_idpos <= fw_idpos + 2'd1;
				end
			end
			D_POWER: begin
				// byte 1 is the index register (bit 7 = direction), byte 2 is
				// the data (GBATEK: *DS Power Management Device*)
				if (pm_first) begin
					pm_index <= b[3:0];
					pm_dir   <= b[7];
					pm_first <= 1'b0;
				end else begin
					pm_first <= 1'b1;
					if (!pm_dir) begin
						case (pm_index)
						4'd0: pm_reg0 <= {1'b0, b[6:0]};
						4'd2: pm_reg2 <= {7'd0, b[0]};
						4'd3: pm_reg3 <= {6'd0, b[1:0]};
						4'd4: pm_reg4 <= {4'h4, b[3:0]};
						default: ;
						endcase
					end
				end
			end
			default: begin
				ts_cmd <= b[7];
				ts_ch  <= b[6:4];
			end
			endcase
		end
	endtask

	always @(posedge clk) begin
		if (reset) begin
			cnt  <= 16'h0000;
			data <= 8'h00;
			dev <= D_FW; busy <= 1'b0; nbits <= 4'd0; bitcnt <= 4'd0;
			tx <= 16'h0000; rx <= 8'h00; irq_r <= 1'b0;
			prep <= 1'b0; prep_d <= 1'b0;
			start_pend <= 1'b0; pend_byte <= 8'h00; ts_cmd <= 1'b0;
			fw_ptr <= 18'd0; fw_mode <= FW_NONE; fw_phase <= FW_CMD;
			fw_abytes <= 3'd0; fw_idpos <= 2'd0;
			fw_wel <= 1'b0; fw_wip <= 1'b0; fw_dummy <= 1'b0;
			eras_addr <= 9'd0; eras_last <= 9'd0; eras_go <= 1'b0;
			prog_wait <= 7'd0; mosi <= 8'h00;
			fw_prog_we <= 1'b0;
			pm_index <= 4'd0; pm_first <= 1'b1; pm_dir <= 1'b0;
			pm_reg0 <= 8'h0F; pm_reg1 <= 8'h00; pm_reg2 <= 8'h00;
			pm_reg3 <= 8'h00; pm_reg4 <= 8'h43;
		end else begin
			// ---- register writes ----
			if (acc && we) begin
				if (hit_cnt) begin
					cnt <= wdata;
					// clearing the hold bit releases the chip select
					if (cnt[11] && !wdata[11]) begin
						fw_phase <= FW_CMD; fw_mode <= FW_NONE;
						fw_abytes <= 3'd0; fw_dummy <= 1'b0; fw_idpos <= 2'd0;
						pm_first <= 1'b1; pm_index <= 4'd0;
						tx <= 16'h0000;
					end
					// changing device releases the chip select: that device's
					// transfer state starts over
					if (wdata[9:8] != cnt[9:8]) begin
						fw_phase <= FW_CMD; fw_mode <= FW_NONE;
						fw_abytes <= 3'd0; fw_dummy <= 1'b0; fw_idpos <= 2'd0;
						pm_index <= 4'd0;
						pm_first <= 1'b1;
						tx       <= 16'h0000;
					end
				end
				if (hit_data && !busy && cnt[15]) begin
					if (prep || prep_d) begin
						// the device reply for this byte is still being
						// prepared: start as soon as it lands
						start_pend <= 1'b1;
						pend_byte  <= wdata[7:0];
						dev        <= cnt[9:8];
					end else begin
						busy   <= 1'b1;
						nbits  <= cnt[10] ? 4'd15 : 4'd7;
						bitcnt <= 4'd0;
						rx     <= 8'h00;
						rxm    <= 8'h00;
						mosi   <= wdata[7:0];
						dev    <= cnt[9:8];
					end
				end
			end

			// ---- one bit per clock, MSB first ----
			if (busy) begin
				tx   <= {tx[14:0], 1'b0};
				mosi <= {mosi[6:0], 1'b0};
				rx   <= rx_full;
				rxm  <= mosi_full;

				if (bitcnt == 4'd7) begin
					bitcnt <= 4'd0;
					dev_rx(mosi_full);
					prep   <= 1'b1;
				end else
					bitcnt <= bitcnt + 4'd1;

				if (nbits == 4'd0) begin
					busy  <= 1'b0;
					data  <= rx_full;
					irq_r <= cnt[14];
					// a transfer with the hold bit clear deselects the part
					if (!cnt[11]) begin
						fw_phase <= FW_CMD; fw_mode <= FW_NONE;
						fw_abytes <= 3'd0; fw_dummy <= 1'b0; fw_idpos <= 2'd0;
						pm_first <= 1'b1; pm_index <= 4'd0;
					end
				end else
					nbits <= nbits - 4'd1;
		end else begin
			irq_r <= 1'b0;
			prep  <= 1'b0;
			if (prep_d) begin
					case (dev)
					D_FW:    tx <= {fw_reply(fw_phase, fw_mode, fw_idpos,
					                         fw_dummy, fw_byte, fw_status), 8'h00};
					D_POWER: tx <= {pm_byte, 8'h00};
					default: if (ts_cmd)
						tx <= {1'b0, ts_word, 3'b000};
					endcase
				end else if (start_pend) begin
					start_pend <= 1'b0;
					busy   <= 1'b1;
					nbits  <= cnt[10] ? 4'd15 : 4'd7;
					bitcnt <= 4'd0;
					rx     <= 8'h00;
					rxm    <= 8'h00;
					mosi   <= pend_byte;
				end
			end

			prep_d <= prep;     // the reply moves with the registered shadow read
			fw_cur <= fw_byte;

			// ---- the shadow's single write port ----
			// The erase walk and a program byte never coincide, so they share
			// one address/data mux here: two write sites with different
			// addresses are two write ports, and a 10 Kb block has one.
			if (eras_go) begin
				fw_ram[eras_addr]     <= 8'hFF;
				fw_written[eras_addr] <= 1'b1;
				if (eras_addr == eras_last) begin
					eras_go <= 1'b0;
					fw_wip  <= 1'b0;
				end
				eras_addr <= eras_addr + 9'd1;
			end else if (fw_prog_we) begin
				fw_ram[fw_prog_addr]     <= fw_prog_byte;
				fw_written[fw_prog_addr] <= 1'b1;
				fw_prog_we <= 1'b0;
			end

			// ---- program busy window ----
			if (prog_wait != 7'd0) begin
				prog_wait <= prog_wait - 7'd1;
				if (prog_wait == 7'd1) begin
					fw_wip <= 1'b0;
					fw_wel <= 1'b0;
				end
			end
		end
	end

	always @(*) begin
		rdata = 16'h0000;
		if (hit_cnt) begin
			rdata[1:0]   = cnt[1:0];
			rdata[7]     = busy;
			rdata[9:8]   = cnt[9:8];
			rdata[10]    = cnt[10];
			rdata[11]    = cnt[11];
			rdata[14]    = cnt[14];
			rdata[15]    = cnt[15];
		end
		if (hit_data) rdata = {8'h00, data};
	end

	assign irq = irq_r;

endmodule
