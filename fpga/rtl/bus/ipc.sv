//============================================================================
// NDS MiSTer Test — IPC: synchronisation register and the two FIFOs
//
// GBATEK, *DS Inter Process Communication*:
//
//   IPCSYNC      0-3  data from the remote CPU's bits 8-11 (read only)
//                8-11 data to the remote CPU's bits 0-3 (read/write)
//                13   write 1 to send an IRQ to the remote CPU
//                14   enable the IRQ from the remote CPU
//   IPCFIFOCNT   0    send FIFO empty   1 send FIFO full
//                2    send FIFO empty IRQ enable
//                3    write 1 to flush the send FIFO
//                8    receive FIFO empty  9 receive FIFO full
//                10   receive FIFO not-empty IRQ enable
//                14   error (read from empty / write to full), ack by writing 0
//                15   enable both FIFOs
//   IPCFIFOSEND  0x04000188  32-bit write, 16-word FIFO
//   IPCFIFORECV  0x04100000  32-bit read, the other CPU's FIFO
//
// The IRQs are the ones GBATEK specifies: IF.16 on a remote send-IRQ (gated by
// this CPU's own enable bit), IF.17 when "IRQ enabled and send FIFO empty"
// goes 0-to-1, IF.18 when "IRQ enabled and receive FIFO not empty" goes
// 0-to-1. A disabled FIFO (bit 15 clear) still answers reads — without
// consuming — and ignores writes without raising the error bit.
//
// One port, one access per cycle: the bus serves a single master at a time, so
// a push and a pop never collide.
//============================================================================
module ipc (
	input              clk,
	input              reset,

	// one access from either CPU
	input              cpu9,        // 1 = ARM9, 0 = ARM7
	input      [2:0]   sel,         // 0 SYNC, 1 CNT, 2 SEND, 3 RECV
	input              we,          // write strobe for this access
	input              re,          // read strobe (IPCFIFORECV consumes)
	input      [31:0]  wdata,
	output reg [31:0]  rdata,

	// IRQ lines into each CPU's flag bank (IF.16, IF.17, IF.18)
	output reg         irq_sync9,  irq_send9,  irq_recv9,
	output reg         irq_sync7,  irq_send7,  irq_recv7
);

	//------------------------------------------------------------------
	// synchronisation register
	//------------------------------------------------------------------
	reg [3:0] out9 = 4'd0, out7 = 4'd0;   // each CPU's bits 8-11
	reg       en9  = 1'b0, en7  = 1'b0;   // each CPU's bit 14

	//------------------------------------------------------------------
	// FIFOs: one per direction, 16 words deep, oldest word first
	//------------------------------------------------------------------
	reg [31:0] fifo97 [0:15];      // ARM9 -> ARM7
	reg [31:0] fifo79 [0:15];      // ARM7 -> ARM9
	reg [4:0]  n97 = 5'd0, n79 = 5'd0;
	reg [3:0]  w97 = 4'd0, w79 = 4'd0;   // write pointers
	reg [3:0]  r97 = 4'd0, r79 = 4'd0;   // read pointers
	reg [31:0] last97 = 32'd0, last79 = 32'd0;

	reg en9_f = 1'b0, en7_f = 1'b0;      // IPCFIFOCNT.15 per CPU
	reg e9_flg = 1'b0, e7_flg = 1'b0;    // IPCFIFOCNT.14 error per CPU
	reg irqen_s9 = 1'b0, irqen_s7 = 1'b0; // bit 2
	reg irqen_r9 = 1'b0, irqen_r7 = 1'b0; // bit 10

	wire        own_en     = cpu9 ? en9_f : en7_f;
	// this CPU's send FIFO is the other CPU's receive FIFO
	wire [4:0]  send_n     = cpu9 ? n97 : n79;
	wire [4:0]  recv_n     = cpu9 ? n79 : n97;
	wire        send_empty = (send_n == 5'd0);
	wire        send_full  = (send_n == 5'd16);
	wire        recv_empty = (recv_n == 5'd0);
	wire        recv_full  = (recv_n == 5'd16);

	wire [15:0] cnt_rd = {
		1'b0,                                  // 15 enable
		cpu9 ? e9_flg : e7_flg,                // 14 error
		3'b000,                                // 13..11
		cpu9 ? irqen_r9 : irqen_r7,            // 10
		recv_full,                             // 9
		recv_empty,                            // 8
		4'b0000,                               // 7..4
		1'b0,                                  // 3 (write-only flush)
		cpu9 ? irqen_s9 : irqen_s7,            // 2
		send_full,                             // 1
		send_empty                             // 0
	};
	// bit 15 is the enable written by this CPU, not a read-only status
	wire [15:0] cnt_rd_en = (cnt_rd & 16'h7FFF) | {own_en, 15'd0};

	wire [15:0] sync_rd = {
		1'b0,                                  // 15
		cpu9 ? en9 : en7,                      // 14
		1'b0,                                  // 13 (write-only)
		1'b0,                                  // 12
		cpu9 ? out9 : out7,                    // 11..8 own output
		4'b0000,                               // 7..4
		cpu9 ? out7 : out9                     // 3..0 remote output
	};

	// pushes and pops, qualified by the per-CPU enable bit
	wire do_send  = we && (sel == 3'd2) && own_en && !send_full;
	wire do_recv  = re && (sel == 3'd3) && own_en && !recv_empty;
	wire do_flush = we && (sel == 3'd1) && wdata[3];
	wire sync_send = we && (sel == 3'd0) && wdata[13];

	// condition changes for the edge-triggered FIFO IRQs (GBATEK)
	wire irq_cond_s9 = irqen_s9 && (n97 == 5'd0);
	wire irq_cond_s7 = irqen_s7 && (n79 == 5'd0);
	wire irq_cond_r9 = irqen_r9 && (n79 != 5'd0);
	wire irq_cond_r7 = irqen_r7 && (n97 != 5'd0);

	reg cond_s9 = 1'b0, cond_s7 = 1'b0, cond_r9 = 1'b0, cond_r7 = 1'b0;

	always @(*) begin
		case (sel)
		3'd0:    rdata = {16'h0000, sync_rd};
		3'd1:    rdata = {16'h0000, cnt_rd_en};
		3'd3:    rdata = cpu9 ? (n79 == 5'd0 ? last79 : fifo79[r79])
		                      : (n97 == 5'd0 ? last97 : fifo97[r97]);
		default: rdata = 32'h0000_0000;
		endcase
	end

	always @(posedge clk) begin
		irq_sync9 <= 1'b0;
		irq_sync7 <= 1'b0;
		irq_send9 <= 1'b0;
		irq_send7 <= 1'b0;
		irq_recv9 <= 1'b0;
		irq_recv7 <= 1'b0;

		// ---- IPCSYNC ----
		if (we && (sel == 3'd0)) begin
			if (cpu9) begin
				out9 <= wdata[11:8];
				en9  <= wdata[14];
			end else begin
				out7 <= wdata[11:8];
				en7  <= wdata[14];
			end
			// a write to bit 13 interrupts the other CPU, if it listens
			if (sync_send) begin
				if (cpu9) irq_sync7 <= en7;
				else      irq_sync9 <= en9;
			end
		end

		// ---- IPCFIFOCNT ----
		if (we && (sel == 3'd1)) begin
			if (cpu9) begin
				en9_f    <= wdata[15];
				e9_flg   <= wdata[14];      // writing 0 acknowledges
				irqen_s9 <= wdata[2];
				irqen_r9 <= wdata[10];
			end else begin
				en7_f    <= wdata[15];
				e7_flg   <= wdata[14];
				irqen_s7 <= wdata[2];
				irqen_r7 <= wdata[10];
			end
			if (do_flush) begin
				if (cpu9) begin n97 <= 5'd0; w97 <= 4'd0; r97 <= 4'd0; end
				else      begin n79 <= 5'd0; w79 <= 4'd0; r79 <= 4'd0; end
			end
		end

		// ---- send / receive ----
		if (do_send) begin
			if (cpu9) begin
				fifo97[w97] <= wdata;
				w97 <= w97 + 4'd1;
				n97 <= n97 + 5'd1;
			end else begin
				fifo79[w79] <= wdata;
				w79 <= w79 + 4'd1;
				n79 <= n79 + 5'd1;
			end
		end else if (we && (sel == 3'd2) && send_full) begin
			// writing to a full FIFO is the documented error condition
			if (cpu9) e9_flg <= 1'b1;
			else      e7_flg <= 1'b1;
		end

		if (do_recv) begin
			if (cpu9) begin
				last79 <= fifo79[r79];
				r79 <= r79 + 4'd1;
				n79 <= n79 - 5'd1;
			end else begin
				last97 <= fifo97[r97];
				r97 <= r97 + 4'd1;
				n97 <= n97 - 5'd1;
			end
		end else if (re && (sel == 3'd3) && recv_empty) begin
			// reading an empty FIFO returns the last word (or zero) and
			// raises the error bit
			if (cpu9) e9_flg <= 1'b1;
			else      e7_flg <= 1'b1;
		end

		// ---- edge-triggered FIFO IRQs ----
		if (irq_cond_s9 && !cond_s9) irq_send9 <= 1'b1;
		if (irq_cond_s7 && !cond_s7) irq_send7 <= 1'b1;
		if (irq_cond_r9 && !cond_r9) irq_recv9 <= 1'b1;
		if (irq_cond_r7 && !cond_r7) irq_recv7 <= 1'b1;
		cond_s9 <= irq_cond_s9;
		cond_s7 <= irq_cond_s7;
		cond_r9 <= irq_cond_r9;
		cond_r7 <= irq_cond_r7;

		if (reset) begin
			out9 <= 4'd0; out7 <= 4'd0;
			en9  <= 1'b0; en7  <= 1'b0;
			n97  <= 5'd0; n79  <= 5'd0;
			w97  <= 4'd0; w79  <= 4'd0;
			r97  <= 4'd0; r79  <= 4'd0;
			last97 <= 32'd0; last79 <= 32'd0;
			en9_f  <= 1'b0; en7_f  <= 1'b0;
			e9_flg <= 1'b0; e7_flg <= 1'b0;
			irqen_s9 <= 1'b0; irqen_s7 <= 1'b0;
			irqen_r9 <= 1'b0; irqen_r7 <= 1'b0;
			cond_s9 <= 1'b0; cond_s7 <= 1'b0;
			cond_r9 <= 1'b0; cond_r7 <= 1'b0;
		end
	end

endmodule
