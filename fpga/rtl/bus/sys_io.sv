//============================================================================
// NDS MiSTer Test — system I/O: timers, IPC, maths, IRQ banks and HALT
//
// The block of registers both CPUs need before a game can run a single frame:
//
//   0x04000100..0x0400010F  four timers per CPU   (nds_timers, one per CPU)
//   0x04000180..0x04000188  IPC sync + FIFOs      (ipc.sv)
//   0x04000280..0x040002BF  ARM9 DIV / SQRT       (math_unit.sv)
//   0x04000138              RTC three-wire port   (nds_rtc.sv, ARM7)
//   0x040001C0/0x040001C2   SPI bus               (spi.sv, ARM7)
//   0x04000300              POSTFLG  (BIOS boot-complete flag, R/W)
//   0x04000301              HALTCNT  (bit 7 = power down)
//   0x04000208              IME      (per CPU)
//   0x04000210/0x04000212   IE       (per CPU)
//   0x04000214/0x04000216   IF       (per CPU, write-1-to-clear)
//   0x04100000              IPCFIFORECV (read the other CPU's FIFO)
//
// Every I/O access carries which CPU made it, because the DS keeps two of each
// of these: eight timers, two IRQ banks, two FIFO views. The register file is
// therefore addressed by `cpu9` as well as by address, which is the one
// structural difference from a single-CPU I/O block.
//
// Interrupt flags are the union of the device sources the caller passes in
// (DMA, keypad, cartridge) and the timers/IPC owned here. An IRQ is asserted
// when `IME && |(IE & IF)`, which is the GBATEK condition for both CPUs.
//============================================================================
module sys_io (
	input              clk,
	input              reset,
	input              tick,        // one ARM7 clock cycle: the timers count it
	input              tick33,      // free-running 33.513982 MHz reference, for
	                                // the RTC's one-second divider only

	// one access (the bus serves a single master at a time)
	input              cpu9,        // 1 = ARM9, 0 = ARM7
	input      [15:0]  addr,
	input              acc,         // access strobe (address is valid)
	input              we,          // write strobe
	input      [15:0]  wdata,       // halfword write data
	input      [31:0]  wdata32,     // full word (IPCFIFOSEND)
	output reg [15:0]  rdata,       // halfword read data

	// 0x04100000 is on its own 64 KB page, decoded by the bus
	input              recv_hit,
	output     [31:0]  recv_rdata,

	// stylus / microphone, for the SPI touchscreen channel
	input      [8:0]   touch_x,
	input      [7:0]   touch_y,
	input              touch_down,
	input              mic_in,

	// OSD "Language" row -> the firmware user settings on the SPI flash
	input      [2:0]   lang,

	// device IRQ pulses from the rest of the system (DMA, keypad, cart)
	input      [31:0]  irq_src9,
	input      [31:0]  irq_src7,

	output     [31:0]  ie9, if9,
	output             ime9, irq9,
	output     [31:0]  ie7, if7,
	output             ime7, irq7,
	output             arm7_halt
);

	//------------------------------------------------------------------
	// decode
	//------------------------------------------------------------------
	wire hit_tmr  = (addr[15:4] == 12'h010);
	wire hit_ipc  = (addr == 16'h0180) || (addr == 16'h0184) || (addr == 16'h0188);
	wire hit_math = (addr >= 16'h0280) && (addr <= 16'h02BF);
	wire hit_irq  = (addr == 16'h0208) ||
	                (addr >= 16'h0210 && addr <= 16'h0217);
	wire hit_halt = (addr == 16'h0300) || (addr == 16'h0301);
	wire hit_rtc  = (addr == 16'h0138);                        // ARM7 only
	wire hit_spi  = (addr == 16'h01C0) || (addr == 16'h01C2);  // ARM7 only

	wire [2:0] ipc_sel = (addr == 16'h0180) ? 3'd0 :
	                     (addr == 16'h0184) ? 3'd1 :
	                     (addr == 16'h0188) ? 3'd2 : 3'd3;

//------------------------------------------------------------------
// timers: one four-timer set per CPU, addressed by the same offsets
//
// Both sets are ticked by `tick`, the ARM7's own clock enable: GBATEK gives
// F = 33.513982 MHz for both NDS9 and NDS7 -- the timers are a divider of the
// clock the ARM7 runs on, not an independent timebase -- so a timer counts
// ARM7 cycles whichever CPU programs it. The ARM9 therefore sees two ticks
// per own cycle, which is the DS's own ratio.
//------------------------------------------------------------------
	wire [15:0] tmr_rd9, tmr_rd7;
	wire [3:0]  tmr_irq9, tmr_irq7;

	nds_timers u_tmr9 (
		.clk(clk), .reset(reset), .tick(tick),
		.reg_off(addr[3:0]), .we(acc && we && hit_tmr && cpu9),
		.wdata(wdata), .rdata(tmr_rd9), .irq(tmr_irq9)
	);

	nds_timers u_tmr7 (
		.clk(clk), .reset(reset), .tick(tick),
		.reg_off(addr[3:0]), .we(acc && we && hit_tmr && !cpu9),
		.wdata(wdata), .rdata(tmr_rd7), .irq(tmr_irq7)
	);

	//------------------------------------------------------------------
	// IPC
	//------------------------------------------------------------------
	wire [31:0] ipc_rd;
	wire ipc_sync9, ipc_send9, ipc_recv9;
	wire ipc_sync7, ipc_send7, ipc_recv7;

	ipc u_ipc (
		.clk(clk), .reset(reset),
		.cpu9(cpu9), .sel(ipc_sel),
		.we(acc && we && (hit_ipc && ipc_sel != 3'd3)),
		.re(acc && !we && (recv_hit || (hit_ipc && ipc_sel == 3'd3))),
		.wdata((ipc_sel == 3'd2) ? wdata32 : {16'h0000, wdata}),
		.rdata(ipc_rd),
		.irq_sync9(ipc_sync9), .irq_send9(ipc_send9), .irq_recv9(ipc_recv9),
		.irq_sync7(ipc_sync7), .irq_send7(ipc_send7), .irq_recv7(ipc_recv7)
	);

	assign recv_rdata = ipc_rd;

	//------------------------------------------------------------------
	// maths coprocessor (ARM9 only; the ARM7 sees zeros)
	//------------------------------------------------------------------
	wire [15:0] math_rd;

	math_unit u_math (
		.clk(clk), .reset(reset),
		.addr(addr[7:0]), .we(acc && we && hit_math && cpu9),
		.wdata(wdata), .rdata(math_rd), .busy()
	);

	//------------------------------------------------------------------
	// real-time clock (4000138h) and SPI bus (40001C0h/40001C2h)
	//------------------------------------------------------------------
	// One second for the RTC out of its own crystal, by way of the free-running
	// 33.5137 MHz reference -- deliberately *not* the timer tick: the ARM7 may
	// be overclocked from the OSD without the clock chip losing time. 33,513,700
	// reference ticks is the second (the DS's ARM7 clock, which is clk_sys/2).
	reg  [25:0] rtc_div = 26'd0;
	reg         rtc_sec = 1'b0;

	always @(posedge clk) begin
		rtc_sec <= 1'b0;
		if (tick33) begin
			if (rtc_div == 26'd33_513_699) begin
				rtc_div <= 26'd0;
				rtc_sec <= 1'b1;
			end else
				rtc_div <= rtc_div + 26'd1;
		end
	end

	wire [15:0] rtc_rd, spi_rd;
	wire        rtc_irq, spi_irq;

	nds_rtc u_rtc (
		.clk(clk), .reset(reset), .sec_tick(rtc_sec),
		.wr(acc && we && hit_rtc && !cpu9 && !reset),
		.wdata(wdata), .rdata(rtc_rd), .irq(rtc_irq)
	);

	nds_spi u_spi (
		.clk(clk), .reset(reset),
		.acc(acc && hit_spi && !cpu9), .we(we),
		.addr(addr), .wdata(wdata), .rdata(spi_rd),
		.touch_x(touch_x), .touch_y(touch_y), .touch_down(touch_down),
		.mic_in(mic_in), .lang(lang), .irq(spi_irq)
	);

	//------------------------------------------------------------------
	// IRQ banks
	//------------------------------------------------------------------
	reg [31:0] ie_r9 = 32'd0, ie_r7 = 32'd0;
	reg [31:0] if_r9 = 32'd0, if_r7 = 32'd0;
	reg        ime_r9 = 1'b0, ime_r7 = 1'b0;

	assign ie9 = ie_r9;
	assign ie7 = ie_r7;
	assign if9 = if_r9;
	assign if7 = if_r7;
	assign ime9 = ime_r9;
	assign ime7 = ime_r7;
	assign irq9 = ime_r9 && ((ie_r9 & if_r9) != 32'd0);
	assign irq7 = ime_r7 && ((ie_r7 & if_r7) != 32'd0);

	// device sources per GBATEK's IE/IF bit list
	// IF bits: 0-3 timers, 7 SIO (the RTC's /INT lands here), 16 IPC sync,
	// 17 send FIFO empty, 18 receive FIFO not empty, 23 ARM7 SPI
	// FIFO not empty (GBATEK)
	wire [31:0] src9 = irq_src9 |
	                   {13'd0, ipc_recv9, ipc_send9, ipc_sync9, 12'd0, tmr_irq9};
	wire [31:0] src7 = irq_src7 |
	                   {8'd0, spi_irq, 4'd0, ipc_recv7, ipc_send7, ipc_sync7,
	                    8'd0, rtc_irq, 3'd0, tmr_irq7};

	//------------------------------------------------------------------
	// HALT / POSTFLG
	//------------------------------------------------------------------
	reg        postflg = 1'b0;
	reg        halt_req = 1'b0;
	wire       wake7 = ime_r7 && ((ie_r7 & if_r7) != 32'd0);

	assign arm7_halt = halt_req && !wake7;

	// write-1-to-clear is combined with this cycle's sources so a flag that
	// arrives in the same cycle as its acknowledgement is not lost
	wire        w1c_lo = acc && we && (addr == 16'h0214);
	wire        w1c_hi = acc && we && (addr == 16'h0216);
	wire [31:0] w1c    = {w1c_hi ? wdata : 16'h0000, w1c_lo ? wdata : 16'h0000};

	always @(posedge clk) begin
		if_r9 <= ((if_r9 & ~(cpu9 ? w1c : 32'd0)) | src9);
		if_r7 <= ((if_r7 & ~(cpu9 ? 32'd0 : w1c)) | src7);

		if (acc && we) begin
			if (hit_irq) begin
				case (addr)
				16'h0208: if (cpu9) ime_r9 <= wdata[0]; else ime_r7 <= wdata[0];
				16'h0210: if (cpu9) ie_r9[15:0]  <= wdata; else ie_r7[15:0]  <= wdata;
				16'h0212: if (cpu9) ie_r9[31:16] <= wdata; else ie_r7[31:16] <= wdata;
				default: ;
				endcase
			end
			if (hit_halt) begin
				if (addr == 16'h0300) postflg  <= wdata[0];
				else                  halt_req <= wdata[7];
			end
		end

		if (reset) begin
			ie_r9 <= 32'd0; ie_r7 <= 32'd0;
			if_r9 <= 32'd0; if_r7 <= 32'd0;
			ime_r9 <= 1'b0; ime_r7 <= 1'b0;
			postflg <= 1'b0;
			halt_req <= 1'b0;
		end
	end

	//------------------------------------------------------------------
	// read mux
	//------------------------------------------------------------------
	always @(*) begin
		rdata = 16'h0000;
		if (hit_rtc)       rdata = cpu9 ? 16'h0000 : rtc_rd;
		else if (hit_spi)  rdata = cpu9 ? 16'h0000 : spi_rd;
		else if (hit_tmr)  rdata = cpu9 ? tmr_rd9 : tmr_rd7;
		else if (hit_ipc)  rdata = ipc_rd[15:0];
		else if (hit_math) rdata = cpu9 ? math_rd : 16'h0000;
		else if (hit_halt) rdata = (addr == 16'h0300) ? {15'd0, postflg}
		                                             : {8'd0, 7'd0, halt_req};
		else if (hit_irq) begin
			case (addr)
			16'h0208: rdata = {15'd0, cpu9 ? ime_r9 : ime_r7};
			16'h0210: rdata = cpu9 ? ie_r9[15:0]  : ie_r7[15:0];
			16'h0212: rdata = cpu9 ? ie_r9[31:16] : ie_r7[31:16];
			16'h0214: rdata = cpu9 ? if_r9[15:0]  : if_r7[15:0];
			16'h0216: rdata = cpu9 ? if_r9[31:16] : if_r7[31:16];
			default: rdata = 16'h0000;
			endcase
		end
	end

endmodule
