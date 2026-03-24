// =============================================================================
// seta_arcade.sv — SETA 1 System Board Top-Level Integration
// =============================================================================
//
// MAME driver: seta/seta.cpp
// Target games: Dragon Unit (drgnunit), The Roulette (setaroul), Thunder & Lightning (thunderl)
//
// Instantiated blocks:
//   x1_001a        — Sprite generator (X1-001A), sprite + tilemap rendering
//   palette_ram    — Palette RAM (2KB or 4KB depending on game variant)
//   work_ram       — 64KB work RAM (68000 general-purpose)
//
// NOT instantiated here (provided by the emu.sv MiSTer wrapper):
//   MC68000 CPU (fx68k), Z80 sound CPU, X1-010 audio chip (blocker)
//
// 68000 Memory Map (byte addresses, verified against MAME seta.cpp):
//   Standard map (drgnunit, thunderl, wits, setaroul):
//     0x000000 – 0x0FFFFF    Program ROM     (up to 1MB, SDRAM)
//     0x100000 – 0x103FFF    X1-010 audio    (16KB, stub - blocker chip)
//     0x200000 – 0x2FFFFF    Work RAM        (variant: 64KB, 256KB, or more)
//     0x600000 – 0x600003    DIP switches    (read-only)
//     0x700000 – 0x7003FF    Palette RAM 1   (2KB, 1024 entries × 16-bit)
//     0xA00000 – 0xA005FF    Sprite Y RAM    (X1-001A spriteylow, 1.5KB)
//     0xA00600 – 0xA00607    Sprite ctrl regs(X1-001A spritectrl, 4 × 16-bit)
//     0xB00000 – 0xB00007    Input ports     (P1, P2, coin/service, read-only)
//     0xC00000 – 0xC00001    Watchdog / nop  (write-only)
//     0xE00000 – 0xE03FFF    Sprite code RAM (X1-001A spritecode, 16KB)
//
//   Blandia variant (different WRAM layout):
//     0x000000 – 0x1FFFFF    Program ROM     (2MB)
//     0x200000 – 0x20FFFF    Work RAM        (64KB)
//     0x210000 – 0x21FFFF    Work RAM        (64KB alternate)
//     0x700000 – 0x7003FF    Palette RAM 1   (2KB)
//     0x703C00 – 0x7047FF    Palette RAM 2   (2KB alternate)
//     0x800000 – 0x8005FF    Sprite Y/code RAM (combined layout)
//
// Interrupt routing:
//   68000 IPL (level 1, active-low ~1 = 3'b110): VBlank from video timing.
//
// Parameterised for per-game differences:
//   WRAM_BASE, WRAM_SIZE — work RAM address and size
//   PAL1_ADDR, PAL1_SIZE — palette RAM address and size
//   SPRITE_Y_ADDR, SPRITE_C_ADDR — X1-001A RAM addresses
//
// =============================================================================

`default_nettype none

/* verilator lint_off SYNCASYNCNET */
module seta_arcade #(
    // ── Work RAM Configuration ─────────────────────────────────────────────
    // Standard games (drgnunit, thunderl, wits, setaroul): 0x200000, 64KB
    // Blandia: 0x200000–0x20FFFF + 0x210000–0x21FFFF (two separate 64KB banks)
    parameter logic [23:1] WRAM_BASE  = 23'h100000,  // 0x200000 byte / 2
    parameter int unsigned WRAM_ABITS = 15,          // 2^15 = 32K words = 64KB

    // ── Palette RAM Configuration ──────────────────────────────────────────
    // Standard: 0x700000, 2048 entries × 16-bit (2KB)
    // Blandia: Two palettes (0x700000 + 0x703C00)
    parameter logic [23:1] PAL1_BASE  = 23'h380000,  // 0x700000 byte / 2
    parameter int unsigned PAL1_ABITS = 11,          // 2^11 = 2K words = 4KB

    // ── X1-001A Sprite Configuration ──────────────────────────────────────
    // Sprite Y RAM: standard 0xA00000–0xA005FF (1.5KB, some games 0.5KB)
    // Sprite Code RAM: standard 0xE00000–0xE03FFF (16KB)
    parameter logic [23:1] SRAM_Y_BASE = 23'h500000,  // 0xA00000 byte / 2
    parameter logic [23:1] SRAM_C_BASE = 23'h700000,  // 0xE00000 byte / 2

    // ── Input/Output Configuration ────────────────────────────────────────
    parameter logic [23:1] DIP_BASE    = 23'h300000,  // 0x600000 byte / 2
    parameter logic [23:1] JOY_BASE    = 23'h580000,  // 0xB00000 byte / 2

    // ── Video Timing (384×240 @ 60 Hz standard for most SETA games) ──────
    parameter int unsigned H_VISIBLE  = 384,
    parameter int unsigned H_TOTAL    = 512,
    parameter int unsigned V_VISIBLE  = 240,
    parameter int unsigned V_TOTAL    = 262,

    // ── Sprite chip parameters (game-specific offsets) ───────────────────
    parameter int signed   FG_NOFLIP_YOFFS = 0,  // Y offset when screen normal
    parameter int signed   FG_NOFLIP_XOFFS = 0,  // X offset when screen normal
    parameter int unsigned SPRITE_LIMIT    = 511
) (
    // ── Clocks / Reset ────────────────────────────────────────────────────
    input  logic        clk_sys,        // system clock (e.g. 32 MHz)
    input  logic        clk_pix,        // pixel clock enable (1-cycle strobe)
    input  logic        reset_n,        // active-low async reset

    // ── MC68000 CPU Bus ───────────────────────────────────────────────────
    input  logic [23:1] cpu_addr,       // 68000 word address
    input  logic [15:0] cpu_din,        // data FROM cpu (write path)
    output logic [15:0] cpu_dout,       // data TO cpu (read mux)
    input  logic        cpu_lds_n,      // lower data strobe
    input  logic        cpu_uds_n,      // upper data strobe
    input  logic        cpu_rw,         // 1=read, 0=write
    input  logic        cpu_as_n,       // address strobe (active low)
    output logic        cpu_dtack_n,    // data acknowledge (active low)
    output logic [2:0]  cpu_ipl_n,      // interrupt level (active-low encoded)
    input  logic [2:0]  cpu_fc,         // function codes (for IACK detect)

    // ── Program ROM SDRAM Interface ───────────────────────────────────────
    output logic [26:0] prog_rom_addr,
    input  logic [15:0] prog_rom_data,
    output logic        prog_rom_req,
    input  logic        prog_rom_ack,

    // ── GFX ROM Interface (toggle handshake for X1-001A) ──────────────────
    output logic [17:0] gfx_addr,
    input  logic [15:0] gfx_data,
    output logic        gfx_req,
    input  logic        gfx_ack,

    // ── Video Output ──────────────────────────────────────────────────────
    output logic [4:0]  rgb_r,
    output logic [4:0]  rgb_g,
    output logic [4:0]  rgb_b,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,

    // ── Player Inputs (active-low) ────────────────────────────────────────
    input  logic [7:0]  joystick_p1,    // [3:0]=UDLR, [7:4]=buttons
    input  logic [7:0]  joystick_p2,
    input  logic [1:0]  coin,           // [0]=COIN1, [1]=COIN2
    input  logic        service,        // SERVICE button
    input  logic [7:0]  dipsw1,
    input  logic [7:0]  dipsw2
);

// =============================================================================
// Video Timing Generator — 384×240 @ 60 Hz
// =============================================================================

localparam int HS_START = 400;
localparam int HS_END   = 432;
localparam int VS_START = 244;
localparam int VS_END   = 247;

logic [8:0] hpos;
logic [8:0] vpos;
logic        vblank_r;
logic        vblank_rise;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        hpos <= 9'd0;
        vpos <= 9'd0;
    end else if (clk_pix) begin
        if (hpos == 9'(H_TOTAL - 1)) begin
            hpos <= 9'd0;
            if (vpos == 9'(V_TOTAL - 1))
                vpos <= 9'd0;
            else
                vpos <= vpos + 9'd1;
        end else begin
            hpos <= hpos + 9'd1;
        end
    end
end

assign hblank  = (hpos >= 9'(H_VISIBLE));
assign vblank  = (vpos >= 9'(V_VISIBLE));
assign hsync_n = ~((hpos >= 9'(HS_START)) && (hpos < 9'(HS_END)));
assign vsync_n = ~((vpos >= 9'(VS_START)) && (vpos < 9'(VS_END)));

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) vblank_r <= 1'b0;
    else          vblank_r <= vblank;
end
assign vblank_rise = vblank & ~vblank_r;

// =============================================================================
// Address Decode (all on cpu_addr[23:1], qualified by !cpu_as_n)
// =============================================================================

// Program ROM: 0x000000–0x0FFFFF (1MB = 512K words, 19-bit index)
logic prog_rom_cs;
assign prog_rom_cs = (cpu_addr[23:19] == 5'b0) && !cpu_as_n;

// Work RAM: parameterised base, default 0x200000 (64KB)
logic wram_cs;
assign wram_cs = (cpu_addr[23:15] == WRAM_BASE[23:15]) && !cpu_as_n;

// Palette RAM 1: 0x700000 (2KB or 4KB depending on variant)
logic pal_cs;
assign pal_cs = (cpu_addr[23:12] == PAL1_BASE[23:12]) && !cpu_as_n;

// Sprite Y RAM: 0xA00000–0xA005FF (1.5KB, 768 × 16-bit max)
// word base 0x500000; cpu_addr[23:10] = word_addr >> 9
logic sram_y_cs;
assign sram_y_cs = (cpu_addr[23:10] == SRAM_Y_BASE[23:10]) && !cpu_as_n;

// Sprite control registers: 0xA00600–0xA00607 (4 × 16-bit words)
// word base 0x500300; cpu_addr[23:3] = word_addr >> 2
logic sram_ctrl_cs;
assign sram_ctrl_cs = (cpu_addr[23:3] == {SRAM_Y_BASE[23:11], 8'hc0}) && !cpu_as_n;

// Sprite code RAM: 0xE00000–0xE03FFF (16KB = 8K words, 13-bit index)
// word base 0x700000; cpu_addr[23:14] = word_addr >> 13
logic sram_code_cs;
assign sram_code_cs = (cpu_addr[23:14] == SRAM_C_BASE[23:14]) && !cpu_as_n;

// DIP switches: 0x600000–0x600003 (2 × 16-bit words)
logic dip_cs;
assign dip_cs = (cpu_addr[23:2] == DIP_BASE[23:2]) && !cpu_as_n;

// Player inputs: 0xB00000–0xB00007 (4 × 16-bit words)
// P1 @ 0xB00000, P2 @ 0xB00002, coin/service @ 0xB00004
logic joy_cs;
assign joy_cs = (cpu_addr[23:2] == JOY_BASE[23:2]) && !cpu_as_n;

// Watchdog / no-op: 0xC00000–0xC00001 (stub, write-only)
logic watchdog_cs;
assign watchdog_cs = (cpu_addr[23:1] == 23'h600000) && !cpu_as_n;

// X1-010 audio chip stub: 0x100000–0x103FFF (16KB, blocker — no implementation)
logic x1010_cs;
assign x1010_cs = (cpu_addr[23:15] == 8'h80) && !cpu_as_n;

// =============================================================================
// X1-001A Sprite Generator (Sprite chip)
// =============================================================================

logic [15:0] sram_y_dout;
logic [15:0] sram_code_dout;
logic [15:0] sram_ctrl_dout;

logic        spr_pix_valid;
logic [8:0]  spr_pix_x;
logic [4:0]  spr_pix_color;
logic [8:0]  spr_pix_pal_index;

/* verilator lint_off UNUSED */
logic        spr_scan_active;
logic        spr_flip_screen;
logic [1:0]  spr_bg_startcol;
logic [3:0]  spr_bg_numcol;
logic        spr_frame_bank;
logic [15:0] spr_col_upper_mask;
/* verilator lint_on UNUSED */

x1_001a #(
    .FG_NOFLIP_YOFFS (FG_NOFLIP_YOFFS),
    .FG_NOFLIP_XOFFS (FG_NOFLIP_XOFFS),
    .SCREEN_H        (V_VISIBLE),
    .SCREEN_W        (H_VISIBLE),
    .SPRITE_LIMIT    (SPRITE_LIMIT)
) u_x1001a (
    .clk             (clk_sys),
    .rst_n           (reset_n),

    // Video timing
    .vblank          (vblank),
    .hblank          (hblank),
    .hpos            (hpos),
    .vpos            (vpos),

    // Y coordinate RAM (CPU access)
    .yram_cs         (sram_y_cs),
    .yram_we         (!cpu_rw),
    .yram_addr       (cpu_addr[9:1]),
    .yram_din        (cpu_din),
    .yram_dout       (sram_y_dout),
    .yram_be         ({!cpu_uds_n, !cpu_lds_n}),

    // Sprite code / attribute RAM (CPU access)
    .cram_cs         (sram_code_cs),
    .cram_we         (!cpu_rw),
    .cram_addr       (cpu_addr[13:1]),
    .cram_din        (cpu_din),
    .cram_dout       (sram_code_dout),
    .cram_be         ({!cpu_uds_n, !cpu_lds_n}),

    // Control registers (CPU access)
    .ctrl_cs         (sram_ctrl_cs),
    .ctrl_we         (!cpu_rw),
    .ctrl_addr       (cpu_addr[2:1]),
    .ctrl_din        (cpu_din),
    .ctrl_dout       (sram_ctrl_dout),
    .ctrl_be         ({!cpu_uds_n, !cpu_lds_n}),

    // External scanner read ports (not used)
    .scan_yram_addr  (9'd0),
    /* verilator lint_off PINCONNECTEMPTY */
    .scan_yram_data  (),
    /* verilator lint_on PINCONNECTEMPTY */
    .scan_cram_addr  (13'd0),
    /* verilator lint_off PINCONNECTEMPTY */
    .scan_cram_data  (),
    /* verilator lint_on PINCONNECTEMPTY */

    // Decoded control outputs
    .flip_screen     (spr_flip_screen),
    .bg_startcol     (spr_bg_startcol),
    .bg_numcol       (spr_bg_numcol),
    .frame_bank      (spr_frame_bank),
    .col_upper_mask  (spr_col_upper_mask),

    // GFX ROM toggle handshake
    .gfx_addr        (gfx_addr),
    .gfx_req         (gfx_req),
    .gfx_data        (gfx_data),
    .gfx_ack         (gfx_ack),

    // Pixel output (to colmix)
    .pix_valid       (spr_pix_valid),
    .pix_x           (spr_pix_x),
    .pix_color       (spr_pix_color),
    .pix_pal_index   (spr_pix_pal_index),

    .scan_active     (spr_scan_active)
);

// =============================================================================
// Palette RAM (2KB or 4KB, xRGB 555 format)
// =============================================================================

logic [15:0] pal_dout;

`ifndef QUARTUS
logic [15:0] palette_ram [0:(1<<PAL1_ABITS)-1];
logic [15:0] pal_dout_r;

always_ff @(posedge clk_sys) begin
    if (pal_cs && !cpu_rw) begin
        if (!cpu_uds_n) palette_ram[cpu_addr[PAL1_ABITS:1]][15:8] <= cpu_din[15:8];
        if (!cpu_lds_n) palette_ram[cpu_addr[PAL1_ABITS:1]][ 7:0] <= cpu_din[ 7:0];
    end
end

always_ff @(posedge clk_sys) begin
    if (pal_cs) pal_dout_r <= palette_ram[cpu_addr[PAL1_ABITS:1]];
end
assign pal_dout = pal_dout_r;
`else
// Quartus: infer M10K via altsyncram
altsyncram #(
    .operation_mode         ("SINGLE_PORT"),
    .width_a                (16),
    .widthad_a              (PAL1_ABITS),
    .numwords_a             (1 << PAL1_ABITS),
    .intended_device_family ("Cyclone V"),
    .lpm_type               ("altsyncram"),
    .ram_block_type         ("M10K"),
    .width_byteena_a        (2),
    .outdata_reg_a          ("UNREGISTERED")
) palette_ram_inst (
    .clock0    (clk_sys),
    .address_a (cpu_addr[PAL1_ABITS:1]),
    .data_a    (cpu_din),
    .wren_a    (pal_cs && !cpu_rw),
    .byteena_a ({!cpu_uds_n, !cpu_lds_n}),
    .q_a       (pal_dout)
);
`endif

// Color lookup: palette RAM stores xRGB (5-5-5 with 1 unused MSB)
logic [4:0] pal_r, pal_g, pal_b;
always_comb begin
    if (spr_pix_valid) begin
        // Palette entry: [15]=x, [14:10]=R, [9:5]=G, [4:0]=B
        {rgb_r, rgb_g, rgb_b} = {pal_dout[14:10], pal_dout[9:5], pal_dout[4:0]};
    end else begin
        {rgb_r, rgb_g, rgb_b} = 15'h0;  // black during blanking
    end
end

// =============================================================================
// Work RAM (64KB BRAM)
// =============================================================================

`ifndef QUARTUS
logic [15:0] work_ram [0:(1<<WRAM_ABITS)-1];
logic [15:0] wram_dout_r;

always_ff @(posedge clk_sys) begin
    if (wram_cs && !cpu_rw) begin
        if (!cpu_uds_n) work_ram[cpu_addr[WRAM_ABITS:1]][15:8] <= cpu_din[15:8];
        if (!cpu_lds_n) work_ram[cpu_addr[WRAM_ABITS:1]][ 7:0] <= cpu_din[ 7:0];
    end
end

always_ff @(posedge clk_sys) begin
    if (wram_cs) wram_dout_r <= work_ram[cpu_addr[WRAM_ABITS:1]];
end
`else
// Quartus: infer M10K via altsyncram
logic [15:0] wram_dout_r;
altsyncram #(
    .operation_mode         ("SINGLE_PORT"),
    .width_a                (16),
    .widthad_a              (WRAM_ABITS),
    .numwords_a             (1 << WRAM_ABITS),
    .intended_device_family ("Cyclone V"),
    .lpm_type               ("altsyncram"),
    .ram_block_type         ("M10K"),
    .width_byteena_a        (2),
    .outdata_reg_a          ("UNREGISTERED")
) work_ram_inst (
    .clock0    (clk_sys),
    .address_a (cpu_addr[WRAM_ABITS:1]),
    .data_a    (cpu_din),
    .wren_a    (wram_cs && !cpu_rw),
    .byteena_a ({!cpu_uds_n, !cpu_lds_n}),
    .q_a       (wram_dout_r)
);
`endif

// =============================================================================
// I/O Registers and DIP Switches
// =============================================================================

logic [15:0] dip_dout;
always_comb begin
    dip_dout = 16'hFFFF;
    if (dip_cs) begin
        case (cpu_addr[2:1])
            2'd0: dip_dout = {dipsw1[7:4], 4'hF, dipsw1[3:0]};   // DIP1
            2'd1: dip_dout = {dipsw2[7:4], 4'hF, dipsw2[3:0]};   // DIP2
            default: dip_dout = 16'hFFFF;
        endcase
    end
end

logic [15:0] joy_dout;
always_comb begin
    joy_dout = 16'hFFFF;
    if (joy_cs) begin
        case (cpu_addr[2:1])
            2'd0: joy_dout = {8'hFF, joystick_p1};
            2'd1: joy_dout = {8'hFF, joystick_p2};
            2'd2: joy_dout = {8'hFF, {2'b11, service, 1'b1, coin[1], coin[0], 2'b11}};
            default: joy_dout = 16'hFFFF;
        endcase
    end
end

// =============================================================================
// Program ROM Handling
// =============================================================================

logic prog_req_pending;
logic [15:0] prog_rom_data_r;
// Toggle-handshake request register: toggles when a new ROM bus cycle starts.
// FIXED: was a combinational self-loop (assign prog_rom_req = cs ? ~prog_rom_req : prog_rom_req)
// which causes DIDNOTCONVERGE in Verilator and is unroutable in synthesis.
// Correct pattern: register that toggles exactly once per new bus cycle.
logic prog_rom_req_r;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        prog_req_pending <= 1'b0;
        prog_rom_data_r  <= 16'h0000;
        prog_rom_req_r   <= 1'b0;
    end else begin
        // Latch ROM data when SDRAM handshake completes
        if (prog_rom_cs && prog_req_pending && (prog_rom_req_r == prog_rom_ack)) begin
            prog_rom_data_r <= prog_rom_data;
        end

        // Set request pending and toggle req on new bus cycle
        if (prog_rom_cs && !prog_req_pending) begin
            prog_req_pending <= 1'b1;
            prog_rom_req_r   <= ~prog_rom_req_r;  // toggle to initiate SDRAM request
        end else if (cpu_as_n) begin
            // Clear request when bus cycle ends (AS goes high)
            prog_req_pending <= 1'b0;
        end
    end
end

// Drive prog_rom_addr and prog_rom_req when fetching
assign prog_rom_addr = {3'b0, cpu_addr[23:1]};
assign prog_rom_req  = prog_rom_req_r;

// =============================================================================
// CPU Data Bus Read Mux
// Priority: PROG_ROM > SRAM_CODE > SRAM_Y > SRAM_CTRL > PAL > WRAM > DIP > JOY > X1010_STUB > open-bus
// =============================================================================

logic prog_dtack_now;
assign prog_dtack_now = prog_rom_cs && prog_req_pending && (prog_rom_req_r == prog_rom_ack);

always_comb begin
    if (prog_rom_cs)
        cpu_dout = prog_dtack_now ? prog_rom_data : prog_rom_data_r;
    else if (sram_code_cs)
        cpu_dout = sram_code_dout;
    else if (sram_y_cs)
        cpu_dout = sram_y_dout;
    else if (sram_ctrl_cs)
        cpu_dout = sram_ctrl_dout;
    else if (pal_cs)
        cpu_dout = pal_dout;
    else if (wram_cs)
        cpu_dout = wram_dout_r;
    else if (dip_cs)
        cpu_dout = dip_dout;
    else if (joy_cs)
        cpu_dout = joy_dout;
    else if (x1010_cs)
        cpu_dout = 16'hFFFF;  // X1-010 stub — return open bus
    else if (watchdog_cs)
        cpu_dout = 16'hFFFF;  // watchdog write-only, no read
    else
        cpu_dout = 16'hFFFF;  // open bus
end

// =============================================================================
// DTACK Generation
// =============================================================================

logic dtack_r;

// Immediate chip-selects: local BRAM/registers that respond in 1 pipeline cycle
logic imm_cs;
assign imm_cs = wram_cs | pal_cs | sram_y_cs | sram_ctrl_cs | sram_code_cs
              | dip_cs | joy_cs | x1010_cs | watchdog_cs;

// Open-bus DTACK: unmapped reads
logic any_cs;
logic open_bus_cs;
assign any_cs      = prog_rom_cs | wram_cs | pal_cs | sram_y_cs | sram_ctrl_cs
                   | sram_code_cs | dip_cs | joy_cs | x1010_cs | watchdog_cs;
assign open_bus_cs = !cpu_as_n && !any_cs;

// Hold latch: set by any source firing, cleared when AS_n deasserts
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)
        dtack_r <= 1'b0;
    else
        dtack_r <= !cpu_as_n && (dtack_r | imm_cs | prog_dtack_now | open_bus_cs);
end

assign cpu_dtack_n = cpu_as_n       ? 1'b1 :
                     prog_dtack_now ? 1'b0 :
                                      !dtack_r;

// =============================================================================
// Interrupt Controller (VBlank → IPL level 1, active-low 3'b110)
// =============================================================================
//
// IACK-based clear (per COMMUNITY_PATTERNS.md Section 1.2).
// Interrupt SET on VBlank rising edge, CLEARED only on IACK cycle.

logic int_n_r;

// IACK detection: FC[2:0] == 3'b111 && ASn == 0
wire inta_n = ~&{cpu_fc[2], cpu_fc[1], cpu_fc[0], ~cpu_as_n};

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        int_n_r <= 1'b1;  // inactive (active-low)
    end else begin
        if (!inta_n)                    int_n_r <= 1'b1;  // clear on IACK
        else if (vblank_rise)           int_n_r <= 1'b0;  // set on VBLANK
    end
end

// Register IPL through synchronizer FF (COMMUNITY_PATTERNS.md 1.2)
logic int_n_ff1, int_n_ff2;
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        int_n_ff1 <= 1'b1;
        int_n_ff2 <= 1'b1;
    end else begin
        int_n_ff1 <= int_n_r;
        int_n_ff2 <= int_n_ff1;
    end
end

// Output IPL: level 1 (active-low 3'b110)
// IPL[2:0] = 3'b110 when interrupt active (IPL0n=0), 3'b111 when inactive
// BUGFIX (2026-03-22): {int_n_ff2, int_n_ff2, ~int_n_ff2} was INVERTED:
//   int_n_ff2=1 (inactive) → {1,1,0}=3'b110 (level 1 always asserted!) WRONG
//   int_n_ff2=0 (active)   → {0,0,1}=3'b001 (level 6!)              WRONG
// Correct: inactive=3'b111, active=3'b110 (only IPL0n low for level 1)
assign cpu_ipl_n = int_n_ff2 ? 3'b111 : 3'b110;

endmodule
