// =============================================================================
// esd16.sv — ESD 16-bit Arcade System Top-Level
// =============================================================================
//
// Hardware: ESD Electronics arcade PCB, 1998-2002
//   - MC68000 @ 16 MHz (fx68k implementation)
//   - Z80 sound CPU @ 3.5 MHz (stub — OKI M6295 ADPCM only path)
//   - OKI M6295 ADPCM (jt6295 or equivalent)
//   - Custom ESD video hardware: 1 BG tilemap + sprites
//   - 320x224 @ 60 Hz display
//
// Games supported: Multi Champ (1998), Multi Champ Deluxe (1999),
//   Head Panic (1999), Deluxe 5 (2000), 2 On 2 Open Ice Challenge (1999),
//   Jumping Pop (2001), Swat Police (2002)
//
// Memory map (byte addresses, from MAME esd16.cpp + Verilated analysis):
//   0x000000-0x07FFFF  Program ROM (512KB max, SDRAM)
//   0x100000-0x10FFFF  Work RAM (64KB, BRAM — 32K x 16 words)
//   0x200000-0x20FFFF  Palette RAM (512 entries x 16-bit, BRAM)
//                      [actually CPU accesses narrow 16-bit at 0x200000 area]
//   0x300000-0x3007FF  Sprite RAM (1K words = 512 words x 16-bit, BRAM)
//   0x400000-0x47FFFF  BG VRAM (16K words = tile codes for BG layer, BRAM)
//   0x500000-0x50000F  Video attribute registers (scroll, flip, layer size)
//   0x600000-0x60000F  I/O registers (joystick, coin, DIP, sound cmd)
//   0x700000-0x70FFFF  No-op region (e.g. ESD MCU / status reads)
//
// Address decode extracted from Verilated C++ (aob = CPU address bus):
//   ROM:     aob[23:19] == 5'b0         (0x000000-0x07FFFF)
//   WRAM:    aob[23:16] == 8'h10        (0x100000-0x10FFFF)
//   PAL:     aob[23:16] == 8'h20        (0x200000-0x20FFFF)
//   SPR:     aob[23:16] == 8'h30        (0x300000-0x30FFFF — only 1K words used)
//   VRAM:    aob[23:18] == 6'h10        (0x400000-0x43FFFF)
//   VIDATTR: aob[23:16] == 8'h50        (0x500000-0x50FFFF)
//   IO:      aob[23:16] == 8'h60        (0x600000-0x60FFFF)
//   NOPR:    aob[23:16] == 8'h70        (0x700000 stub region)
//
// I/O register decode (within 0x600000 region, aob[3:1] word select):
//   aob[3:1] == 3'd1  read: {P2 joy[5:0], P1 joy[5:0]} | 0xC0C0
//   aob[3:1] == 3'd2  read: coin/system inputs
//   aob[3:1] == 3'd3  read: DIP switches
//   write aob[3]=1, aob[2]=1, aob[1]=0: sound command (low byte)
//   write aob[3]=1, aob[2]=0, aob[1]=0: flip screen + layer color
//
// Video attribute registers (within 0x500000, aob[3:1] word select):
//   aob[3:2]=0, aob[1]=0: scroll0_x write
//   aob[3:2]=0, aob[1]=1: scroll0_y write  (aob[1]=bit1 of byte addr)
//   aob[3:2]=1, aob[1]=0: scroll1_x write
//   aob[3:2]=1, aob[1]=1: scroll1_y write
//   aob[3]=1, aob[2:1]=0x0: platform_x
//   aob[3]=1, aob[2:1]=0x1: platform_y
//   aob[3]=1, aob[2:1]=0x3: layersize
//
// Interrupt: level 6 (IPL[2:0]=001) on VBlank rising edge.
//   Cleared by IACK (community pattern: set/clear latch, NEVER timer).
//
// =============================================================================
`default_nettype none

/* verilator lint_off SYNCASYNCNET */
module esd16 (
    // Clocks / Reset
    input  logic        clk_sys,       // master system clock (typ. 32-48 MHz)
    input  logic        clk_pix,       // pixel clock enable (1-cycle pulse, sys-domain)
    input  logic        reset_n,       // active-low asynchronous reset

    // fx68k CPU interface (from testbench / emu wrapper)
    input  logic        enPhi1,        // CPU phi1 clock enable (from C++ or RTL toggle)
    input  logic        enPhi2,        // CPU phi2 clock enable

    // Program ROM SDRAM interface (toggle-handshake)
    output logic [26:0] prog_rom_addr,
    input  logic [15:0] prog_rom_data,
    output logic        prog_rom_req,
    input  logic        prog_rom_ack,

    // BG GFX ROM SDRAM interface (toggle-handshake)
    output logic [26:0] bg_rom_addr,
    input  logic [15:0] bg_rom_data,
    output logic        bg_rom_req,
    input  logic        bg_rom_ack,

    // Sprite GFX ROM SDRAM (unused in gate1/sim, reserved for future)
    output logic [26:0] spr_rom_addr,
    input  logic [15:0] spr_rom_data,
    output logic        spr_rom_req,
    input  logic        spr_rom_ack,

    // Video output
    output logic  [7:0] rgb_r,
    output logic  [7:0] rgb_g,
    output logic  [7:0] rgb_b,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,

    // Player / system inputs (active-low, bit mapping from MAME esd16.cpp)
    //   [5:0] = {BTN2,BTN1,RIGHT,LEFT,DOWN,UP}
    //   [6]   = START, [7] = not used (hardware tie to 1)
    //   [8]   = COIN, [9] = SERVICE
    input  logic  [9:0] joystick_0,   // P1 inputs (active-low)
    input  logic  [9:0] joystick_1,   // P2 inputs (active-low)
    input  logic [15:0] dip_sw,       // DIP switches (active-low)

    // Audio output (OKI M6295 stub — zero until sound CPU added)
    output logic [15:0] audio_l,
    output logic [15:0] audio_r,

    // Debug ports (used by Verilator testbench)
    output logic [23:1] dbg_cpu_addr,
    output logic        dbg_cpu_as_n,
    output logic        dbg_cpu_rw,
    output logic [15:0] dbg_cpu_dout,
    output logic        dbg_cpu_dtack_n,
    output logic        dbg_cpu_halted_n
);

// =============================================================================
// Reset synchronizer (two-stage, async assert / sync release)
// =============================================================================
// Verilated shows rst_r1 and rst_r2 in the module — active HIGH internally.
// External reset_n is active-low.

logic rst_r1, rst_r2;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        rst_r1 <= 1'b1;
        rst_r2 <= 1'b1;
    end else begin
        rst_r1 <= 1'b0;
        rst_r2 <= rst_r1;
    end
end

wire rst = rst_r2; // active-high internal reset

// =============================================================================
// CPU Bus Signals (from fx68k)
// =============================================================================
logic [23:1] cpu_addr;    // word address A[23:1]
logic [15:0] cpu_dout_w;  // CPU write data
logic [15:0] cpu_din;     // mux of all read sources
logic        cpu_as_n;    // address strobe
logic        cpu_rw;      // 1=read, 0=write
logic        cpu_uds_n;   // upper byte strobe
logic        cpu_lds_n;   // lower byte strobe
logic        cpu_dtack_n; // data transfer ack (to CPU)
logic  [2:0] cpu_fc;      // function codes
logic  [2:0] cpu_ipl_n;   // interrupt priority level (active low encoded)
logic        cpu_halted_n;

// IACK detection: FC=111 and AS asserted (community pattern)
wire inta_n = ~&{cpu_fc[2], cpu_fc[1], cpu_fc[0], ~cpu_as_n};

// Byte-write enables (GUARDRAILS 1.6)
wire cpu_wru = ~cpu_rw & ~cpu_uds_n; // write upper byte
wire cpu_wrl = ~cpu_rw & ~cpu_lds_n; // write lower byte

// =============================================================================
// fx68k CPU Instantiation
// =============================================================================
/* verilator lint_off PINCONNECTEMPTY */
fx68k u_cpu (
    .clk        (clk_sys),
    .extReset   (rst),
    .pwrUp      (rst),
    .enPhi1     (enPhi1),
    .enPhi2     (enPhi2),
    .HALTn      (1'b1),
    .ASn        (cpu_as_n),
    .eRWn       (cpu_rw),
    .UDSn       (cpu_uds_n),
    .LDSn       (cpu_lds_n),
    .DTACKn     (cpu_dtack_n),
    .VPAn       (inta_n),
    .BERRn      (1'b1),
    .BRn        (1'b1),
    .BGACKn     (1'b1),
    .IPL0n      (cpu_ipl_n[0]),
    .IPL1n      (cpu_ipl_n[1]),
    .IPL2n      (cpu_ipl_n[2]),
    .FC0        (cpu_fc[0]),
    .FC1        (cpu_fc[1]),
    .FC2        (cpu_fc[2]),
    .iEdb       (cpu_din),
    .oEdb       (cpu_dout_w),
    .eab        (cpu_addr),
    .BGn        (),
    .oRESETn    (),
    .oHALTEDn   (cpu_halted_n),
    .VMAn       (),
    .E          ()
);
/* verilator lint_on PINCONNECTEMPTY */

// =============================================================================
// Address Decode
// =============================================================================
// Decoded from Verilated aob (CPU address object bus = byte address >> 1
// for word select, but upper bits match byte address directly).
// cpu_addr[23:1] = A[23:1]; byte_addr[23:0] = {cpu_addr[23:1], 1'b0}
// so cpu_addr[23:16] = byte_addr[23:16] (upper byte always matches).

logic rom_cs, wram_cs, pal_cs, spr_cs, vram_cs, vidattr_cs, io_cs, nopr_cs;

// ROM: byte address 0x000000-0x07FFFF -> A[23:19] == 5'b0
assign rom_cs    = !cpu_as_n && !rst && (cpu_addr[23:19] == 5'b00000);
// WRAM: 0x100000-0x10FFFF -> A[23:16] == 8'h10
assign wram_cs   = !cpu_as_n && !rst && (cpu_addr[23:16] == 8'h10);
// PAL: 0x200000-0x20FFFF -> A[23:16] == 8'h20
assign pal_cs    = !cpu_as_n && !rst && (cpu_addr[23:16] == 8'h20);
// SPR: 0x300000-0x30FFFF -> A[23:16] == 8'h30 (only 1K words actually used)
assign spr_cs    = !cpu_as_n && !rst && (cpu_addr[23:16] == 8'h30);
// VRAM: 0x400000-0x43FFFF -> A[23:18] == 6'h10 (bit pattern 010000 for A[23:18])
assign vram_cs   = !cpu_as_n && !rst && (cpu_addr[23:18] == 6'b010000);
// VIDATTR: 0x500000-0x50FFFF -> A[23:16] == 8'h50
assign vidattr_cs = !cpu_as_n && !rst && (cpu_addr[23:16] == 8'h50);
// IO: 0x600000-0x60FFFF -> A[23:16] == 8'h60
assign io_cs     = !cpu_as_n && !rst && (cpu_addr[23:16] == 8'h60);
// NOPR: 0x700000-0x70FFFF -> A[23:16] == 8'h70
assign nopr_cs   = !cpu_as_n && !rst && (cpu_addr[23:16] == 8'h70);

// Any valid chip select
wire bus_cs = rom_cs | wram_cs | pal_cs | spr_cs | vram_cs | vidattr_cs | io_cs | nopr_cs;

// =============================================================================
// Work RAM — 32K words (64KB) at 0x100000
// =============================================================================
// Byte-enable writes to 16-bit wide BRAM (GUARDRAILS Rule 3: behavioral for <32K)

logic [7:0] wram_hi [0:32767]; // upper byte of each word
logic [7:0] wram_lo [0:32767]; // lower byte of each word
logic [15:0] wram_dout;
logic [14:0] wram_addr_w;

assign wram_addr_w = cpu_addr[15:1]; // 15-bit word address within WRAM

always_ff @(posedge clk_sys) begin
    if (wram_cs && !cpu_as_n) begin
        if (cpu_wru) wram_hi[wram_addr_w] <= cpu_dout_w[15:8];
        if (cpu_wrl) wram_lo[wram_addr_w] <= cpu_dout_w[7:0];
        wram_dout <= {wram_hi[wram_addr_w], wram_lo[wram_addr_w]};
    end
end

// =============================================================================
// Palette RAM — 512 entries x 16-bit at 0x200000
// =============================================================================
logic [7:0] pal_hi [0:511];
logic [7:0] pal_lo [0:511];
logic [15:0] pal_dout;
logic  [8:0] pal_cpu_addr;
logic  [8:0] vid_pal_addr_w;
logic [15:0] vid_pal_data_w;

assign pal_cpu_addr = cpu_addr[9:1]; // 9-bit word address within PAL

always_ff @(posedge clk_sys) begin
    if (pal_cs && !cpu_as_n) begin
        if (cpu_wru) pal_hi[pal_cpu_addr] <= cpu_dout_w[15:8];
        if (cpu_wrl) pal_lo[pal_cpu_addr] <= cpu_dout_w[7:0];
        pal_dout <= {pal_hi[pal_cpu_addr], pal_lo[pal_cpu_addr]};
    end
end

// Video read port (combinational for 1-cycle latency in Verilated)
always_ff @(posedge clk_sys) begin
    vid_pal_data_w <= {pal_hi[vid_pal_addr_w], pal_lo[vid_pal_addr_w]};
end

// =============================================================================
// Sprite RAM — 1K words (0x300000)
// =============================================================================
logic [7:0] spr_hi [0:1023];
logic [7:0] spr_lo [0:1023];
logic [15:0] spr_dout;
logic  [9:0] spr_cpu_addr;
logic  [9:0] vid_spr_addr_w;
logic [15:0] vid_spr_data_w;

assign spr_cpu_addr = cpu_addr[10:1];

always_ff @(posedge clk_sys) begin
    if (spr_cs && !cpu_as_n) begin
        if (cpu_wru) spr_hi[spr_cpu_addr] <= cpu_dout_w[15:8];
        if (cpu_wrl) spr_lo[spr_cpu_addr] <= cpu_dout_w[7:0];
        spr_dout <= {spr_hi[spr_cpu_addr], spr_lo[spr_cpu_addr]};
    end
end

always_ff @(posedge clk_sys) begin
    vid_spr_data_w <= {spr_hi[vid_spr_addr_w], spr_lo[vid_spr_addr_w]};
end

// =============================================================================
// BG VRAM — 16K words (0x400000-0x43FFFF) — tile codes for BG layer
// =============================================================================
logic [7:0] bg_vram_hi [0:16383];
logic [7:0] bg_vram_lo [0:16383];
logic [15:0] bg_vram_dout;
logic [13:0] bg_vram_cpu_addr;
logic [14:0] vid_vram_addr_w;
logic [15:0] vid_vram_data_w;

assign bg_vram_cpu_addr = cpu_addr[14:1]; // 14-bit word address

always_ff @(posedge clk_sys) begin
    if (vram_cs && !cpu_as_n) begin
        if (cpu_wru) bg_vram_hi[bg_vram_cpu_addr] <= cpu_dout_w[15:8];
        if (cpu_wrl) bg_vram_lo[bg_vram_cpu_addr] <= cpu_dout_w[7:0];
        bg_vram_dout <= {bg_vram_hi[bg_vram_cpu_addr], bg_vram_lo[bg_vram_cpu_addr]};
    end
end

// Video read port — 1-cycle latency
always_ff @(posedge clk_sys) begin
    vid_vram_data_w <= {bg_vram_hi[vid_vram_addr_w[13:0]], bg_vram_lo[vid_vram_addr_w[13:0]]};
end

// =============================================================================
// Video Attribute Registers (0x500000)
// =============================================================================
// Decoded from Verilated NBA sequent lines 468-516 (vidattr_cs write decode).
// aob = {cpu_addr, 1'b0} byte address; we check cpu_addr[3:1] for word select.

logic [15:0] scroll0_x, scroll0_y;
logic [15:0] scroll1_x, scroll1_y;
logic [15:0] platform_x, platform_y;
logic [15:0] layersize;

always_ff @(posedge clk_sys or posedge rst) begin
    if (rst) begin
        scroll0_x  <= 16'd0;
        scroll0_y  <= 16'd0;
        scroll1_x  <= 16'd0;
        scroll1_y  <= 16'd0;
        platform_x <= 16'd0;
        platform_y <= 16'd0;
        layersize  <= 16'd0;
    end else if (vidattr_cs && !cpu_rw && !cpu_as_n) begin
        // aob[3:1] decoded from cpu_addr[3:1]
        if (!cpu_addr[3]) begin
            // aob[3]=0 block
            if (!cpu_addr[2]) begin
                if (!cpu_addr[1]) scroll0_x <= cpu_dout_w;
                else              scroll0_y <= cpu_dout_w;
            end else begin
                if (!cpu_addr[1]) scroll1_x <= cpu_dout_w;
                else              scroll1_y <= cpu_dout_w;
            end
        end else begin
            // aob[3]=1 block
            if (!cpu_addr[2]) begin
                if (!cpu_addr[1]) platform_x <= cpu_dout_w;
                else              platform_y <= cpu_dout_w;
            end else begin
                if (cpu_addr[1])  layersize  <= cpu_dout_w;
            end
        end
    end
end

// =============================================================================
// I/O Registers (0x600000)
// =============================================================================
logic [1:0]  layer0_color; // BG palette bank
logic        flip_screen;
logic  [7:0] sound_cmd;
logic        sound_cmd_wr;

// Reads: joystick, coin/system, DIP
// From Verilated ico_sequent lines 24-61:
//   word 1: {P2 joy[5:0], P1 joy[5:0]} with bits [7:6] forced to 1 (0xC0C0 mask)
//   word 2: coin/service: bits [4:3]=P1_COIN,P2_COIN, [2]=SERVICE, [1]=P2_START
//           bits [7:5] forced 1, [0] forced 1 (0xFFE1 base)
//   word 3: DIP switches
wire [15:0] io_dout;
assign io_dout =
    (cpu_addr[3:1] == 3'd1) ? (16'hC0C0 |
                                ({~joystick_1[5:0], ~joystick_0[5:0]})) :
    (cpu_addr[3:1] == 3'd2) ? (16'hFFE1 |
                                {4'b0,
                                 ~joystick_0[8], // P1 COIN
                                 ~joystick_1[8], // P2 COIN
                                 ~joystick_0[6], // P1 START
                                 ~joystick_1[6], // P2 START
                                 3'b0}) :
    (cpu_addr[3:1] == 3'd3) ? dip_sw :
                               16'hFFFF; // open bus

// Writes: flip_screen, layer color, sound command
always_ff @(posedge clk_sys or posedge rst) begin
    if (rst) begin
        flip_screen  <= 1'b0;
        layer0_color <= 2'd0;
        sound_cmd    <= 8'd0;
        sound_cmd_wr <= 1'b0;
    end else begin
        sound_cmd_wr <= 1'b0;
        if (io_cs && !cpu_rw && !cpu_as_n) begin
            if (cpu_addr[3]) begin
                if (cpu_addr[2]) begin
                    // aob[3]=1, aob[2]=1, aob[1]=0 -> sound cmd
                    if (!cpu_addr[1] && cpu_wrl) begin
                        sound_cmd    <= cpu_dout_w[7:0];
                        sound_cmd_wr <= 1'b1;
                    end
                end else begin
                    // aob[3]=1, aob[2]=0, aob[1]=0 -> flip + layer color
                    if (!cpu_addr[1]) begin
                        flip_screen  <= cpu_dout_w[7];
                        layer0_color <= cpu_dout_w[1:0];
                    end
                end
            end
        end
    end
end

// =============================================================================
// CPU Read Data Mux (COMMUNITY_PATTERNS 1.5: open bus = 0xFFFF)
// =============================================================================
always_comb begin
    if      (rom_cs)     cpu_din = prog_rom_data;
    else if (wram_cs)    cpu_din = wram_dout;
    else if (pal_cs)     cpu_din = pal_dout;
    else if (spr_cs)     cpu_din = spr_dout;
    else if (vram_cs)    cpu_din = bg_vram_dout;
    else if (io_cs)      cpu_din = io_dout;
    else                 cpu_din = 16'hFFFF;
end

// =============================================================================
// Program ROM SDRAM Access (COMMUNITY_PATTERNS 1.3, 1.4)
// =============================================================================
// Toggle-handshake: toggle req on new read, clear on ack.
logic prog_rom_pending;

always_ff @(posedge clk_sys or posedge rst) begin
    if (rst) begin
        prog_rom_req     <= 1'b0;
        prog_rom_addr    <= 27'd0;
        prog_rom_pending <= 1'b0;
    end else begin
        if (rom_cs && cpu_rw && !prog_rom_pending && !cpu_as_n) begin
            // New ROM read request
            prog_rom_req     <= 1'b1;
            prog_rom_addr    <= {3'b0, cpu_addr[23:1], 1'b0}; // byte address
            prog_rom_pending <= 1'b1;
        end else if (prog_rom_ack) begin
            prog_rom_req     <= 1'b0;
            prog_rom_pending <= 1'b0;
        end
    end
end

// =============================================================================
// DTACK Logic — 1 wait state pipeline
// =============================================================================
// Immediate regions (WRAM, PAL, SPR, VRAM, VIDATTR, IO, NOPR) get dtack
// after 1 cycle delay (dtack_delay pattern).
// ROM waits for prog_rom_ack.

logic dtack_delay;
logic dtack_n_r;

always_ff @(posedge clk_sys or posedge rst) begin
    if (rst) begin
        dtack_n_r  <= 1'b1;
        dtack_delay <= 1'b0;
    end else begin
        if (cpu_as_n) begin
            // Bus cycle ended — deassert DTACK
            dtack_n_r  <= 1'b1;
            dtack_delay <= 1'b0;
        end else if (bus_cs) begin
            // Check if ROM is ready (for ROM cycles) or immediate (for others)
            if (dtack_delay && !(rom_cs && !prog_rom_ack)) begin
                dtack_n_r <= 1'b0;
            end
            dtack_delay <= 1'b1;
        end
    end
end

assign cpu_dtack_n = dtack_n_r;

// =============================================================================
// Interrupt — Level 6 VBlank (COMMUNITY_PATTERNS 1.2)
// =============================================================================
// ESD hardware uses level 6. ipl_sync = 1 = 3'b001 (active-low IPL encoding).
// SET on vblank rising edge, CLEAR on IACK (inta_n=0).

logic int6_n;
logic vblank_prev;
logic [2:0] ipl_sync;

// Wire vblank from video subsystem
logic vblank_w;
logic hblank_w;

always_ff @(posedge clk_sys or posedge rst) begin
    if (rst) begin
        int6_n     <= 1'b1;
        vblank_prev <= 1'b0;
        ipl_sync   <= 3'b111;
    end else begin
        vblank_prev <= vblank_w;
        if (!inta_n) begin
            // IACK cycle: CPU acknowledged interrupt
            int6_n <= 1'b1;
        end else if (vblank_w && !vblank_prev) begin
            // Rising edge of VBlank: set interrupt
            int6_n <= 1'b0;
        end
        // Registered IPL output (synchronizer — COMMUNITY_PATTERNS 1.2)
        ipl_sync <= int6_n ? 3'b111 : 3'b001; // 001 = level 6 (active-low IPL)
    end
end

assign cpu_ipl_n = ipl_sync;

// =============================================================================
// Video Subsystem
// =============================================================================
logic [26:0] bg_rom_addr_w;
logic        bg_rom_req_w;
logic  [9:0] vid_hcnt;
logic  [8:0] vid_vcnt;
logic [14:0] vid_vram_addr_out;

esd16_video u_video (
    .clk_sys       (clk_sys),
    .clk_pix       (clk_pix),
    .rst           (rst),

    // Scroll / video attributes from CPU
    .scroll0_x     (scroll0_x),
    .scroll0_y     (scroll0_y),
    .scroll1_x     (scroll1_x),
    .scroll1_y     (scroll1_y),
    .platform_x    (platform_x),
    .platform_y    (platform_y),
    .layersize     (layersize),
    .layer0_color  (layer0_color),
    .flip_screen   (flip_screen),

    // VRAM read port
    .vid_vram_addr (vid_vram_addr_out),
    .vid_vram_data (vid_vram_data_w),

    // Sprite RAM read port
    .vid_spr_addr  (vid_spr_addr_w),
    .vid_spr_data  (vid_spr_data_w),

    // Palette RAM read port
    .vid_pal_addr  (vid_pal_addr_w),
    .vid_pal_data  (vid_pal_data_w),

    // BG GFX ROM SDRAM
    .bg_rom_addr   (bg_rom_addr_w),
    .bg_rom_req    (bg_rom_req_w),
    .bg_rom_data   (bg_rom_data),
    .bg_rom_ack    (bg_rom_ack),

    // Timing
    .hcnt          (vid_hcnt),
    .vcnt          (vid_vcnt),
    .hblank        (hblank_w),
    .vblank        (vblank_w),
    .hsync_n       (hsync_n),
    .vsync_n       (vsync_n),

    // RGB
    .rgb_r         (rgb_r),
    .rgb_g         (rgb_g),
    .rgb_b         (rgb_b)
);

// Connect VRAM video read port
assign vid_vram_addr_w = {1'b0, vid_vram_addr_out};
// Forward video timing to top-level outputs
assign hblank = hblank_w;
assign vblank = vblank_w;

// Forward SDRAM signals
assign bg_rom_addr = bg_rom_addr_w;
assign bg_rom_req  = bg_rom_req_w;

// Sprite ROM stubs (no sprite engine yet)
assign spr_rom_addr = 27'd0;
assign spr_rom_req  = 1'b0;

// =============================================================================
// Audio stubs (OKI M6295 sound path not implemented in gate1 RTL)
// =============================================================================
assign audio_l = 16'd0;
assign audio_r = 16'd0;

// =============================================================================
// Debug outputs
// =============================================================================
assign dbg_cpu_addr    = cpu_addr;
assign dbg_cpu_as_n    = cpu_as_n;
assign dbg_cpu_rw      = cpu_rw;
assign dbg_cpu_dout    = cpu_din;
assign dbg_cpu_dtack_n = dtack_n_r;
assign dbg_cpu_halted_n = cpu_halted_n;

endmodule
