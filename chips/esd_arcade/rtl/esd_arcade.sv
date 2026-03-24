// =============================================================================
// esd_arcade.sv — ESD 16-bit Arcade System Top-Level
// =============================================================================
//
// Hardware reference: MAME src/mame/misc/esd16.cpp
//   Main CPU  : MC68000 @ 16 MHz, IRQ6 = VBlank (autovector)
//   Sound CPU : Z80 @ 4 MHz
//   Sound     : YM3812 (OPL2) + OKI M6295
//   Video     : 2 scrolling BG layers (8x8x8bpp or 16x16x8bpp, switchable)
//               + DECO-compatible sprite engine (16x16x5bpp, 256 sprites)
//               ESD CRTC99 or 2x Actel A40MX04 FPGAs
//   Screen    : 320x224 visible @ 60 Hz
//
// Memory map (multchmp_map — reference game Multi Champ):
//   0x000000-0x07FFFF  Program ROM (512KB, SDRAM)
//   0x100000-0x10FFFF  Work RAM (64KB, BRAM)
//   0x200000-0x200FFF  Palette RAM (2KB = 512 x 16-bit xRGB_555)
//   0x300000-0x3007FF  Sprite RAM (2KB = 0x400 x 16-bit, mirrored)
//   0x400000-0x43FFFF  BG VRAM (layer0: 0x3FFF words, layer1: offset 0x10000)
//   0x500000-0x50000F  Video attribute registers (scroll, platform, layersize)
//   0x600000-0x60000F  I/O (joystick, coin, DIP, tilemap color, sound cmd)
//
// Priority: Layer 0 (back) -> Layer 1 -> Sprites (front unless sprite[15] set)
//
// =============================================================================
`default_nettype none

/* verilator lint_off SYNCASYNCNET */
module esd_arcade #(
    parameter int unsigned WRAM_ABITS = 15,   // 64KB = 32K words
    parameter int unsigned PAL_ABITS  = 9,    // 512 entries
    parameter int unsigned SPR_ABITS  = 10,   // 1024 entries (0x400)
    parameter int unsigned VRAM_ABITS = 14,   // 16K words per layer
    parameter logic [26:0] PROG_ROM_BASE = 27'h000000,
    parameter logic [26:0] SPR_ROM_BASE  = 27'h080000,
    parameter logic [26:0] BG_ROM_BASE   = 27'h280000
) (
    // Clocks / Reset
    input  logic        clk_sys,
    input  logic        clk_pix,   // 1-cycle pixel clock enable in clk_sys domain
    input  logic        reset_n,   // Active-low async reset (from MiSTer framework)

    // MC68000 CPU Bus (driven by emu.sv / fx68k wrapper)
    input  logic [23:1] cpu_addr,
    input  logic [15:0] cpu_din,
    output logic [15:0] cpu_dout,
    input  logic        cpu_lds_n,
    input  logic        cpu_uds_n,
    input  logic        cpu_rw,
    input  logic        cpu_as_n,
    input  logic  [2:0] cpu_fc,    // FC[2:0] for IACK detection
    output logic        cpu_dtack_n,
    output logic  [2:0] cpu_ipl_n, // Active-low IPL[2:0]

    // Program ROM SDRAM Interface
    output logic [26:0] prog_rom_addr,
    input  logic [15:0] prog_rom_data,
    output logic        prog_rom_req,
    input  logic        prog_rom_ack,

    // Sprite ROM SDRAM Interface
    output logic [26:0] spr_rom_addr,
    input  logic [15:0] spr_rom_data,
    output logic        spr_rom_req,
    input  logic        spr_rom_ack,

    // BG Tile ROM SDRAM Interface
    output logic [26:0] bg_rom_addr,
    input  logic [15:0] bg_rom_data,
    output logic        bg_rom_req,
    input  logic        bg_rom_ack,

    // Video Output
    output logic  [7:0] rgb_r,
    output logic  [7:0] rgb_g,
    output logic  [7:0] rgb_b,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,

    // Audio (stub — silence until sound subsystem implemented)
    output logic [15:0] audio_l,
    output logic [15:0] audio_r,

    // Joystick (active low: [5:0]=UDLRBA, [7]=Start, [8]=Coin)
    input  logic  [9:0] joystick_0,
    input  logic  [9:0] joystick_1,

    // DIP switches
    input  logic [15:0] dip_sw,

    // ROM download interface (ioctl)
    input  logic        ioctl_download,
    input  logic [26:0] ioctl_addr,
    input  logic [15:0] ioctl_dout,
    input  logic        ioctl_wr,
    input  logic  [7:0] ioctl_index,
    output logic        ioctl_wait
);

// =============================================================================
// Reset synchronizer (2FF, async assert / sync deassert)
// =============================================================================

logic rst, rst_r1, rst_r2;
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        rst_r1 <= 1'b1;
        rst_r2 <= 1'b1;
    end else begin
        rst_r1 <= 1'b0;
        rst_r2 <= rst_r1;
    end
end
assign rst = rst_r2;

// =============================================================================
// Video Timing (320x264 total, 320x224 visible)
// =============================================================================

logic [9:0] hcnt;
logic [8:0] vcnt;
logic hblank_r, vblank_r, hsync_r, vsync_r;
logic hblank_prev, vblank_prev;

always_ff @(posedge clk_sys or posedge rst) begin
    if (rst) begin
        hcnt       <= '0;
        vcnt       <= '0;
        hblank_r   <= 1'b1;
        vblank_r   <= 1'b1;
        hsync_r    <= 1'b1;
        vsync_r    <= 1'b1;
        hblank_prev <= 1'b0;
        vblank_prev <= 1'b0;
    end else if (clk_pix) begin
        hblank_prev <= hblank_r;
        vblank_prev <= vblank_r;
        // Horizontal counter
        if (hcnt == 10'd383) begin
            hcnt <= '0;
            if (vcnt == 9'd263)
                vcnt <= '0;
            else
                vcnt <= vcnt + 1'b1;
        end else begin
            hcnt <= hcnt + 1'b1;
        end
        // Blanking — active region 0..319 h, 0..223 v
        hblank_r <= (hcnt >= 10'd319);
        vblank_r <= (vcnt >= 9'd224);
        // Sync pulses
        hsync_r  <= ~(hcnt >= 10'd336 && hcnt < 10'd368);
        vsync_r  <= ~(vcnt >= 9'd234  && vcnt < 9'd238);
    end
end

assign hblank  = hblank_r;
assign vblank  = vblank_r;
assign hsync_n = hsync_r;
assign vsync_n = vsync_r;

wire vblank_rising = vblank_r & ~vblank_prev;

// =============================================================================
// IACK Detection (COMMUNITY_PATTERNS.md Section 1.2)
// =============================================================================

wire inta_n = ~&{cpu_fc[2], cpu_fc[1], cpu_fc[0], ~cpu_as_n};

// =============================================================================
// VBlank Interrupt — IRQ6 (IACK-based set/clear latch per community pattern)
// Level 6 active = IPL[2:0] = 3'b001 (all other bits 1, LSB=0 → not level 1)
// =============================================================================

logic int6_n;
always_ff @(posedge clk_sys or posedge rst) begin
    if (rst) begin
        int6_n <= 1'b1;
    end else begin
        if (!inta_n)
            int6_n <= 1'b1;       // Clear on CPU interrupt acknowledge
        else if (vblank_rising)
            int6_n <= 1'b0;       // Assert on VBlank rising edge
    end
end

// IPL synchronizer (prevents Verilator delta-cycle late-sample)
logic [2:0] ipl_sync;
always_ff @(posedge clk_sys or posedge rst) begin
    if (rst)
        ipl_sync <= 3'b111;
    else
        ipl_sync <= int6_n ? 3'b111 : 3'b001; // Level 6: IPL[2:1]=1, IPL[0]=0 wait
        // Actually: Level 6 means IPL active-low = ~6 = 001 in 3-bit
        // IPL[2:0] encodes level as: ~level on 3 bits
        // Level 6 = 3'b110 inverted = 3'b001
end
assign cpu_ipl_n = ipl_sync;

// =============================================================================
// Address Decode — Registered chip selects (COMMUNITY_PATTERNS.md Section 1.4)
// =============================================================================

wire [23:0] byte_addr = {cpu_addr, 1'b0};

// nopr_cs: 0x700000-0x7FFFFF — per MAME esd16.cpp multchmp_map:
//   0x700008-0x70000B are "nopr" (no-op read) protection check dummies.
//   Map the entire 0x700000 page as a catch-all that returns 0xFFFF and
//   asserts DTACK to prevent CPU stall.
logic rom_cs, wram_cs, pal_cs, spr_cs, vram_cs, vidattr_cs, io_cs, nopr_cs;

always_ff @(posedge clk_sys or posedge rst) begin
    if (rst) begin
        rom_cs     <= 1'b0;
        wram_cs    <= 1'b0;
        pal_cs     <= 1'b0;
        spr_cs     <= 1'b0;
        vram_cs    <= 1'b0;
        vidattr_cs <= 1'b0;
        io_cs      <= 1'b0;
        nopr_cs    <= 1'b0;
    end else if (!cpu_as_n) begin
        rom_cs     <= (byte_addr[23:19] == 5'b00000);           // 0x000000-0x07FFFF
        wram_cs    <= (byte_addr[23:16] == 8'h10);              // 0x100000-0x10FFFF
        pal_cs     <= (byte_addr[23:16] == 8'h20);              // 0x200000-0x20FFFF
        spr_cs     <= (byte_addr[23:16] == 8'h30);              // 0x300000-0x30FFFF
        vram_cs    <= (byte_addr[23:18] == 6'b010000);          // 0x400000-0x43FFFF
        vidattr_cs <= (byte_addr[23:16] == 8'h50);              // 0x500000-0x50FFFF
        io_cs      <= (byte_addr[23:16] == 8'h60);              // 0x600000-0x60FFFF
        nopr_cs    <= (byte_addr[23:16] == 8'h70);              // 0x700000-0x70FFFF (nopr)
    end else begin
        rom_cs     <= 1'b0;
        wram_cs    <= 1'b0;
        pal_cs     <= 1'b0;
        spr_cs     <= 1'b0;
        vram_cs    <= 1'b0;
        vidattr_cs <= 1'b0;
        io_cs      <= 1'b0;
        nopr_cs    <= 1'b0;
    end
end

// Byte-granular write enables (COMMUNITY_PATTERNS.md Section 1.6)
wire cpu_wr  = ~cpu_rw;
wire cpu_wru = cpu_wr & ~cpu_uds_n;
wire cpu_wrl = cpu_wr & ~cpu_lds_n;

// =============================================================================
// DTACK Generation (1 wait-state minimum, stall on ROM SDRAM)
// =============================================================================

logic dtack_delay, dtack_n_r;
wire  bus_cs   = |{rom_cs, wram_cs, pal_cs, spr_cs, vram_cs, vidattr_cs, io_cs, nopr_cs};
wire  bus_busy = rom_cs & ~prog_rom_ack;

always_ff @(posedge clk_sys or posedge rst) begin
    if (rst) begin
        dtack_delay <= 1'b0;
        dtack_n_r   <= 1'b1;
    end else begin
        if (cpu_as_n) begin
            dtack_delay <= 1'b0;
            dtack_n_r   <= 1'b1;
        end else if (bus_cs) begin
            dtack_delay <= 1'b1;
            if (dtack_delay && !bus_busy)
                dtack_n_r <= 1'b0;
        end
    end
end
assign cpu_dtack_n = dtack_n_r;

// =============================================================================
// Program ROM SDRAM Request
// =============================================================================

logic prog_rom_pending;
always_ff @(posedge clk_sys or posedge rst) begin
    if (rst) begin
        prog_rom_req     <= 1'b0;
        prog_rom_addr    <= PROG_ROM_BASE;
        prog_rom_pending <= 1'b0;
    end else begin
        if (rom_cs && cpu_rw && !prog_rom_pending && !cpu_as_n) begin
            prog_rom_req     <= 1'b1;
            prog_rom_addr    <= PROG_ROM_BASE + {3'b0, cpu_addr, 1'b0};
            prog_rom_pending <= 1'b1;
        end else if (prog_rom_ack) begin
            prog_rom_req     <= 1'b0;
            prog_rom_pending <= 1'b0;
        end
    end
end

// =============================================================================
// Work RAM (64KB, dual-port BRAM)
// =============================================================================

logic [15:0] wram [0:(1<<WRAM_ABITS)-1];
logic [15:0] wram_dout;

always_ff @(posedge clk_sys) begin
    if (wram_cs && !cpu_as_n) begin
        if (cpu_wru) wram[cpu_addr[WRAM_ABITS:1]][15:8] <= cpu_din[15:8];
        if (cpu_wrl) wram[cpu_addr[WRAM_ABITS:1]][ 7:0] <= cpu_din[ 7:0];
        wram_dout <= wram[cpu_addr[WRAM_ABITS:1]];
    end
end

// =============================================================================
// Palette RAM (512 x 16-bit xRGB_555)
// =============================================================================

logic [15:0] pal_ram  [0:(1<<PAL_ABITS)-1];
logic [15:0] pal_dout;

// CPU write port
always_ff @(posedge clk_sys) begin
    if (pal_cs && !cpu_as_n) begin
        if (cpu_wru) pal_ram[cpu_addr[PAL_ABITS:1]][15:8] <= cpu_din[15:8];
        if (cpu_wrl) pal_ram[cpu_addr[PAL_ABITS:1]][ 7:0] <= cpu_din[ 7:0];
        pal_dout <= pal_ram[cpu_addr[PAL_ABITS:1]];
    end
end

// Video read port
logic [PAL_ABITS-1:0] vid_pal_addr;
logic [15:0]           vid_pal_data;
always_ff @(posedge clk_sys)
    vid_pal_data <= pal_ram[vid_pal_addr];

// =============================================================================
// Sprite RAM (1024 x 16-bit)
// =============================================================================

logic [15:0] spr_ram  [0:(1<<SPR_ABITS)-1];
logic [15:0] spr_dout;

always_ff @(posedge clk_sys) begin
    if (spr_cs && !cpu_as_n) begin
        if (cpu_wru) spr_ram[cpu_addr[SPR_ABITS:1]][15:8] <= cpu_din[15:8];
        if (cpu_wrl) spr_ram[cpu_addr[SPR_ABITS:1]][ 7:0] <= cpu_din[ 7:0];
        spr_dout <= spr_ram[cpu_addr[SPR_ABITS:1]];
    end
end

logic [SPR_ABITS-1:0] vid_spr_addr;
logic [15:0]           vid_spr_data;
always_ff @(posedge clk_sys)
    vid_spr_data <= spr_ram[vid_spr_addr];

// =============================================================================
// BG VRAM (2 layers x 16K words each)
// Layer 0: addr[14]=0, layer 1: addr[14]=1
// byte 0x400000 = word 0 layer 0; byte 0x420000 = word 0 layer 1
// =============================================================================

logic [15:0] bg_vram [0:2*(1<<VRAM_ABITS)-1];
logic [15:0] bg_vram_dout;

// CPU write port
always_ff @(posedge clk_sys) begin
    if (vram_cs && !cpu_as_n) begin
        if (cpu_wru)
            bg_vram[{cpu_addr[VRAM_ABITS], cpu_addr[VRAM_ABITS-1:1]}][15:8] <= cpu_din[15:8];
        if (cpu_wrl)
            bg_vram[{cpu_addr[VRAM_ABITS], cpu_addr[VRAM_ABITS-1:1]}][ 7:0] <= cpu_din[ 7:0];
        bg_vram_dout <= bg_vram[{cpu_addr[VRAM_ABITS], cpu_addr[VRAM_ABITS-1:1]}];
    end
end

logic [VRAM_ABITS:0] vid_vram_addr;
logic [15:0]          vid_vram_data;
always_ff @(posedge clk_sys)
    vid_vram_data <= bg_vram[vid_vram_addr];

// =============================================================================
// Video Attribute Registers
// 0x500000 + offset:
//   +0x0/0x2: scroll[0][X/Y]  — layer 0 scroll
//   +0x4/0x6: scroll[1][X/Y]  — layer 1 scroll
//   +0x8/0xA: platform_x/y    — platform write destination
//   +0xC:     nopw
//   +0xE:     layersize
// =============================================================================

logic [15:0] scroll0_x, scroll0_y;
logic [15:0] scroll1_x, scroll1_y;
logic [15:0] platform_x, platform_y;
logic [15:0] layersize;

always_ff @(posedge clk_sys or posedge rst) begin
    if (rst) begin
        scroll0_x  <= '0; scroll0_y  <= '0;
        scroll1_x  <= '0; scroll1_y  <= '0;
        platform_x <= '0; platform_y <= '0;
        layersize  <= '0;
    end else if (vidattr_cs && cpu_wr && !cpu_as_n) begin
        case (cpu_addr[3:1])
            3'd0: scroll0_x  <= cpu_din;
            3'd1: scroll0_y  <= cpu_din;
            3'd2: scroll1_x  <= cpu_din;
            3'd3: scroll1_y  <= cpu_din;
            3'd4: platform_x <= cpu_din;
            3'd5: platform_y <= cpu_din;
            3'd6: begin end   // nopw
            3'd7: layersize  <= cpu_din;
            default: begin end
        endcase
    end
end

// =============================================================================
// I/O Registers
// 0x600000 + offset (io_area_dsw map):
//   +0x0:     IRQ Ack (nopw)
//   +0x2:     P1_P2 joystick read
//   +0x4:     SYSTEM (coin/start) read
//   +0x6:     DSW read
//   +0x8:     tilemap0_color_w (layer0 palette bank [1:0], flip_screen [7])
//   +0xA:     nopw
//   +0xD byte: sound_command_w (byte at word+6 lower byte)
//   +0xE:     nopw
// =============================================================================

logic [1:0] layer0_color;
logic       flip_screen;
logic [7:0] sound_cmd;
logic       sound_cmd_wr;

always_ff @(posedge clk_sys or posedge rst) begin
    if (rst) begin
        layer0_color <= 2'b00;
        flip_screen  <= 1'b0;
        sound_cmd    <= 8'h00;
        sound_cmd_wr <= 1'b0;
    end else begin
        sound_cmd_wr <= 1'b0;
        if (io_cs && cpu_wr && !cpu_as_n) begin
            case (cpu_addr[3:1])
                3'd0: begin end    // IRQ Ack — handled by IACK detection
                3'd4: begin        // tilemap0_color_w
                    layer0_color <= cpu_din[1:0];
                    flip_screen  <= cpu_din[7];
                end
                3'd5: begin end    // nopw at +0xA
                // sound_command_w: byte 0xD = word addr 6, lower byte
                3'd6: begin
                    if (cpu_wrl) begin
                        sound_cmd    <= cpu_din[7:0];
                        sound_cmd_wr <= 1'b1;
                    end
                end
                3'd7: begin end    // nopw at +0xE
                default: begin end
            endcase
        end
    end
end

// I/O read mux
logic [15:0] io_dout;
always_comb begin
    io_dout = 16'hFFFF;
    case (cpu_addr[3:1])
        // P1_P2: joystick 0 in low byte, joystick 1 in high byte
        // MAME bit layout: [0]=U,[1]=D,[2]=L,[3]=R,[4]=B1,[5]=B2
        3'd1: io_dout = {2'b11, ~joystick_1[5:0], 2'b11, ~joystick_0[5:0]};
        // SYSTEM: coin/start
        3'd2: io_dout = {8'hFF,
                         3'b111,
                         ~joystick_0[8], ~joystick_1[8],  // Coin1, Coin2
                         ~joystick_0[7], ~joystick_1[7],  // Start1, Start2
                         1'b1};
        // DSW
        3'd3: io_dout = dip_sw;
        default: io_dout = 16'hFFFF;
    endcase
end

// =============================================================================
// CPU Data Read Mux (unmapped = 0xFFFF per COMMUNITY_PATTERNS.md Section 1.5)
// =============================================================================

always_comb begin
    cpu_dout = 16'hFFFF;
    if      (rom_cs)     cpu_dout = prog_rom_data;
    else if (wram_cs)    cpu_dout = wram_dout;
    else if (pal_cs)     cpu_dout = pal_dout;
    else if (spr_cs)     cpu_dout = spr_dout;
    else if (vram_cs)    cpu_dout = bg_vram_dout;
    else if (io_cs)      cpu_dout = io_dout;
    // nopr_cs: returns 0xFFFF (default) — protection check dummy, DTACK asserted
end

// =============================================================================
// Video Subsystem
// =============================================================================

esd_video #(
    .VRAM_ABITS (VRAM_ABITS+1),  // +1 for 2 layers
    .PAL_ABITS  (PAL_ABITS),
    .SPR_ABITS  (SPR_ABITS)
) u_video (
    .clk_sys      (clk_sys),
    .clk_pix      (clk_pix),
    .rst          (rst),
    .hcnt         (hcnt),
    .vcnt         (vcnt),
    .hblank       (hblank_r),
    .vblank       (vblank_r),
    .flip_screen  (flip_screen),
    .scroll0_x    (scroll0_x),
    .scroll0_y    (scroll0_y),
    .layer0_color (layer0_color),
    .layersize    (layersize),
    .scroll1_x    (scroll1_x),
    .scroll1_y    (scroll1_y),
    // VRAM read
    .vram_addr    (vid_vram_addr),
    .vram_data    (vid_vram_data),
    // Palette read
    .pal_addr     (vid_pal_addr),
    .pal_data     (vid_pal_data),
    // Sprite RAM read
    .spr_addr     (vid_spr_addr),
    .spr_data     (vid_spr_data),
    // Sprite ROM SDRAM
    .spr_rom_addr (spr_rom_addr),
    .spr_rom_data (spr_rom_data),
    .spr_rom_req  (spr_rom_req),
    .spr_rom_ack  (spr_rom_ack),
    // BG tile ROM SDRAM
    .bg_rom_addr  (bg_rom_addr),
    .bg_rom_data  (bg_rom_data),
    .bg_rom_req   (bg_rom_req),
    .bg_rom_ack   (bg_rom_ack),
    // RGB out
    .rgb_r        (rgb_r),
    .rgb_g        (rgb_g),
    .rgb_b        (rgb_b)
);

// =============================================================================
// Audio (stub — silence)
// =============================================================================

assign audio_l   = 16'h0000;
assign audio_r   = 16'h0000;
assign ioctl_wait = 1'b0;

endmodule
