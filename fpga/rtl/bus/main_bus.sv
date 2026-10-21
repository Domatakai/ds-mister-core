//============================================================================
// NDS MiSTer Test — main bus interconnect
//
// Single-server round-robin fabric serving both CPU masters against the
// DS address map. Private regions (BIOS, WRAM, IO, palette, OAM) answer
// in one cycle; shared regions (main RAM via SDRAM, the cart window via
// DDR3) run a two-phase micro-sequence so every 32-bit access assembles
// both 16-bit halves — the DS bus is 16-bit wide.
//
// Map (physical, as seen by either CPU):
//   0x00000000..0x00003FFF  ARM7 BIOS (HLE: NOPs, dispatch in M1)
//   0x02000000..0x02FFFFFF  Main RAM 4 MB              -> SDRAM via arbiter
//   0x03000000..0x03007FFF  Shared WRAM 32 KB          -> BRAM
//   0x03800000..0x0380FFFF  ARM7 WRAM 64 KB            -> BRAM
//   0x04000000..0x040003FF  I/O registers              -> IO block below
//   0x05000000..0x050007FF  Palette 2 KB               -> BRAM
//   0x06000000..0x06FFFFF7  VRAM                       -> vram_arbiter (M2)
//   0x07000000..0x070007FF  OAM 2 KB                   -> BRAM
//   0x08000000..0x0FFFFFFF  Cart window                -> cart_slot (DDR3)
//   0xFFFF0000..0xFFFF3FFF  ARM9 BIOS mirror           -> HLE
//
// IO registers (GBATEK has the full list; M1 grows it):
//   0x000 DISPCNT_A  RW     0x1000 DISPCNT_B  RW
//   0x130 KEYINPUT    R  {4'hF, ~keys} (0 = Pressed, active low)
//   0x132 KEYCNT      RW     0x180 IPCSYNC  RW (stub)
//   0x204 EXMEMCNT    RW     0x208 IME RW  0x210 IE RW  0x214 IF W1C
//   0x240..0x248      VRAMCNT A..I -> vram_arbiter
//   0x300 POWCNT1     RW
//
// Cheat hook: every completed main-RAM read is offered to cheat_engine,
// which may substitute the value (GameShark codes loaded via F2).
//============================================================================
module main_bus (
	input            clk,
	input            reset,

	// input state from input_mapper
	input     [11:0] ds_keys,
	input      [8:0] touch_x,
	input      [7:0] touch_y,
	input            touch_down,
	input            mic_in,

	// ---- ARM9 master ----
	input     [31:0] m9_addr,
	input     [31:0] m9_wdata,
	input      [3:0] m9_be,
	input            m9_rd,
	input            m9_wr,
	output reg       m9_ready,
	output reg [31:0] m9_rdata,

	// ---- ARM7 master ----
	input     [31:0] m7_addr,
	input     [31:0] m7_wdata,
	input      [3:0] m7_be,
	input            m7_rd,
	input            m7_wr,
	output reg       m7_ready,
	output reg [31:0] m7_rdata,

	// ---- cart window (cart_slot read bridge) ----
	output reg       cart_req,
	output reg [25:0] cart_addr,
	input            cart_valid,
	input     [15:0] cart_rdata,

	// ---- shared SDRAM (mem_arbiter) ----
	output reg       ram_req,
	output reg       ram_wr,
	output reg [24:0] ram_addr,
	output reg [15:0] ram_wdata,
	output reg [1:0] ram_be,
	input            ram_done,
	input     [15:0] ram_rdata,

	// ---- VRAMCNT writes -> vram_arbiter ----
	output           vramcnt_we,
	output     [3:0] vramcnt_addr,
	output     [7:0] vramcnt_data,

	// ---- cheat hook ----
	output reg       cheat_chk_en,
	output reg [31:0] cheat_chk_addr,
	output reg [15:0] cheat_chk_data,
	input     [15:0] cheat_patch,
	input            cheat_hit,

	// ---- engine / system observations (M2 consumers) ----
	output reg [15:0] dispcnt_a,
	output reg [15:0] dispcnt_b,
	output reg        irq_master_enable,
	output reg [31:0] irq_enable,
	output reg [31:0] irq_flags
);

//------------------------------------------------------------------
// Memories
//------------------------------------------------------------------
reg [31:0] wram_shared [0:8191];   // 32 KB  @0x03000000
reg [31:0] wram_arm7   [0:16383];  // 64 KB  @0x03800000
reg [15:0] palette     [0:1023];   // 2 KB   @0x05000000
reg [15:0] oam         [0:1023];   // 2 KB   @0x07000000

//------------------------------------------------------------------
// IO registers
//------------------------------------------------------------------
reg [15:0] keycnt   = 0;
reg [15:0] ipcsync  = 0;
reg [15:0] exmemcnt = 0;
reg [15:0] powcnt1  = 0;
reg        vramcnt_we_r = 0;

assign vramcnt_we   = vramcnt_we_r;
assign vramcnt_addr = a[3:0];
assign vramcnt_data = wdata[7:0];

wire [15:0] io_addr  = a[15:0];
wire [15:0] keyinput = {4'hF, ~ds_keys}; // GBATEK: 0 = Pressed

//------------------------------------------------------------------
// Arbitration view of the granted master
//------------------------------------------------------------------
localparam S_IDLE  = 3'd0,
           S_PRIV  = 3'd1,
           S_REQ_A = 3'd2,
           S_WAIT_A= 3'd3,
           S_REQ_B = 3'd4,
           S_WAIT_B= 3'd5,
           S_RESP  = 3'd6;

reg [2:0]  state = S_IDLE;
reg        turn = 0;      // fairness: alternates when both request
reg        m9_active = 0;
reg        m7_active = 0;
reg        is_read = 0;
reg        need_b = 0;
reg [15:0] lo_half = 0;
reg [15:0] hi_half = 0;

wire m9_req = m9_rd | m9_wr;
wire m7_req = m7_rd | m7_wr;

wire        m_rd  = m9_active ? m9_rd  : m7_rd;
wire        m_wr  = m9_active ? m9_wr  : m7_wr;
wire [31:0] a     = m9_active ? m9_addr : m7_addr;
wire [31:0] wdata = m9_active ? m9_wdata : m7_wdata;
wire  [3:0] be    = m9_active ? m9_be    : m7_be;

//------------------------------------------------------------------
// Address decode
//------------------------------------------------------------------
wire is_bios   = (a[31:14] == 18'd0) ||                       // 0x00000000
                 (a[31:16] == 16'hFFFF && a[15:14] == 2'b00); // 0xFFFF0000
wire is_ram    = (a[31:24] == 8'h02);
wire is_shared = (a[31:24] == 8'h03 && a[23] == 1'b0);
wire is_a7wram = (a[31:24] == 8'h03 && a[23] == 1'b1);
wire is_io     = (a[31:24] == 8'h04);
wire is_pal    = (a[31:24] == 8'h05);
wire is_vram   = (a[31:24] == 8'h06);
wire is_oam    = (a[31:24] == 8'h07);
wire is_cart   = (a[31:24] == 8'h08);
wire is_private = is_bios | is_shared | is_a7wram | is_io | is_pal | is_oam | is_vram;

//------------------------------------------------------------------
// Read data for private regions
//------------------------------------------------------------------
reg [31:0] rd_word;
always @(*) begin
	rd_word = 32'h0000_0000;
	if (is_io) begin
		case (io_addr)
		16'h0130: rd_word = {16'h0000, keyinput};
		16'h0132: rd_word = {16'h0000, keycnt};
		16'h0180: rd_word = {16'h0000, ipcsync};
		16'h0204: rd_word = {16'h0000, exmemcnt};
		16'h0208: rd_word = {31'd0, irq_master_enable};
		16'h0210: rd_word = irq_enable;
		16'h0214: rd_word = irq_flags;
		16'h0300: rd_word = {16'h0000, powcnt1};
		16'h0000: rd_word = {16'h0000, dispcnt_a};
		16'h1000: rd_word = {16'h0000, dispcnt_b};
		default:  rd_word = 32'h0000_0000;
		endcase
	end else if (is_bios) begin
		rd_word = 32'hE1A0_0000; // MOV r0,r0 (NOP) — HLE dispatch in M1
	end else if (is_pal) begin
		rd_word = {palette[{a[10:1]} + 10'd1], palette[{a[10:1]}]};
	end else if (is_oam) begin
		rd_word = {oam[{a[10:1]} + 10'd1], oam[{a[10:1]}]};
	end
	// VRAM reads 0 until bank storage lands (M2)
end

//------------------------------------------------------------------
// Address/word helpers
//------------------------------------------------------------------
wire [12:0] shared_idx = a[14:2];
wire [13:0] a7_idx     = a[15:2];
wire [9:0]  pal_idx    = a[10:1];

wire [15:0] w_lane_lo = wdata[15:0];
wire [15:0] w_lane_hi = wdata[31:16];

// main RAM: byte 0x02000000+offset -> SDRAM word 0x200000+ (4 MB window)
wire [24:0] ram_word_lo = {3'd0, 1'b1, 1'b0, a[21:2]};
wire [24:0] ram_word_hi = ram_word_lo + 25'd1;

//------------------------------------------------------------------
// FSM
//------------------------------------------------------------------
always @(posedge clk) begin
	m9_ready <= 0;
	m7_ready <= 0;
	vramcnt_we_r <= 0;
	cheat_chk_en <= 0;
	cart_req <= 0;
	ram_req  <= 0;

	case (state)

	S_IDLE: begin
		if (m9_req && m7_req) begin
			if (turn) begin m7_active <= 1; m9_active <= 0; end
			else      begin m9_active <= 1; m7_active <= 0; end
			state <= S_PRIV;
		end else if (m9_req) begin
			m9_active <= 1; m7_active <= 0; state <= S_PRIV;
		end else if (m7_req) begin
			m7_active <= 1; m9_active <= 0; state <= S_PRIV;
		end
	end

	S_PRIV: begin
		is_read  <= m_rd;
		need_b   <= |be[3:2] && (is_ram || is_shared || is_a7wram ||
		                         is_pal || is_oam || is_io);
		lo_half  <= 16'h0000;
		hi_half  <= 16'h0000;

		if (is_ram && (m_rd || m_wr)) begin
			ram_req   <= 1;
			ram_wr    <= m_wr;
			ram_addr  <= ram_word_lo;
			ram_wdata <= w_lane_lo;
			ram_be    <= be[1:0];
			state     <= S_WAIT_A;
		end else if (is_cart && m_rd) begin
			cart_req  <= 1;
			cart_addr <= {a[25:2], 2'b00};
			state     <= S_WAIT_A;
		end else if (is_cart && m_wr) begin
			// ROM command writes (unlock sequence) — M4
			state <= S_RESP;
		end else begin
			// private region: perform in this cycle, respond in S_RESP
			if (m_wr) begin
				if (is_shared)
					wram_shared[shared_idx] <= {be[3] ? wdata[31:24] : wram_shared[shared_idx][31:24],
					                            be[2] ? wdata[23:16] : wram_shared[shared_idx][23:16],
					                            be[1] ? wdata[15:8]  : wram_shared[shared_idx][15:8],
					                            be[0] ? wdata[7:0]   : wram_shared[shared_idx][7:0]};
				else if (is_a7wram)
					wram_arm7[a7_idx] <= {be[3] ? wdata[31:24] : wram_arm7[a7_idx][31:24],
					                      be[2] ? wdata[23:16] : wram_arm7[a7_idx][23:16],
					                      be[1] ? wdata[15:8]  : wram_arm7[a7_idx][15:8],
					                      be[0] ? wdata[7:0]   : wram_arm7[a7_idx][7:0]};
				else if (is_pal) begin
					if (be[0]) palette[pal_idx]         <= wdata[15:0];
					if (be[1]) palette[pal_idx + 10'd1] <= wdata[31:16];
				end else if (is_oam) begin
					if (be[0]) oam[pal_idx]         <= wdata[15:0];
					if (be[1]) oam[pal_idx + 10'd1] <= wdata[31:16];
				end else if (is_io) begin
					case (io_addr)
					16'h0000: dispcnt_a <= w_lane_lo;
					16'h1000: dispcnt_b <= w_lane_lo;
					16'h0132: keycnt    <= w_lane_lo;
					16'h0180: ipcsync   <= w_lane_lo;
					16'h0204: exmemcnt  <= w_lane_lo;
					16'h0208: irq_master_enable <= w_lane_lo[0];
					16'h0210: irq_enable[15:0]  <= w_lane_lo;
					16'h0212: irq_enable[31:16] <= w_lane_lo;
					16'h0214: irq_flags[15:0]   <= irq_flags[15:0]  & ~w_lane_lo;
					16'h0216: irq_flags[31:16]  <= irq_flags[31:16] & ~w_lane_lo;
					16'h0300: powcnt1 <= w_lane_lo;
					default: ;
					endcase
					if (io_addr >= 16'h0240 && io_addr <= 16'h0248)
						vramcnt_we_r <= 1;
				end
			end
			state <= S_RESP;
		end
	end

	S_WAIT_A: begin
		if (is_ram && ram_done) begin
			lo_half <= ram_rdata;
			if (m_wr && !is_read) begin
				// write sequence: first half done
				if (need_b) state <= S_REQ_B;
				else        state <= S_RESP;
			end else if (need_b) begin
				ram_req   <= 1;
				ram_wr    <= 0;
				ram_addr  <= ram_word_hi;
				ram_be    <= 2'b11;
				state     <= S_WAIT_B;
			end else state <= S_RESP;
		end else if (is_cart && cart_valid) begin
			lo_half <= cart_rdata;
			if (need_b) begin
				cart_req  <= 1;
				cart_addr <= {a[25:2], 2'b00} + 26'd2;
				state     <= S_WAIT_B;
			end else state <= S_RESP;
		end
	end

	S_REQ_B: begin
		// issue the high halfword of a split write
		ram_req   <= 1;
		ram_wr    <= 1;
		ram_addr  <= ram_word_hi;
		ram_wdata <= w_lane_hi;
		ram_be    <= be[3:2];
		state     <= S_WAIT_B;
	end

	S_WAIT_B: begin
		if (is_ram && ram_done) begin
			hi_half <= ram_rdata;
			state   <= S_RESP;
		end else if (is_cart && cart_valid) begin
			hi_half <= cart_rdata;
			state   <= S_RESP;
		end
	end

	S_RESP: begin
		if (m9_active) begin
			if (is_read && !m_wr) begin
				m9_rdata <= is_private ? rd_word :
				            is_ram     ? {hi_half, lo_half} :
				            is_cart    ? {hi_half, lo_half} : 32'h0;
				cheat_chk_en   <= is_ram;
				cheat_chk_addr <= a;
				cheat_chk_data <= lo_half;
			end
			m9_ready <= 1;
		end else if (m7_active) begin
			if (is_read && !m_wr) begin
				m7_rdata <= is_private ? rd_word :
				            is_ram     ? {hi_half, lo_half} :
				            is_cart    ? {hi_half, lo_half} : 32'h0;
				cheat_chk_en   <= is_ram;
				cheat_chk_addr <= a;
				cheat_chk_data <= lo_half;
			end
			m7_ready <= 1;
		end
		turn      <= ~turn;
		m9_active <= 0;
		m7_active <= 0;
		state     <= S_IDLE;
	end

	default: state <= S_IDLE;
	endcase

	if (reset) begin
		state <= S_IDLE;
		m9_active <= 0; m7_active <= 0;
		m9_ready  <= 0; m7_ready  <= 0;
		vramcnt_we_r <= 0; cheat_chk_en <= 0;
		cart_req <= 0; ram_req <= 0; ram_wr <= 0;
		irq_master_enable <= 0;
		irq_enable  <= 0;
		irq_flags   <= 0;
		dispcnt_a   <= 0;
		dispcnt_b   <= 0;
	end
end

// cheat_patch is applied by the CPU read service in M1; touch/mic and
// observations are consumed as the engines land.
wire _unused = &{1'b0, touch_x, touch_y, touch_down, mic_in,
                 cheat_patch, cheat_hit};

endmodule
