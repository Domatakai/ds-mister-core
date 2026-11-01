//============================================================================
// NDS MiSTer Test — Nintendo DS core for MiSTer FPGA
// Core top level (module emu), following the MiSTer framework interface.
//
// This file is derived from MiSTer-devel/Template_MiSTer (GPL v2+):
//   https://github.com/MiSTer-devel/Template_MiSTer
//
// Status bit allocation (128-bit status word from hps_io). The OSD Lab on
// the project website is the menu prototype — keep the two in sync.
//
//   [0]     reset core (R[0], main menu)
//   [127]   soft reset (T[127])
//   [126]   erase save data (T[126], action)
//   [125]   disable all cheats (T[125], action)
//   [4:2]   save type        (Auto/EEPROM512K/EEPROM8K/FLASH512K/FLASH1M/FRAM/NAND)
//   [7:5]   screen layout    (Vertical/Horizontal/Top only/Bottom only)
//   [9:8]   rotation         (0/90/180/270)
//   [12:10] aspect ratio     (Original/Full/ARC1/ARC2)
//   [14:13] scanlines        (VGA_SL 0..3)
//   [15]    swap screens
//   [18:16] backlight        (Dim..Brightest: the 5-step panel gain)
//   [53:52] refresh rate     (Native 59.82 / 59.95 / 60.00)
//   [22:19] master volume    (0%..100%)
//   [24:23] sound output     (Stereo/Mono/Headphones — the DS's wording)
//   [26:25] I2S latency      (1/2/4 frames)
//   [27]    SPU sync
//   (the SPU takes its own timing from SOUNDxTMR; [27] is still an OSD row
//    reserved for a future sync option, see rtl/audio/spu.sv)
//   [28]    ARM7 BIOS        (HLE / bios7.bin)
//   [29]    ARM9 BIOS        (HLE / bios9.bin)
//   [30]    auto-start       (Manual/Auto — the DS Settings row; reserved)
//   [32:31] region           (Auto/NTSC-U/NTSC-J/PAL) — informational only:
//                            the core is region-free, any cart boots.
//   [34:33] stylus mode
//   [36:35] microphone
//   [37]    rumble pak
//   [39:38] pad profile
//   [41:40] core speed       (100/150/200/Max %)
//   [43:42] frameskip
//   [44]    auto frameskip
//   [46:45] rewind buffer
//   [47]    show FPS
//   [48]    frame graph
//   [49]    bus activity LEDs
//   [51:50] log level
//   [55:54] stylus tap button(L2/R2/L3/R3)
//   [56]    face buttons     (standard / swapped)
//   [57]    shoulders        (normal / swapped)
//   [59:58] CPU overclock    (Normal / ARM7 x2 / ARM7 x4)
//   [62:60] video filter     (Off / Soft / Smooth / Sharp)
//   [65:63] LCD colour       (Original / DS LCD / Vivid / Warm / Cool / Grayscale)
//   [67:66] audio filter     (Off / Warm / Bright / Bass)
//   [69:68] stereo width     (Off / Soft / Strong)
//   [70]    MT-32-pi link    (Off/On; MIDI out + I2S return)
//   [73:71] MIDI volume      (0%..100% for the MT-32-pi return only)
//   [74]    internal demo MIDI stream (Off/On; a test phrase, see
//                            rtl/audio/midi_port.sv)
//   [75]    MT-32-pi LCD on screen (Off/On; draws the Pi's OLED panel
//                            over the top-left corner, rtl/video/lcd_overlay.sv)
//   [76]    MT-32-pi synth  (MT-32 / SoundFont; requested from the Pi over
//                            I2C — 0xA1 vs 0xA2 in sys/mt32pi.sv)
//   [79:77] SoundFont bank   (which soundfont the Pi loads, 0..7; only used
//                            in SoundFont mode — rtl/audio/mt32_select.sv)
//   [80]    Pi LCD size      (1x = 128x64 exact pixels / 2x = 256x128 for
//                            a large display — rtl/video/lcd_overlay.sv)
//   [82:81] Pi LCD corner    (top/bottom x left/right; 2x fills the width)
//   [84:83] lid close        (Ignore / L2+R2 / L3+R3: shuts the shell. The
//                            hinge is reported on EXTKEYIN bit 7 and the
//                            screens go dark — rtl/input/input_mapper.sv,
//                            rtl/video/screen_composer.sv)
//   [87:85] language         (English/Japanese/French/German/Italian/
//                            Spanish: the language the synthesised firmware
//                            user settings report — rtl/bus/spi.sv)
//   [89:88] slot-2           (None/GBA cartridge/RAM expansion. Reserved:
//                            the spec row for the DS's second card slot;
//                            only slot 1 loads today)
//   [90]    firmware         (HLE / firmware.bin. Reserved)
//   [93]    auto overclock   (On/Off. Written On-first (0), so a fresh core
//                            takes the per-game reference from the loaded
//                            cart's game code instead of Normal)
//   [123]   clear game slots (action: forget every staged game)
//   [124]   boot menu        (action: open the in-core game picker)
//============================================================================
module emu
(
`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////
assign ADC_BUS = 'Z;
// USER_IN/USER_OUT carry MT-32-pi (MIDI out on bit 1, I2S audio back); the
// instance in the audio section drives the whole port.
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
// DDRAM is driven by the cart slot (ROM image in DDR3)
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;
assign AUDIO_S   = 1; // signed samples from the SPU
assign AUDIO_MIX = 0;
assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;
//////////////////////////////////////////////////////////////////

`include "build_id.v"

//------------------------------------------------------------------
// OSD menu definition (drawn by sys/osd.sv, values arrive in status[])
//
// The cartridge entry is the .nds loader. "F1,NDS" asks the HPS file
// browser for the NDS extension, and the Main matches extensions
// case-insensitively (ScanDirectory -> tolower, Main's file_io.cpp), so
// .nds, .NDS and .Nds all list. It opens in /media/fat/games/NDS because
// that is where NDS.rbf lives; the folder belongs to the HPS, and no
// MiSTer core is ever given a directory listing -- which is why the boot
// menu names games from their own headers. Further extensions would be
// packed three characters each ("NDSBIN"), with no separator.
//------------------------------------------------------------------
localparam [19119:0] CONF_STR = {   // 2390 string bytes, the 6-char `BUILD_DATE
                                    // (sys/build_id.tcl: %y%m%d) included
                                    // (tools/confstr_len.py checks the width)
"NDS MiSTer Test;;",
"-;",
"P1,Slot-1 Card;",
"P1F1,NDS;",
"P1-;",
"h0P1O[4:2],Save type,Auto,EEPROM 512K,EEPROM 8K,FLASH 512K,FLASH 1M,FRAM,NAND;",
"P1O[89:88],Slot-2,None,GBA cartridge,RAM expansion;",
"h0P1T[126],Erase save data;",
"h1P1T[124],Boot menu;",
"h1P1T[123],Clear game slots;",
"-;",
"P2,Screens;",
"P2O[7:5],Screen layout,Vertical,Horizontal,Top only,Bottom only;",
"P2O[9:8],Rotation,0,90,180,270;",
"P2O[15],Swap screens,Off,On;",
"P2O[12:10],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
"P2O[18:16],Backlight,Dim,Low,Medium,High,Brightest;",
"P2O[14:13],Scanlines,Off,Soft,Medium,Hard;",
"P2O[53:52],Refresh rate,Native 59.82,59.95,60.00;",
"P2O[62:60],Video filter,Off,Soft,Smooth,Sharp;",
"P2O[65:63],LCD colour,Original,DS LCD,Vivid,Warm,Cool,Grayscale;",
"-;",
"P3,Sound;",
"P3O[22:19],Master volume,0%,10%,20%,30%,40%,50%,60%,70%,80%,90%,100%;",
"P3O[24:23],Sound output,Stereo,Mono,Headphones;",
"P3O[26:25],I2S latency,1 frame,2 frames,4 frames;",
"P3O[27],SPU sync,Off,On;",
"P3O[67:66],Audio filter,Off,Warm,Bright,Bass;",
"P3O[69:68],Stereo width,Off,Soft,Strong;",
"-;",
"P4,Touch & Pad;",
"P4O[34:33],Stylus cursor,Off,D-pad,Left stick;",
"P4O[55:54],Stylus tap,L2,R2,L3,R3;",
"P4O[84:83],Lid close,Ignore,L2+R2,L3+R3;",
"P4O[36:35],Microphone,Off,Button,Host device;",
"P4O[37],Rumble pak,Off,On;",
"P4-;",
"P4O[56],Face buttons,Standard,Swapped;",
"P4O[57],Shoulders,Normal,Swapped;",
"P4O[39:38],Pad profile,Default,Left-hand,Arcade stick;",
"-;",
"P5,Firmware;",
"P5O[28],ARM7 BIOS,HLE,bios7.bin;",
"P5O[29],ARM9 BIOS,HLE,bios9.bin;",
"P5O[90],Firmware,HLE,firmware.bin;",
"P5O[87:85],Language,English,Japanese,French,German,Italian,Spanish;",
"P5O[30],Auto-start,Manual,Auto;",
"P5O[32:31],Region,Auto,NTSC-U,NTSC-J,PAL;",
"-;",
"P6,System;",
"P6O[41:40],Core speed,100%,150%,200%,Max;",
"h0P6O[59:58],CPU overclock,Normal,ARM7 x2,ARM7 x4;",
"h0P6O[93],Auto overclock,On,Off;",
"P6O[43:42],Frameskip,Off,1,2,3;",
"P6O[44],Auto frameskip,Off,On;",
"P6O[46:45],Rewind buffer,Off,5 s,15 s,30 s;",
"P6-;",
"P6-,Diagnostics;",
"P6O[47],Show FPS,Off,On;",
"P6O[48],Frame graph,Off,On;",
"P6O[49],Bus activity LEDs,Off,On;",
"P6O[51:50],Log level,Off,Errors,Verbose;",
"h0P6T[125],Disable all cheats;",
"-;",
"P7,MIDI;",
"P7O[70],MT-32-pi,Off,On;",
"P7O[73:71],MIDI volume,0%,14%,29%,43%,57%,71%,86%,100%;",
"P7O[74],Internal demo stream,Off,On;",
"P7O[75],Pi LCD on screen,Off,On;",
"P7O[80],Pi LCD size,1x,2x;",
"P7O[82:81],Pi LCD corner,Top left,Top right,Bottom left,Bottom right;",
"P7O[76],MT-32-pi synth,MT-32,SoundFont;",
"P7O[79:77],SoundFont bank,0,1,2,3,4,5,6,7;",
"-;",
"F2,CHT;",
"-;",
"T[127],Soft reset;",
"R[0],Reset core and close OSD;",
"v,1;",
"V,v",`BUILD_DATE
};

//------------------------------------------------------------------
// HPS I/O — menu, ROM download (F1 .nds), cheat file (F2 .cht),
// save file access (sd_*), joysticks, PS/2
//------------------------------------------------------------------
wire [127:0] status;
// OSD row visibility: rows that only mean something while a cartridge is
// up are masked on these (CONF_STR's h0/h1 prefixes), so a loaded core
// shows the cartridge's menu instead of a list of dead options.
wire        game_loaded;   // a .nds has finished downloading
wire        any_slot;      // at least one staged game exists
wire   [1:0] buttons;
wire         forced_scandoubler;
wire  [10:0] ps2_key;
wire  [31:0] joystick_0, joystick_1;
wire         ioctl_download;
wire  [26:0] ioctl_addr;
wire  [15:0] ioctl_dout;
wire         ioctl_wr;
wire  [15:0] ioctl_index;
wire   [0:0] sd_rd, sd_wr;
wire  [15:0] sd_buff_dout;
wire  [12:0] sd_buff_addr;
wire         sd_buff_wr;
wire   [0:0] sd_ack;
wire   [0:0] img_mounted;
wire  [63:0] img_size;
wire         ioctl_wait;   // cart slot backpressure -> HPS
wire  [15:0] stick0;       // left analog stick (stylus cursor mode)

// no SD block-device saves yet: keep HPS request inputs deasserted
assign sd_rd = 1'b0;
assign sd_wr = 1'b0;

//------------------------------------------------------------------
// F2 (.cht) text path: secondary files share the ioctl pipe, keyed by
// ioctl_index (F1 -> 1, F2 -> 2). WIDE=1 delivers two ASCII bytes per
// 16-bit word, low byte first; the high byte of an odd final word is
// zero padding and is filtered by the engine (0 is never a hex digit
// or a separator). One byte per clk_sys cycle: the HPS spaces WIDE
// words >= 16 SCK (~160 ns @100 MHz) apart vs the single cycle needed,
// so consecutive words can never collide.
//------------------------------------------------------------------
wire        cheat_dl = ioctl_download & (ioctl_index[5:0] == 6'd2);

wire        f2_wr;
wire  [7:0] f2_dout;
assign f2_wr   = cheat_dl & ioctl_wr;
assign f2_dout = ioctl_dout[7:0];

hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),
	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask({14'd0, any_slot, game_loaded}), // h0 = game loaded, h1 = a slot exists
	.ps2_key(ps2_key),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_l_analog_0(stick0),
	.ioctl_download(ioctl_download),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wr(ioctl_wr),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),
	.ioctl_din(16'd0),            // no save upload
	.ioctl_upload_req(1'b0),
	.ioctl_upload_index(8'd0),

	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_lba('{32'd0}),
	.sd_blk_cnt('{6'd0}),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_wr(sd_buff_wr),
	.sd_buff_din('{16'd0}),
	.sd_ack(sd_ack),
	.img_mounted(img_mounted),
	.img_size(img_size),

	// no block-device saves yet: keep the SD request inputs low
	.status_in(128'd0),
	.status_set(1'b0),
	.info_req(1'b0),
	.info(8'd0),
	.new_vmode(1'b0),
	.video_rotated(1'b0),

	.ps2_kbd_clk_in(1'b1),
	.ps2_kbd_data_in(1'b1),
	.ps2_kbd_led_status(3'd0),
	.ps2_kbd_led_use(3'd0),
	.ps2_mouse_clk_in(1'b1),
	.ps2_mouse_data_in(1'b1),

	.joystick_0_rumble(16'd0),
	.joystick_1_rumble(16'd0),
	.joystick_2_rumble(16'd0),
	.joystick_3_rumble(16'd0),
	.joystick_4_rumble(16'd0),
	.joystick_5_rumble(16'd0)
);

//------------------------------------------------------------------
// Status word decode — named wires keep CONF_STR and RTL in step.
//------------------------------------------------------------------
wire        reset_core    = RESET | status[0] | buttons[1];
wire        soft_reset    = status[127];
wire        erase_save    = status[126];
wire  [2:0] save_type     = status[4:2];
wire  [2:0] scr_layout    = status[7:5];
wire  [1:0] rotation      = status[9:8];
wire  [2:0] aspect        = status[12:10];
wire  [1:0] scanlines     = status[14:13];
wire        swap_screens  = status[15];
wire  [2:0] brightness    = status[18:16];
wire  [1:0] refresh       = status[53:52];
wire  [3:0] volume        = status[22:19];
wire  [1:0] mix_mode      = status[24:23];
wire  [1:0] i2s_latency   = status[26:25];
wire        spu_sync      = status[27];
wire        bios_real     = status[28];   // ARM7 BIOS
wire        bios9_real    = status[29];   // ARM9 BIOS
wire        auto_start    = status[30];   // the DS's own Auto-start row
wire  [1:0] slot2         = status[89:88]; // spec row (GBA slot), not wired
wire  [2:0] lang_sel      = status[87:85];
wire  [1:0] lid_sel       = status[84:83];
wire        fw_dump       = status[90];   // firmware.bin, reserved
wire  [1:0] region        = status[32:31];
wire  [1:0] stylus_mode   = status[34:33];
wire  [1:0] mic_source    = status[36:35];
wire        rumble        = status[37];
wire  [1:0] pad_profile   = status[39:38];
wire  [1:0] core_speed    = status[41:40];
wire  [1:0] frameskip     = status[43:42];
wire        autoskip      = status[44];
wire  [1:0] rewind_buf    = status[46:45];
wire        show_fps      = status[47];
wire        frame_graph   = status[48];
wire        bus_leds      = status[49];
wire  [1:0] log_level     = status[51:50];
wire  [1:0] tap_sel       = status[55:54];
wire        face_swap     = status[56];
wire        shoulder_swap = status[57];
wire  [1:0] oc_mode       = status[59:58];
wire        auto_oc       = ~status[93];  // row is written On,Off: 0 = On
wire  [2:0] vfilter       = status[62:60]; // Video filter
wire  [2:0] palette_sel   = status[65:63]; // Colour palette
wire  [1:0] afilter       = status[67:66]; // Audio filter
wire  [1:0] stereo_width  = status[69:68]; // Stereo width
wire        mt32_enable   = status[70];    // MT-32-pi link
wire  [2:0] midi_volume   = status[73:71]; // MT-32-pi return level
wire        midi_demo     = status[74];    // internal test stream
wire        mt32_lcd      = status[75];    // draw the Pi's OLED panel
wire        midi_synth    = status[76];    // 0 = MT-32, 1 = SoundFont
wire  [2:0] sf_bank       = status[79:77]; // soundfont index for the Pi
wire        mt32_lcd_2x   = status[80];    // draw the panel at double size
wire  [1:0] mt32_lcd_pos  = status[82:81]; // which corner it sits in

//------------------------------------------------------------------
// Boot menu / game slots
//
// A MiSTer core cannot list the SD card — the HPS hands it one file per
// OSD selection — so the picker lists the games the cart has already
// staged in DDR3, each named from its own ROM header. Select (or the OSD
// action) opens it, A boots the highlighted slot, and the choice is held
// in a register that a core reset does not clear, so the game you picked
// is the one that comes back up.
//------------------------------------------------------------------
wire        menu_action  = status[124];   // OSD action: open the picker
wire        clear_action = status[123];   // OSD action: forget every slot
wire        menu_boot;                    // A pressed on a valid slot
wire  [1:0] menu_boot_sel;
wire        menu_active;                  // menu owns the picture
wire  [3:0] slot_valid;
wire  [1:0] slot_load;                    // slot the next load goes into
wire        menu_open_p, menu_close_p;
wire  [1:0] menu_hdr_slot;
wire  [3:0] menu_hdr_char;
wire  [7:0] menu_hdr_data;
wire [31:0] slot_caps;                    // declared size per slot (0x80)
wire [15:0] slot_save_det;                // save type the probe detected
wire [31:0] slot9_entry;                  // header 0x24 of the boot slot
wire [31:0] slot7_entry;                  // header 0x34 of the boot slot

reg   [1:0] active_game_slot = 2'd0;      // deliberately not reset
reg         menu_bit_d  = 1'b0;
reg         clear_bit_d = 1'b0;
reg         j_up_d = 1'b0, j_dn_d = 1'b0, j_a_d = 1'b0, j_sel_d = 1'b0;

wire menu_up  = joystick_0[3]  & ~j_up_d;
wire menu_dn  = joystick_0[2]  & ~j_dn_d;
wire menu_a   = joystick_0[4]  & ~j_a_d;
wire menu_sel = joystick_0[10] & ~j_sel_d;

wire menu_toggle = menu_sel | (menu_action & ~menu_bit_d);
assign menu_open_p  = menu_toggle & ~menu_active;
assign menu_close_p = menu_toggle &  menu_active;

wire slot_clear = clear_action & ~clear_bit_d;

//------------------------------------------------------------------
// Clocks
//
// The core runs on the DS's own 67.0274 MHz, out of the PLL. That is the
// ARM9's clock and the ARM7's 33.513982 MHz is exactly half of it, so the 2:1
// `cpu_ce` produces is the hardware's ratio rather than a scaled one — the
// whole point of moving off CLK_50M. Derived from it by clock enable:
//
//   clk_sys   67.0274 MHz — ARM9 every cycle, ARM7 every second cycle
//   clk_pix   13.4055 MHz — pixel CE (/5) for the 256x384 stacked frame
//
// The one part of the machine that does not move is the DDR3 interface: the
// framework's DDRAM IP is generated for a 50 MHz reference and would drag its
// whole PHY phase with it, so `clk_ddr` stays CLK_50M and `ddr_bus_bridge`
// is the single crossing between the two.
//------------------------------------------------------------------
wire clk_cpu;
wire pll_locked;

// The PLL's reset is driven, not tied off: Quartus reports "RST port on the
// PLL is not properly connected" for a constant, and the port exists to give
// the counters a defined start. Sixteen CLK_50M cycles from configuration,
// long before the core leaves reset on pll_locked.
reg [3:0] pll_rst_sr = 4'hf;
always @(posedge CLK_50M) pll_rst_sr <= {pll_rst_sr[2:0], 1'b0};

pll u_pll (
	.refclk(CLK_50M),
	.rst(pll_rst_sr[3]),
	.outclk_0(clk_cpu),
	.locked(pll_locked)
);

wire clk_sys = clk_cpu;
wire clk_ddr = CLK_50M;
wire clk_pix_ce;

//------------------------------------------------------------------
// Reset — released on a frame boundary so video never glitches.
// frame_start pulses once per frame and timing is free-running, so
// this always releases (a synchronous-clear version would deadlock:
// reset would freeze ce_div, so frame_start could never fire).
//------------------------------------------------------------------
wire frame_start;
reg  reset_hold = 1'b1;
always @(posedge clk_sys) begin
	// a boot from the menu resets the core onto the slot the player chose, and
	// the PLL must have locked (its output is not running before that, so this
	// simply holds the machine until the first real clock arrives)
	if (reset_core | soft_reset | menu_boot | ~pll_locked) reset_hold <= 1'b1;
	else if (frame_start)                                  reset_hold <= 1'b0;
end

// one-cycle edges for the menu controls; kept out of the reset so a
// held button cannot fire twice across a reset
always @(posedge clk_sys) begin
	j_up_d      <= joystick_0[3];
	j_dn_d      <= joystick_0[2];
	j_a_d       <= joystick_0[4];
	j_sel_d     <= joystick_0[10];
	menu_bit_d  <= menu_action;
	clear_bit_d <= clear_action;
	if (menu_boot) active_game_slot <= menu_boot_sel;
end
wire reset = reset_hold;

//------------------------------------------------------------------
// Video path: fixed 256x384 stacked frame (top screen above bottom).
// The pixel CE is now 67.0274/5 = 13.40548 MHz (it was 50/4 = 12.5), so the
// totals moved with it; the OSD "Refresh rate" option still picks them:
//   Native  330 x 679 -> 59.8272 Hz  (DS native is 59.8261, +18 ppm)
//   59.95   344 x 650 -> 59.9530 Hz
//   60.00   331 x 675 -> 59.9999 Hz
// Every mode keeps H_ACTIVE/V_ACTIVE and the sync windows fixed, so only the
// blanking tail changes and the scaler re-locks the way it always did.
//------------------------------------------------------------------
wire  [8:0] h_total = (refresh == 2'd1) ? 9'd344 :
                      (refresh == 2'd2) ? 9'd331 : 9'd330;
wire  [9:0] v_total = (refresh == 2'd1) ? 10'd650 :
                      (refresh == 2'd2) ? 10'd675 : 10'd679;

wire  [8:0] pix_x, pix_y;
wire        pix_de, pix_hs, pix_vs;
wire [15:0] pix_out;

video_timing video_timing (
	.clk(clk_sys),
	.ce(1'b1),
	.pixel_ce(clk_pix_ce),
	// free-running: holding video_timing in reset would freeze ce_div,
	// so frame_start could never fire and reset_pending would deadlock
	.reset(1'b0),
	.h_total(h_total),
	.v_total(v_total),
	.x(pix_x),
	.y(pix_y),
	.de(pix_de),
	.hs(pix_hs),
	.vs(pix_vs),
	.frame_start(frame_start)
);

//------------------------------------------------------------------
// 2D engines A/B — real text renderers (M2). The composer asks for a
// native pixel; the engines answer combinationally from their front
// line buffers, which fetch FSMs fill by streaming VRAM through
// vram_arbiter while the current line displays.
//------------------------------------------------------------------
wire [7:0] na_x, nb_x;
wire [7:0] na_y, nb_y;
wire       na_on, nb_on;
wire [15:0] pix_top, pix_bot;

// Engine plumbing: register writes, palette/OAM second BRAM ports,
// VRAM fetch ports
wire        ea_we, eb_we;
wire  [6:0] ea_addr;
wire [15:0] ea_data;
wire  [9:0] ea_pal_addr, ea_oam_addr, eb_pal_addr, eb_oam_addr;
wire [15:0] ea_pal_data, ea_oam_data, eb_pal_data, eb_oam_data;
// Both engines fetch in bursts: a request names a length, the beats stream
// back one per cycle, and ready marks the last one.
wire        ea_v_req, ea_v_ready, eb_v_req, eb_v_ready;
wire [19:0] ea_v_addr, eb_v_addr;
wire  [7:0] ea_v_len,  eb_v_len;
wire        ea_v_bs_valid, eb_v_bs_valid;
wire [15:0] ea_v_bs_data,  eb_v_bs_data;

// engine A's 3D layer read port (frame halfwords for compositing): a burst
// of ea_d3_len halfwords, streamed back on ea_d3_bs_valid
wire        ea_d3_req, ea_d3_ready;
wire [16:0] ea_d3_addr;
wire  [7:0] ea_d3_len;
wire        ea_d3_bs_valid;
wire [15:0] ea_d3_bs_data;

// DMA: register file + bus master (third main_bus master), triggers
wire        dma_reg_we, dma_ready, dma_rd, dma_wr;
wire  [7:0] dma_reg_addr, dma_reg_rd_addr;
wire [15:0] dma_reg_data, dma_reg_rdata;
wire [31:0] dma_addr, dma_wdata, dma_rdata;
wire  [3:0] dma_be, dma_irq;
reg         hs_d = 1'b0, vs_d = 1'b0;
always @(posedge clk_sys) begin
	hs_d <= pix_hs;
	vs_d <= pix_vs;
end
wire hblank_t = pix_hs & ~hs_d;   // rising edge = hblank start
wire vblank_t = pix_vs & ~vs_d;   // rising edge = vblank start

// CPU VRAM window <-> vram_arbiter, and vram_arbiter -> mem_arbiter
wire        bus_vram_req, bus_vram_wr, bus_vram_valid;
wire [19:0] bus_vram_addr;
wire [15:0] bus_vram_wdata, bus_vram_rdata;
wire        v2a_req, v2a_wr, v2a_ready;
wire [24:0] v2a_addr;
wire [15:0] v2a_wdata, v2a_rdata;
wire  [1:0] v2a_be;

screen_composer screen_composer (
	.clk(clk_sys),
	.ce(clk_pix_ce),
	.x(pix_x),
	.y(pix_y),
	.de(pix_de),
	.layout(scr_layout),
	.rotation(rotation),
	.swap(swap_screens),
	.brightness(brightness),
	.dark(hinge_j),        // lid shut: both screens off, as on hardware
	.na_x(na_x), .na_y(na_y), .na_on(na_on), .pix_top(pix_top),
	.nb_x(nb_x), .nb_y(nb_y), .nb_on(nb_on), .pix_bot(pix_bot),
	.rgb555(pix_out)
);

engine_a engine_a (
	.clk(clk_sys),
	.reset(reset),
	.x(na_x), .y(na_y), .on(na_on), .rgb555(pix_top),
	.reg_we(ea_we), .reg_addr(ea_addr), .reg_data(ea_data),
	.pal_addr(ea_pal_addr), .pal_data(ea_pal_data),
	.oam_addr(ea_oam_addr), .oam_data(ea_oam_data),
	.v_req(ea_v_req), .v_addr(ea_v_addr), .v_len(ea_v_len),
	.v_ready(ea_v_ready),
	.v_bs_valid(ea_v_bs_valid), .v_bs_data(ea_v_bs_data),
	.d3_req(ea_d3_req), .d3_addr(ea_d3_addr), .d3_len(ea_d3_len),
	.d3_ready(ea_d3_ready),
	.d3_bs_valid(ea_d3_bs_valid), .d3_bs_data(ea_d3_bs_data)
);
`ifndef NDS_ONE_SCREEN
engine_b engine_b (
	.clk(clk_sys),
	.reset(reset),
	.x(nb_x), .y(nb_y), .on(nb_on), .rgb555(pix_bot),
	.reg_we(eb_we), .reg_addr(ea_addr), .reg_data(ea_data),
	.pal_addr(eb_pal_addr), .pal_data(eb_pal_data),
	.oam_addr(eb_oam_addr), .oam_data(eb_oam_data),
	.v_req(eb_v_req), .v_addr(eb_v_addr), .v_len(eb_v_len),
	.v_ready(eb_v_ready),
	.v_bs_valid(eb_v_bs_valid), .v_bs_data(eb_v_bs_data)
);
`else
// Engine B compiled out (NDS_ONE_SCREEN): one renderer serves both screens.
// The composer still asks for a bottom pixel and gets blank; the palette,
// OAM and VRAM ports engine B would have driven are tied off.
assign pix_bot     = 16'h0000;
assign eb_pal_addr = 10'd0;
assign eb_oam_addr = 10'd0;
assign eb_v_req    = 1'b0;
assign eb_v_addr   = 20'd0;
assign eb_v_len    = 8'd0;
`endif

// Spatial filter (exactly 1 CE latency, sync delayed to match) then
// the colour profile, then RGB888 for the framework.
wire [15:0] filt_out, pal_out;
wire        f_de, f_hs, f_vs;

video_filter video_filter (
	.clk(clk_sys),
	.ce(clk_pix_ce),
	.mode(vfilter),
	.x(pix_x),
	.y(pix_y),
	.de(pix_de),
	.hs(pix_hs),
	.vs(pix_vs),
	.rgb_in(pix_out),
	.rgb_o(filt_out),
	.de_o(f_de),
	.hs_o(f_hs),
	.vs_o(f_vs)
);

palette palette (
	.mode(palette_sel),
	.rgb_in(filt_out),
	.rgb_o(pal_out)
);

//------------------------------------------------------------------
// MT-32-pi LCD overlay — the Pi streams its OLED contents in video
// timing; the overlay captures a frame and draws it over the top-left
// corner at one panel pixel per output pixel (the scaler enlarges the
// whole frame, so the Pi's status text stays readable). Costs two CEs,
// so h/v sync and DE are taken from its delayed copies.
//------------------------------------------------------------------
wire [15:0] o_out;
wire        o_de, o_hs, o_vs;

lcd_overlay lcd_overlay (
	.clk(clk_sys),
	.ce(clk_pix_ce),
	.reset(reset),
	.enable(mt32_lcd & mt32_available),   // nothing to show without a Pi
	.scale2x(mt32_lcd_2x),
	.corner(mt32_lcd_pos),
	.src_de(pix_de),
	.src_en(mt32_lcd_en),
	.src_pix(mt32_lcd_pix),
	.src_vs(pix_vs),
	.x(pix_x),
	.y(pix_y),
	.de(f_de),
	.hs(f_hs),
	.vs(f_vs),
	.rgb_in(pal_out),
	.rgb_o(o_out),
	.de_o(o_de),
	.hs_o(o_hs),
	.vs_o(o_vs)
);

//------------------------------------------------------------------
// Boot menu — draws over everything when open, otherwise passes the
// picture through (one CE, like the panel overlay). The overlay costs two
// CEs, so the text coordinates are delayed to match its DE.
//------------------------------------------------------------------
reg  [8:0] mx1 = 9'd0, my1 = 9'd0, mx2 = 9'd0, my2 = 9'd0;
reg  [8:0] mx3 = 9'd0, my3 = 9'd0;
always @(posedge clk_sys) if (clk_pix_ce) begin
	mx1 <= pix_x;  my1 <= pix_y;
	mx2 <= mx1;    my2 <= my1;
	mx3 <= mx2;    my3 <= my2;
end

wire [15:0] m_out;
wire        m_de, m_hs, m_vs;

boot_menu boot_menu (
	.clk(clk_sys),
	.ce(clk_pix_ce),
	.reset(reset),
	.enable(1'b1),
	.open_req(menu_open_p),
	.close_req(menu_close_p),
	.up(menu_up),
	.down(menu_dn),
	.a(menu_a),
	.slot_valid(slot_valid),
	.hdr_slot(menu_hdr_slot),
	.hdr_char(menu_hdr_char),
	.hdr_data(menu_hdr_data),
	.slot_caps(slot_caps),
	.slot_save(slot_save_det),
	.active(menu_active),
	.boot_sel(menu_boot_sel),
	.boot_pulse(menu_boot),
	.x(mx3),
	.y(my3),
	.de(o_de),
	.hs(o_hs),
	.vs(o_vs),
	.rgb_in(o_out),
	.rgb_o(m_out),
	.de_o(m_de),
	.hs_o(m_hs),
	.vs_o(m_vs)
);

wire [4:0] out_r = m_out[14:10], out_g = m_out[9:5], out_b = m_out[4:0];
assign VGA_R = m_de ? {out_r, out_r[4:2]} : 8'd0;
assign VGA_G = m_de ? {out_g, out_g[4:2]} : 8'd0;
assign VGA_B = m_de ? {out_b, out_b[4:2]} : 8'd0;
assign VGA_HS = m_hs;
assign VGA_VS = m_vs;
assign VGA_DE = m_de;
assign VGA_F1 = 0;
assign VGA_SL = scanlines;
assign VGA_SCALER = 0;

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = clk_pix_ce;

// Aspect: stacked output is 256x384 (2:3), single-screen 4:3, side 8:3.
// The OSD override replaces these with ARC values (TODO in M4).
assign VIDEO_ARX = (scr_layout == 3'd0) ? 13'd2 : (scr_layout == 3'd1) ? 13'd8 : 13'd4;
assign VIDEO_ARY = (scr_layout == 3'd0) ? 13'd3 : (scr_layout == 3'd1) ? 13'd3 : 13'd3;

//------------------------------------------------------------------
// SDRAM cluster: two masters — the bus RAM window and the cart save
// path — through mem_arbiter into sdram_ctrl (per-byte write masks).
// Cart ROM lives in DDR3 (see cart slot) so 256 Mbit+ carts fit.
//------------------------------------------------------------------
wire        bus_ram_req, bus_ram_wr, bus_ram_done;
wire [24:0] bus_ram_addr;
wire [15:0] bus_ram_wdata;
wire  [1:0] bus_ram_be;

wire        save_req, save_wr, save_done;
wire [24:0] save_addr;
wire [15:0] save_din;

wire        arb_req, arb_wr;
wire [24:0] arb_addr;
wire [15:0] arb_wdata;
wire  [1:0] arb_be;
wire        arb_rd_done, arb_wr_done;
wire [15:0] arb_rdata;
// SPU sample-fetch master (fourth, lowest priority)
wire        spu_mem_req, spu_mem_ready;
wire [24:0] spu_mem_addr;
wire [15:0] spu_mem_rdata;
// read-burst channel from the VRAM master (3D frame fetch) to the controller
wire        v2a_bst, arb_bst, arb_bst_done, arb_bs_valid;
wire        arb_bst_beat;
wire  [7:0] v2a_len, arb_len;
wire  [1:0] v2a_step, arb_step;
wire [15:0] arb_bst_data;   // straight from the controller
wire [15:0] arb_bs_data;    // forwarded by mem_arbiter

mem_arbiter mem_arbiter (
	.clk(clk_sys),
	.reset(reset),
	.bus_req(bus_ram_req),
	.bus_wr(bus_ram_wr),
	.bus_addr(bus_ram_addr),
	.bus_wdata(bus_ram_wdata),
	.bus_be(bus_ram_be),
	.bus_ready(bus_ram_done),
	.save_req(save_req),
	.save_wr(save_wr),
	.save_addr(save_addr),
	.save_wdata(save_din),
	.save_be(2'b11),       // save writes are halfword-wide (M4 refines)
	.save_ready(save_done),
	.vram_req(v2a_req),
	.vram_wr(v2a_wr),
	.vram_addr(v2a_addr),
	.vram_wdata(v2a_wdata),
	.vram_be(v2a_be),
	.vram_bst(v2a_bst),
	.vram_len(v2a_len),
	.vram_step(v2a_step),
	.vram_ready(v2a_ready),
	.vram_bs_valid(arb_bs_valid),
	.vram_bs_data(arb_bs_data),
	.spu_req(spu_mem_req),
	.spu_addr(spu_mem_addr),
	.spu_ready(spu_mem_ready),
	.spu_rdata(spu_mem_rdata),
	.sdram_req(arb_req),
	.sdram_wr(arb_wr),
	.sdram_addr(arb_addr),
	.sdram_wdata(arb_wdata),
	.sdram_be(arb_be),
	.sdram_bst(arb_bst),
	.sdram_len(arb_len),
	.sdram_step(arb_step),
	.sdram_rd_done(arb_rd_done),
	.sdram_wr_done(arb_wr_done),
	.sdram_bst_done(arb_bst_done),
	.sdram_bs_valid(arb_bst_beat),
	.sdram_bs_data(arb_bst_data),
	.sdram_rdata(arb_rdata)
);

sdram_ctrl sdram_ctrl (
	.clk(clk_sys),
	.reset(reset),
	.addr(arb_addr),
	.din(arb_wdata),
	.be(arb_be),
	.rd(arb_req && !arb_wr && !arb_bst),
	.wr(arb_req &&  arb_wr),
	.rd_bst(arb_req && arb_bst),
	.bst_len(arb_len),
	.bst_step(arb_step),
	.dout(arb_rdata),
	.rd_done(arb_rd_done),
	.wr_done(arb_wr_done),
	.bst_valid(arb_bst_beat),
	.bst_data(arb_bst_data),
	.bst_done(arb_bst_done),
	.SDRAM_CLK(SDRAM_CLK),
	.SDRAM_CKE(SDRAM_CKE),
	.SDRAM_A(SDRAM_A),
	.SDRAM_BA(SDRAM_BA),
	.SDRAM_DQ(SDRAM_DQ),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nWE(SDRAM_nWE)
);

//------------------------------------------------------------------
// Cart slot: .nds download into DDR3 (all cart sizes up to 4 Gbit),
// header + capacity detection, CPU window bridge, save plumbing (M4)
//------------------------------------------------------------------
wire        cart_loaded;
wire [31:0] rom_bytes;
wire [31:0] slot_code;

assign game_loaded = cart_loaded;
assign any_slot    = |slot_valid;

// The DDR3 side of the cart runs on the framework's own reference clock
// (`clk_ddr`), because the DDRAM IP's PLL and PHY phase are generated for
// 50 MHz and would move with the core's 67.0274 MHz. `ddr_bus_bridge` is the
// single crossing between the two domains.
wire        cart_ddr_rd, cart_ddr_we, cart_ddr_ack, cart_ddr_busy;
wire [28:0] cart_ddr_addr;
wire [63:0] cart_ddr_din, cart_ddr_dout;
wire  [7:0] cart_ddr_be;

cart_slot cart_slot (
	.clk(clk_sys),
	.reset(reset),
	.ioctl_download(ioctl_download),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wr(ioctl_wr),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),
	.ddr_burstcnt(),
	.ddr_addr(cart_ddr_addr),
	.ddr_din(cart_ddr_din),
	.ddr_be(cart_ddr_be),
	.ddr_we(cart_ddr_we),
	.ddr_rd(cart_ddr_rd),
	.ddr_busy(cart_ddr_busy),   // the bridge answers as the DDR controller
	.ddr_dout_ready(cart_ddr_ack),
	.ddr_dout(cart_ddr_dout),
	.win_req(win_req),          // CPU fetch path <- main_bus cart window
	.win_addr(win_addr),
	.win_valid(win_valid),
	.win_data(win_data),
	.save_req(save_req),
	.save_wr(save_wr),
	.save_addr(save_addr),
	.save_din(save_din),
	.save_done(save_done),
	.erase_save(erase_save),
	.save_type(save_type),
	.cart_loaded(cart_loaded),
	.rom_bytes(rom_bytes),
	.slot_code(slot_code),

	// four staged games: the window reads the chosen slot, downloads fill
	// the lowest empty one, and the titles come from the ROM headers
	.boot_slot(active_game_slot),
	.load_slot(slot_load),
	.slot_valid(slot_valid),
	.slot_clear(slot_clear),
	.hdr_slot(menu_hdr_slot),
	.hdr_char(menu_hdr_char),
	.hdr_data(menu_hdr_data),
	.slot_caps(slot_caps),
	.slot9_entry(slot9_entry),
	.slot7_entry(slot7_entry),
	.slot_save(),           // the record itself: only the probe result is shown
	.slot_save_det(slot_save_det)
);

ddr_bus_bridge ddr_bus_bridge (
	.clk(clk_sys),
	.reset(reset),
	.req(cart_ddr_rd | cart_ddr_we),
	.req_wr(cart_ddr_we),
	.req_addr(cart_ddr_addr),
	.req_din(cart_ddr_din),
	.req_be(cart_ddr_be),
	.ack(cart_ddr_ack),
	.busy(cart_ddr_busy),
	.dout(cart_ddr_dout),
	.clk_ddr(clk_ddr),
	.reset_ddr(reset),
	.ddr_burstcnt(DDRAM_BURSTCNT),
	.ddr_addr(DDRAM_ADDR),
	.ddr_din(DDRAM_DIN),
	.ddr_be(DDRAM_BE),
	.ddr_we(DDRAM_WE),
	.ddr_rd(DDRAM_RD),
	.ddr_busy(DDRAM_BUSY),
	.ddr_dout_ready(DDRAM_DOUT_READY),
	.ddr_dout(DDRAM_DOUT)
);

assign DDRAM_CLK = clk_ddr;

//------------------------------------------------------------------
// Input: DS keys (KEYINPUT), stylus position/press, microphone
//------------------------------------------------------------------
wire [11:0] ds_keys;
wire  [8:0] touch_x;
wire  [7:0] touch_y;
wire        touch_down;
wire        mic_pressed;
wire        hinge_j;      // EXTKEYIN bit 7 / the shell's magnetic hinge

input_mapper input_mapper (
	.clk(clk_sys),
	.reset(reset),
	.joy0(joystick_0),
	.joy1(joystick_1),
	.stick0(stick0),
	.menu_active(menu_active),   // the picker swallows the pad
	.stylus_cursor(stylus_mode),
	.tap_sel(tap_sel),
	.face_swap(face_swap),
	.shoulder_swap(shoulder_swap),
	.mic_source(mic_source),
	.lid_sel(lid_sel),
	.keys(ds_keys),
	.touch_x(touch_x),
	.touch_y(touch_y),
	.touch_down(touch_down),
	.mic_pressed(mic_pressed),
	.hinge_closed(hinge_j)
);

//------------------------------------------------------------------
// CPUs + bus — stubs (M1). The bus keeps the NDS memory map; both CPUs
// idle until their pipelines are implemented.
//------------------------------------------------------------------
//------------------------------------------------------------------
// Main bus + cheat engine + VRAM register file
//------------------------------------------------------------------
wire [25:0] win_addr;
wire        win_req, win_valid;
wire [15:0] win_data;

wire        bus_vramcnt_we;
wire  [3:0] bus_vramcnt_addr;
wire  [7:0] bus_vramcnt_data;

wire        cheat_chk_en, cheat_hit, cheat_ready;
wire [31:0] cheat_chk_addr;
wire [31:0] cheat_chk_word;
wire [15:0] cheat_patch, cheat_patch_hi;
wire        cheat_patch_hi_en;

wire [15:0] dispcnt_a, dispcnt_b;
wire        irq_me;
wire [31:0] irq_en, irq_fl;

// 3D command window (0x04000400..0x040007FF) -> geometry engine -> rasterizer
wire        gx_we;
wire  [9:0] gx_addr;
wire [31:0] gx_data, gx_rdata;
wire        gx_vtx_valid;
wire signed [31:0] gx_vtx_x, gx_vtx_y;
wire  [7:0] gx_vtx_color;
wire  [1:0] gx_vtx_poly;

// 3D pixel stream into the bank mapped to the 3D engine (M3)
wire        px3_valid, px3_ready;
wire [15:0] px3_addr, px3_rgb555;

// SPU register window (0x04000400..0x0400051F from the ARM7)
wire        spu_reg_acc, spu_reg_we;
wire [15:0] spu_reg_addr, spu_reg_wdata, spu_reg_rdata;

// CPU clock enables. Declared up here because the ARM7-domain peripherals
// below take them: the timers count `ce7`, and the DMA advances on it. On the
// DS those are all a divider of the same 33.513982 MHz clock the ARM7 runs on.
wire        ce9, ce7;

main_bus main_bus (
	.clk(clk_sys),
	.reset(reset),
	.ce7(ce7),
	.ds_keys(ds_keys),
	.lang(lang_sel),
	.hinge_closed(hinge_j),
	.touch_x(touch_x),
	.touch_y(touch_y),
	.touch_down(touch_down),
	.mic_in(mic_pressed),
	.m9_addr(m9_addr),
	.m9_wdata(m9_wdata),
	.m9_be(m9_be),
	.m9_rd(m9_rd),
	.m9_wr(m9_wr),
	.m9_ready(m9_ready),
	.m9_rdata(m9_rdata),
	.m7_addr(m7_addr),
	.m7_wdata(m7_wdata),
	.m7_be(m7_be),
	.m7_rd(m7_rd),
	.m7_wr(m7_wr),
	.m7_ready(m7_ready),
	.m7_rdata(m7_rdata),
	.cart_req(win_req),
	.cart_addr(win_addr),
	.cart_valid(win_valid),
	.cart_rdata(win_data),
	.ram_req(bus_ram_req),
	.ram_wr(bus_ram_wr),
	.ram_addr(bus_ram_addr),
	.ram_wdata(bus_ram_wdata),
	.ram_be(bus_ram_be),
	.ram_done(bus_ram_done),
	.ram_rdata(arb_rdata),
	.vramcnt_we(bus_vramcnt_we),
	.vramcnt_addr(bus_vramcnt_addr),
	.vramcnt_data(bus_vramcnt_data),
	.vram_req(bus_vram_req),
	.vram_wr(bus_vram_wr),
	.vram_addr(bus_vram_addr),
	.vram_wdata(bus_vram_wdata),
	.vram_valid(bus_vram_valid),
	.vram_rdata(bus_vram_rdata),
	.dma_reg_we(dma_reg_we),
	.dma_reg_addr(dma_reg_addr),
	.dma_reg_data(dma_reg_data),
	.dma_reg_rd_addr(dma_reg_rd_addr),
	.dma_reg_rdata(dma_reg_rdata),
	.d_addr(dma_addr),
	.d_wdata(dma_wdata),
	.d_be(dma_be),
	.d_rd(dma_rd),
	.d_wr(dma_wr),
	.d_ready(dma_ready),
	.d_rdata(dma_rdata),
	.dma_irq(dma_irq),
	.ea_we(ea_we),
	.ea_addr(ea_addr),
	.ea_data(ea_data),
	.eb_we(eb_we),
	.gx_we(gx_we),
	.gx_addr(gx_addr),
	.gx_data(gx_data),
	.gx_rdata(gx_rdata),
	.pal_ra_a(ea_pal_addr),
	.pal_rd_a(ea_pal_data),
	.pal_ra_b(eb_pal_addr),
	.pal_rd_b(eb_pal_data),
	.oam_ra_a(ea_oam_addr),
	.oam_rd_a(ea_oam_data),
	.oam_ra_b(eb_oam_addr),
	.oam_rd_b(eb_oam_data),
	.cheat_chk_en(cheat_chk_en),
	.cheat_chk_addr(cheat_chk_addr),
	.cheat_chk_word(cheat_chk_word),
	.cheat_patch(cheat_patch),
	.cheat_patch_hi_en(cheat_patch_hi_en),
	.cheat_patch_hi(cheat_patch_hi),
	.cheat_hit(cheat_hit),
	.cheat_ready(cheat_ready),
	.midi_wr(midi_wr),
	.midi_rd(midi_rd),
	.midi_addr(midi_addr),
	.midi_wdata(midi_wdata),
	.midi_rdata(midi_rdata),
	.spu_acc(spu_reg_acc),
	.spu_we(spu_reg_we),
	.spu_addr(spu_reg_addr),
	.spu_wdata(spu_reg_wdata),
	.spu_rdata(spu_reg_rdata),
	.dispcnt_a(dispcnt_a),
	.dispcnt_b(dispcnt_b),
	.irq_master_enable(irq_me),
	.irq_enable(irq_en),
	.irq_flags(irq_fl),
	.irq9_cpu(irq9_cpu),
	.irq7_cpu(irq7_cpu),
	.arm7_halt(arm7_halt)
);

//------------------------------------------------------------------
// 3D pipeline (M3): GXFIFO command decode, matrix state, vertex submission
// and the flat-shaded rasterizer are live; covered pixels are written into
// the VRAM bank whose VRAMCNT MST selects the 3D engine.
//------------------------------------------------------------------
`ifndef NDS_NO_3D
geometry_engine geometry_engine (
	.clk(clk_sys),
	.reset(reset),
	.reg_we(gx_we),
	.reg_addr(gx_addr),
	.reg_data(gx_data),
	.reg_rdata(gx_rdata),
	.vtx_valid(gx_vtx_valid),
	.vtx_x(gx_vtx_x),
	.vtx_y(gx_vtx_y),
	.vtx_color(gx_vtx_color),
	.vtx_poly(gx_vtx_poly)
);

raster_engine raster_engine (
	.clk(clk_sys),
	.reset(reset),
	.vtx_valid(gx_vtx_valid),
	.vtx_x(gx_vtx_x),
	.vtx_y(gx_vtx_y),
	.vtx_color(gx_vtx_color),
	.vtx_poly(gx_vtx_poly),
	.px_valid(px3_valid),
	.px_addr(px3_addr),
	.px_rgb555(px3_rgb555),
	.px_ready(px3_ready)
);
`else
	// 3D pipeline compiled out: the GXFIFO port reads as zero and the
	// rasteriser presents no pixels, so the arbiter's 3D port stays idle.
	assign gx_rdata      = 32'd0;
	assign gx_vtx_valid  = 1'b0;
	assign gx_vtx_x      = 32'sd0;
	assign gx_vtx_y      = 32'sd0;
	assign gx_vtx_color  = 8'd0;
	assign gx_vtx_poly   = 2'd0;
	assign px3_valid     = 1'b0;
	assign px3_addr      = 16'd0;
	assign px3_rgb555    = 16'd0;
`endif

vram_arbiter vram_arbiter (
	.clk(clk_sys),
	.reset(reset),
	.reg_we(bus_vramcnt_we),
	.reg_addr(bus_vramcnt_addr),
	.reg_data(bus_vramcnt_data),
	.cpu_req(bus_vram_req),
	.cpu_wr(bus_vram_wr),
	.cpu_addr(bus_vram_addr),
	.cpu_wdata(bus_vram_wdata),
	.cpu_ready(bus_vram_valid),
	.cpu_rdata(bus_vram_rdata),
	.a_req(ea_v_req),
	.a_addr(ea_v_addr),
	.a_len(ea_v_len),
	.a_ready(ea_v_ready),
	.a_bs_valid(ea_v_bs_valid),
	.a_bs_data(ea_v_bs_data),
	.b_req(eb_v_req),
	.b_addr(eb_v_addr),
	.b_len(eb_v_len),
	.b_ready(eb_v_ready),
	.b_bs_valid(eb_v_bs_valid),
	.b_bs_data(eb_v_bs_data),
	.v_req(v2a_req),
	.v_wr(v2a_wr),
	.v_addr(v2a_addr),
	.v_wdata(v2a_wdata),
	.v_be(v2a_be),
	.v_bst(v2a_bst),
	.v_len(v2a_len),
	.v_step(v2a_step),
	.v_ready(v2a_ready),
	.v_rdata(v2a_rdata),
	.v_bs_valid(arb_bs_valid),
	.v_bs_data(arb_bs_data),
	.g3_req(px3_valid),
	.g3_addr({px3_addr, 1'b0}),   // byte offset into the 256x192 frame
	.g3_wdata(px3_rgb555),
	.g3_ready(px3_ready),
	.g3r_req(ea_d3_req),
	.g3r_addr(ea_d3_addr),        // same frame address space as the rasterizer
	.g3r_len(ea_d3_len),
	.g3r_ready(ea_d3_ready),
	.g3r_bs_valid(ea_d3_bs_valid),
	.g3r_bs_data(ea_d3_bs_data)
);

//------------------------------------------------------------------
// DMA: four channels against the shared fabric; immediate runs on
// the enable write, vblank/hblank on the sync edges (M2). Special
// timing (capture/GX FIFO) lands with M3/M5.
//
// The transfer engine runs on the ARM7's clock enable (`.ce`), because the
// DMA is ARM7 hardware and its rate should follow that CPU's: one bus beat per
// ARM7 cycle, whatever the OSD's CPU overclock row is doing.
//------------------------------------------------------------------
dma_engine dma_engine (
	.clk(clk_sys),
	.reset(reset),
	.ce(ce7),
	.reg_we(dma_reg_we),
	.reg_addr(dma_reg_addr),
	.reg_data(dma_reg_data),
	.reg_rd_addr(dma_reg_rd_addr),
	.reg_rdata(dma_reg_rdata),
	.d_addr(dma_addr),
	.d_wdata(dma_wdata),
	.d_be(dma_be),
	.d_rd(dma_rd),
	.d_wr(dma_wr),
	.d_ready(dma_ready),
	.d_rdata(dma_rdata),
	.vblank(vblank_t),
	.hblank(hblank_t),
	.irq_set(dma_irq)
);

`ifndef NDS_NO_CHEAT
cheat_engine cheat_engine (
	.clk(clk_sys),
	.reset(reset),
	.f2_wr(f2_wr),
	.f2_dout(f2_dout),
	.f2_dl(cheat_dl),
	.clr_cheats(status[125]),   // OSD: Disable all cheats (until next load)
	.chk_en(cheat_chk_en),
	.chk_addr(cheat_chk_addr),
	.chk_word(cheat_chk_word),
	.hit(cheat_hit),
	.patch(cheat_patch),
	.patch_hi_en(cheat_patch_hi_en),
	.patch_hi(cheat_patch_hi),
	.chk_ready(cheat_ready)
);
`else
	// cheat engine compiled out (NDS_NO_CHEAT): no patching, always ready
	assign cheat_hit         = 1'b0;
	assign cheat_patch       = 16'd0;
	assign cheat_patch_hi_en = 1'b0;
	assign cheat_patch_hi    = 16'd0;
	assign cheat_ready       = 1'b1;
`endif

//------------------------------------------------------------------
// CPUs
//
// The ARM7 is the real core: it fetches, decodes and executes through the
// same master port the fabric serves, booting from the active slot's cart
// header entry point (0x34) instead of a BIOS, with the firmware's stack.
// It is held in reset while the slot is empty, because there is nothing to
// run — and a core that spins through the HLE BIOS would only steal bus
// cycles from the engines.
//
// The ARM9 is the sibling core and the DS's primary CPU: it fetches, decodes
// and executes through its own master port, booting from the active slot's ARM9
// entry point (cart header 0x24) with the stack the firmware leaves behind, and
// held in reset with the ARM7 while the slot is empty.
//
// HALTCNT (0x04000301) is one register with a per-CPU meaning -- the ARM7
// halts, the ARM9 sleeps -- and this core models the single halt request it
// carries: whichever CPU wrote it stops until one of its own enabled
// interrupts arrives.
//
// The two cores run at the DS's 2:1 ratio, which `cpu_ce` produces as clock
// enables on this single clk_sys domain (67.02 vs 33.51 MHz: the ARM9 every
// cycle, the ARM7 every second one), and each core reaches the fabric through
// `cpu_ce_bridge` so that a response arriving on a gated-off cycle is held
// rather than lost. Which pattern is used is the OSD's CPU overclock row.
// `ce7` also clocks the ARM7-domain peripherals (the timers and the DMA
// engine) so that their timing follows the CPU's rate; the RTC's crystal and
// the 48 kHz audio deliberately stay on absolute time.
//------------------------------------------------------------------
// The mode the CPUs actually get: the manual row, or the per-game reference
// that the loaded cart's game code selects (rtl/cpu/oc_lookup.sv).
wire [1:0] oc_eff;

oc_lookup oc_lookup (
	.manual(oc_mode),
	.auto_on(auto_oc),
	.code(slot_code),
	.mode(oc_eff)
);

cpu_ce cpu_ce (
	.clk(clk_sys),
	.mode(oc_eff),
	.ce9(ce9),
	.ce7(ce7)
);

wire [31:0] m9_addr, m9_wdata;
wire  [3:0] m9_be;
wire        m9_rd, m9_wr;
wire [31:0] m9_rdata;
wire        m9_ready;
wire        m9_halted, m9_thumb;
wire [31:0] m9_pc;

// the cores' own side of the bridges
wire [31:0] c9_addr, c9_wdata, c9_rdata, c7_addr, c7_wdata, c7_rdata;
wire  [3:0] c9_be, c7_be;
wire        c9_rd, c9_wr, c9_ready, c7_rd, c7_wr, c7_ready;

wire        irq9_cpu, irq7_cpu;   // IME & IE & IF, per CPU bank
wire        arm7_halt;            // the shared HALTCNT bit 7 request

wire [31:0] m7_addr;
wire [31:0] m7_wdata;
wire  [3:0] m7_be;
wire        m7_rd;
wire        m7_wr;
wire [31:0] m7_rdata;
wire        m7_ready;
wire        m7_halted, m7_thumb;
wire [31:0] m7_pc;

//------------------------------------------------------------------
// The BIOS SWI bank: one engine, arbitrated between the two cores
//
// It used to be one engine inside each core (2,784 combinational ALUTs in the
// mapper's per-entity table). One shared copy halves that; the arbiter hands
// it to whichever core is waiting and routes its bus access onto *that* core's
// master, so Halt and IntrWait still read the caller's own IE/IF.
//------------------------------------------------------------------
wire        hle9_go, hle9_done, hle9_handled, hle9_wr0, hle9_wr1, hle9_wr3;
wire  [7:0] hle9_num;
wire [31:0] hle9_r0, hle9_r1, hle9_r2, hle9_r3;
wire [31:0] hle9_res0, hle9_res1, hle9_res3;
wire        hle9_b_req, hle9_b_wr, hle9_b_ack;
wire [31:0] hle9_b_addr, hle9_b_wlane, hle9_b_rdata;
wire  [3:0] hle9_b_be;

wire        hle7_go, hle7_done, hle7_handled, hle7_wr0, hle7_wr1, hle7_wr3;
wire  [7:0] hle7_num;
wire [31:0] hle7_r0, hle7_r1, hle7_r2, hle7_r3;
wire [31:0] hle7_res0, hle7_res1, hle7_res3;
wire        hle7_b_req, hle7_b_wr, hle7_b_ack;
wire [31:0] hle7_b_addr, hle7_b_wlane, hle7_b_rdata;
wire  [3:0] hle7_b_be;

`ifndef NDS_NO_SWI_HLE
swi_share swi_share (
	.clk(clk_sys), .reset(reset),
	.ce9(ce9), .ce7(ce7),
	.c9_go(hle9_go), .c9_num(hle9_num),
	.c9_r0(hle9_r0), .c9_r1(hle9_r1), .c9_r2(hle9_r2), .c9_r3(hle9_r3),
	.c9_done(hle9_done), .c9_handled(hle9_handled),
	.c9_res0(hle9_res0), .c9_res1(hle9_res1), .c9_res3(hle9_res3),
	.c9_wr0(hle9_wr0), .c9_wr1(hle9_wr1), .c9_wr3(hle9_wr3),
	.c9_b_req(hle9_b_req), .c9_b_wr(hle9_b_wr), .c9_b_be(hle9_b_be),
	.c9_b_addr(hle9_b_addr), .c9_b_wlane(hle9_b_wlane),
	.c9_b_ack(hle9_b_ack), .c9_b_rdata(hle9_b_rdata),
	.c7_go(hle7_go), .c7_num(hle7_num),
	.c7_r0(hle7_r0), .c7_r1(hle7_r1), .c7_r2(hle7_r2), .c7_r3(hle7_r3),
	.c7_done(hle7_done), .c7_handled(hle7_handled),
	.c7_res0(hle7_res0), .c7_res1(hle7_res1), .c7_res3(hle7_res3),
	.c7_wr0(hle7_wr0), .c7_wr1(hle7_wr1), .c7_wr3(hle7_wr3),
	.c7_b_req(hle7_b_req), .c7_b_wr(hle7_b_wr), .c7_b_be(hle7_b_be),
	.c7_b_addr(hle7_b_addr), .c7_b_wlane(hle7_b_wlane),
	.c7_b_ack(hle7_b_ack), .c7_b_rdata(hle7_b_rdata),
	.busy(), .owner()
);
`else
// BIOS SWI bank compiled out (NDS_NO_SWI_HLE): no HLE at all, so every BIOS
// call vectors to the (absent) BIOS and hangs. A measurement switch only --
// it prices the bank, it is not a usable configuration.
assign hle9_done    = 1'b0;
assign hle9_handled = 1'b0;
assign hle9_res0    = 32'd0;
assign hle9_res1    = 32'd0;
assign hle9_res3    = 32'd0;
assign hle9_b_req   = 1'b0;
assign hle9_b_wr    = 1'b0;
assign hle9_b_be    = 4'd0;
assign hle9_b_addr  = 32'd0;
assign hle9_b_wlane = 32'd0;
assign hle9_b_rdata = 32'd0;
assign hle7_done    = 1'b0;
assign hle7_handled = 1'b0;
assign hle7_res0    = 32'd0;
assign hle7_res1    = 32'd0;
assign hle7_res3    = 32'd0;
assign hle7_b_req   = 1'b0;
assign hle7_b_wr    = 1'b0;
assign hle7_b_be    = 4'd0;
assign hle7_b_addr  = 32'd0;
assign hle7_b_wlane = 32'd0;
assign hle7_b_rdata = 32'd0;
`endif

wire cart_present = slot_valid[active_game_slot];
wire arm7_reset   = reset | ~cart_present;
wire arm9_reset   = reset | ~cart_present;

arm9_core arm9 (
	.clk(clk_sys),
	.reset(arm9_reset),
	.ce(ce9),                         // 67 MHz side of the DS's 2:1
	.boot_pc(slot9_entry),
	.boot_sp(32'h0300_2F7C),          // GBATEK: where the firmware leaves SP
	.bus_addr(c9_addr),
	.bus_wdata(c9_wdata),
	.bus_be(c9_be),
	.bus_rd(c9_rd),
	.bus_wr(c9_wr),
	.bus_rdata(c9_rdata),
	.bus_ready(c9_ready),
	.irq(irq9_cpu),
	.fiq(1'b0),
	.halt(arm7_halt),
	.halted(m9_halted),
	.thumb_state(m9_thumb),
	.pc_out(m9_pc),
	.hle_go(hle9_go), .hle_num(hle9_num),
	.hle_r0(hle9_r0), .hle_r1(hle9_r1), .hle_r2(hle9_r2), .hle_r3(hle9_r3),
	.hle_done(hle9_done), .hle_handled(hle9_handled),
	.hle_res0(hle9_res0), .hle_res1(hle9_res1), .hle_res3(hle9_res3),
	.hle_wr0(hle9_wr0), .hle_wr1(hle9_wr1), .hle_wr3(hle9_wr3),
	.hle_b_req(hle9_b_req), .hle_b_wr(hle9_b_wr), .hle_b_be(hle9_b_be),
	.hle_b_addr(hle9_b_addr), .hle_b_wlane(hle9_b_wlane),
	.hle_b_ack(hle9_b_ack), .hle_b_rdata(hle9_b_rdata)
);

cpu_ce_bridge bus9 (
	.clk(clk_sys), .ce(ce9),
	.core_addr(c9_addr), .core_wdata(c9_wdata), .core_be(c9_be),
	.core_rd(c9_rd), .core_wr(c9_wr),
	.core_rdata(c9_rdata), .core_ready(c9_ready),
	.bus_addr(m9_addr), .bus_wdata(m9_wdata), .bus_be(m9_be),
	.bus_rd(m9_rd), .bus_wr(m9_wr),
	.bus_rdata(m9_rdata), .bus_ready(m9_ready)
);

arm7_core arm7 (
	.clk(clk_sys),
	.reset(arm7_reset),
	.ce(ce7),                         // 33.5 MHz side: every second cycle
	.boot_pc(slot7_entry),
	.boot_sp(32'h0380_FD80),          // GBATEK: where the firmware leaves SP
	.bus_addr(c7_addr),
	.bus_wdata(c7_wdata),
	.bus_be(c7_be),
	.bus_rd(c7_rd),
	.bus_wr(c7_wr),
	.bus_rdata(c7_rdata),
	.bus_ready(c7_ready),
	.irq(irq7_cpu),
	.fiq(1'b0),
	.halt(arm7_halt),
	.halted(m7_halted),
	.thumb_state(m7_thumb),
	.pc_out(m7_pc),
	.hle_go(hle7_go), .hle_num(hle7_num),
	.hle_r0(hle7_r0), .hle_r1(hle7_r1), .hle_r2(hle7_r2), .hle_r3(hle7_r3),
	.hle_done(hle7_done), .hle_handled(hle7_handled),
	.hle_res0(hle7_res0), .hle_res1(hle7_res1), .hle_res3(hle7_res3),
	.hle_wr0(hle7_wr0), .hle_wr1(hle7_wr1), .hle_wr3(hle7_wr3),
	.hle_b_req(hle7_b_req), .hle_b_wr(hle7_b_wr), .hle_b_be(hle7_b_be),
	.hle_b_addr(hle7_b_addr), .hle_b_wlane(hle7_b_wlane),
	.hle_b_ack(hle7_b_ack), .hle_b_rdata(hle7_b_rdata)
);

cpu_ce_bridge bus7 (
	.clk(clk_sys), .ce(ce7),
	.core_addr(c7_addr), .core_wdata(c7_wdata), .core_be(c7_be),
	.core_rd(c7_rd), .core_wr(c7_wr),
	.core_rdata(c7_rdata), .core_ready(c7_ready),
	.bus_addr(m7_addr), .bus_wdata(m7_wdata), .bus_be(m7_be),
	.bus_rd(m7_rd), .bus_wr(m7_wr),
	.bus_rdata(m7_rdata), .bus_ready(m7_ready)
);

//------------------------------------------------------------------
// Audio: the sixteen-channel SPU (M4) -> audio filter -> I2S
//
// The SPU mixes the channels at 48 kHz and raises sample_tick, which is the
// audio filter's sample strobe (previously once per frame). Its sample
// fetches are the fourth SDRAM-arbiter master, below the CPUs and the
// engines.
//------------------------------------------------------------------
wire [15:0] spu_l, spu_r;
wire        spu_tick;

`ifndef NDS_NO_SPU
spu spu (
	.clk(clk_sys),
	.reset(reset),
	.reg_acc(spu_reg_acc),
	.reg_we(spu_reg_we),
	.reg_addr(spu_reg_addr),
	.reg_wdata(spu_reg_wdata),
	.reg_rdata(spu_reg_rdata),
	.mem_req(spu_mem_req),
	.mem_addr(spu_mem_addr),
	.mem_ready(spu_mem_ready),
	.mem_rdata(spu_mem_rdata),
	.volume(volume),
	.mix_mode(mix_mode),
	.sample_tick(spu_tick),
	.audio_l(spu_l),
	.audio_r(spu_r)
);
`else
	// SPU compiled out (NDS_NO_SPU): silence, and no fourth arbiter master
	assign spu_l        = 16'd0;
	assign spu_r        = 16'd0;
	assign spu_tick     = 1'b0;
	assign spu_reg_rdata= 16'd0;
	assign spu_mem_req  = 1'b0;
	assign spu_mem_addr = 25'd0;
`endif

wire [15:0] spu_f_l, spu_f_r;

audio_filter audio_filter (
	.clk(clk_sys),
	.reset(reset),
	.strobe(spu_tick),
	.mode(afilter),
	.width(stereo_width),
	.in_l(spu_l),
	.in_r(spu_r),
	.out_l(spu_f_l),
	.out_r(spu_f_r)
);

//------------------------------------------------------------------
// MIDI / MT-32-pi
//
// MT-32-pi hangs off the user port: MIDI out on USER_OUT[1], its I2S
// return on USER_IN, and the little I2C display bus on USER_OUT[0] /
// USER_IN[3] (handled inside sys/mt32pi.sv, including the crossed-cable
// detect). The DS has no MIDI hardware, so the core repurposes the AUX
// SPI port at 0x04000150 — where a DS sequencer or homebrew would write
// bytes — and midi_port turns those writes into 31.25 kbaud serial. The
// return audio arrives at 48 kHz and audio_mix sums it with the SPU.
//------------------------------------------------------------------
wire        midi_wr, midi_rd, midi_tx_serial, midi_rx_serial;
wire [15:0] midi_addr, midi_wdata, midi_rdata;
wire [15:0] mt32_i2s_l, mt32_i2s_r;
wire        mt32_available, mt32_newmode;
wire  [7:0] mt32_mode, mt32_rom, mt32_sf;
wire        mt32_lcd_en, mt32_lcd_pix, mt32_lcd_update;

// 48 kHz tick for the MIDI bit clock: 48000 against the 67.0274 MHz core
// clock, accumulated so the baud period carries no rounding error (1536 ticks
// per bit at 31.25 kbaud).
reg  [26:0] midi_acc  = 27'd0;
reg         midi_tick = 1'b0;
wire [26:0] midi_acc_n = midi_acc + 27'd48000;
always @(posedge clk_sys) begin
	midi_tick <= 1'b0;
	if (midi_acc_n >= 27'd67_027_400) begin
		midi_acc  <= midi_acc_n - 27'd67_027_400;
		midi_tick <= 1'b1;
	end else begin
		midi_acc <= midi_acc_n;
	end
end

midi_port midi_port (
	.clk(clk_sys),
	.reset(reset),
	.tick_48k(midi_tick),
	.wr(midi_wr),
	.rd(midi_rd),
	.addr(midi_addr),
	.wdata(midi_wdata),
	.rdata(midi_rdata),
	.tx(midi_tx_serial),
	.tx_busy(),
	.rx(midi_rx_serial),
	.demo_en(midi_demo),
	.demo_restart(1'b0)
);

// The Pi reads its mode/ROM/soundfont request once, when it starts, so a
// change made in the OSD has to make it look again: mt32_select holds the
// module in reset for a moment after a change, which the slave turns into
// the 0xA0 reload reply, and the Pi then boots with the new request.
wire       mt32_mode_sf, mt32_restart;
wire [7:0] mt32_sf_index;

mt32_select mt32_select (
	.clk(clk_sys),
	.reset(reset),
	.sf_bank(sf_bank),
	.synth(midi_synth),
	.mode_sf(mt32_mode_sf),
	.sf_index(mt32_sf_index),
	.restart(mt32_restart)
);

mt32pi mt32pi (
	.CLK_AUDIO(CLK_AUDIO),
	.CLK_VIDEO(clk_sys),
	.CE_PIXEL(clk_pix_ce),
	.VGA_VS(pix_vs),
	.VGA_DE(pix_de),
	.USER_IN(USER_IN),
	.USER_OUT(USER_OUT),
	.reset(reset | mt32_restart),
	// the line idles high (MIDI stop state) while the option is off
	.midi_tx(mt32_enable ? midi_tx_serial : 1'b1),
	.midi_rx(midi_rx_serial),
	.mt32_i2s_r(mt32_i2s_r),
	.mt32_i2s_l(mt32_i2s_l),
	.mt32_available(mt32_available),
	// the OSD decides which engine and which soundfont the Pi loads
	.mt32_mode_req(mt32_mode_sf),      // 0xA1 = MT-32, 0xA2 = SoundFont
	.mt32_rom_req(2'd0),               // Pi's default control ROM
	.mt32_sf_req(mt32_sf_index),
	.mt32_mode(mt32_mode),
	.mt32_rom(mt32_rom),
	.mt32_sf(mt32_sf),
	.mt32_newmode(mt32_newmode),
	.mt32_lcd_en(mt32_lcd_en),
	.mt32_lcd_pix(mt32_lcd_pix),
	.mt32_lcd_update(mt32_lcd_update)
);

audio_mix audio_mix (
	.clk_audio(CLK_AUDIO),
	.reset(reset),
	.spu_l(spu_f_l),
	.spu_r(spu_f_r),
	.mt32_l(mt32_i2s_l),
	.mt32_r(mt32_i2s_r),
	.mt32_en(mt32_enable),
	.mt32_vol(midi_volume),
	.out_l(AUDIO_L),
	.out_r(AUDIO_R)
);

//------------------------------------------------------------------
// User LED: cart activity, or the bus-activity option from diagnostics
//------------------------------------------------------------------
reg [24:0] led_cnt = 0;
always @(posedge clk_sys) led_cnt <= led_cnt + 1'd1;
assign LED_USER = bus_leds ? led_cnt[22] : (ioctl_download ? led_cnt[20] : led_cnt[24]);

// Unused-in-skeleton outputs
wire _unused = &{1'b0, aspect, bios_real, bios9_real, fw_dump, auto_start,
                 slot2, region, rumble, pad_profile, core_speed, frameskip,
                 autoskip, rewind_buf, show_fps, frame_graph, log_level,
                 i2s_latency,
                 spu_sync, ps2_key, img_mounted, img_size, cart_loaded,
                 rom_bytes, slot_load, m9_rdata, m7_pc, m7_halted, m7_thumb,
                 dispcnt_a, dispcnt_b,
                 irq_me, irq_en, irq_fl, sd_rd, sd_wr,
                 sd_buff_dout, sd_buff_addr, sd_buff_wr, sd_ack,	                 mt32_mode, mt32_rom, mt32_sf, mt32_newmode,
	                 mt32_lcd_update,
                 HDMI_WIDTH, HDMI_HEIGHT, 1'b0};
	// Read the sink so the analyser does not call it "assigned but never read"
	// (warning 10036). The branch cannot be taken and synthesises to nothing:
	// measured on a throwaway module, the warning goes from 1 to 0 with this
	// line and the netlist is unchanged.
	always @(*) if (_unused) begin end


endmodule
