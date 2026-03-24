// =============================================================================
// DECO 16-bit (dec0) Arcade System — Top-Level RTL Integration
// =============================================================================
//
// Reference: MAME dec0.cpp (dataeast/dec0.cpp)
// Hardware: 68000 main CPU + M6502 sound CPU + BAC06 tiles + MXC06 sprites
// Games: Heavy Barrel, Bad Dudes, Robocop, Sly Spy, Midnight Resistance, etc.
//
// Memory Map (dec0_map):
//   0x000000–0x05FFFF   Program ROM (384 KB)
//   0x240000–0x24FFFF   Graphics control (DECO BAC06 tilemap × 3, registers)
//   0x300000–0x300009   Rotary joystick analog input
//   0x30C000–0x30C0FF   Main I/O and control (joystick, buttons, DSW, MCU comm)
//   0x310000–0x3107FF   Palette RAM (1024 × 16-bit)
//   0x314000–0x3147FF   Palette RAM extended
//   0x318000–0x31BFFF   Main RAM (16 KB)
//   0x31C000–0x31C7FF   Sprite RAM (2 KB, write buffer for MXC06)
//   0xFF8000–0xFFBFFF   Main RAM mirror (16 KB)
//   0xFFC000–0xFFC7FF   Sprite RAM mirror
//
// Sound CPU Memory Map (M6502):
//   0x0000–0x07FF      RAM (2 KB)
//   0x0800–0x0801      YM2203 OPN
//   0x1000–0x1001      YM3812 OPL2
//   0x3000              Sound latch (from main CPU at 0x30C014)
//   0x3800              OKI M6295 ADPCM
//   0x8000–0xFFFF      ROM (32 KB)
//
// Main CPU interrupts:
//   IPL[2:1] = 2'b10 (level 2) on VBLANK, cleared by IACK
//   Write 0x30C018 to acknowledge VBLANK (manual acknowledgment variant)
//
// =============================================================================

`default_nettype none

module deco16_arcade #(
    // ── Program ROM ────────────────────────────────────────────────────────
    parameter int unsigned PROG_ABITS = 19,  // 2^19 = 512K words = 1MB bytes

    // ── Main RAM ────────────────────────────────────────────────────────────
    // 16 KB at 0x318000 / 0xFF8000
    parameter int unsigned MAIN_RAM_ABITS = 14,  // 2^14 = 16K words = 32KB bytes
    parameter logic [7:0]  MAIN_RAM_BASE  = 8'h31,  // upper byte

    // ── Palette RAM ─────────────────────────────────────────────────────────
    // 1024 entries × 16-bit at 0x310000
    parameter int unsigned PAL_ABITS = 10,
    parameter logic [7:0]  PAL_BASE  = 8'h31,

    // ── Sprite RAM ──────────────────────────────────────────────────────────
    // 2 KB (256 sprites × 8 bytes) at 0x31C000
    parameter int unsigned SPR_ABITS = 11,
    parameter logic [7:0]  SPR_BASE  = 8'h31
) (
    // ── Clocks / Reset ──────────────────────────────────────────────────────
    input  logic        clk_sys,        // Master system clock (40 MHz typical)
    input  logic        clk_pix,        // Pixel clock enable (1-cycle pulse)
    input  logic        reset_n,        // Active-low async reset

    // ── MC68000 CPU Bus ─────────────────────────────────────────────────────
    input  logic [23:1] cpu_addr,       // Word address
    input  logic [15:0] cpu_din,        // Data FROM cpu (write path)
    output logic [15:0] cpu_dout,       // Data TO cpu (read path mux)
    input  logic        cpu_lds_n,      // Lower data strobe
    input  logic        cpu_uds_n,      // Upper data strobe
    input  logic        cpu_rw,         // 1=read, 0=write
    input  logic        cpu_as_n,       // Address strobe (active low)
    input  logic [2:0]  cpu_fc,         // Function code (bit[2:0] = FC[2:0])
    output logic        cpu_dtack_n,    // Data transfer acknowledge
    output logic [2:0]  cpu_ipl_n,      // Interrupt priority level

    // ── Program ROM SDRAM Interface ─────────────────────────────────────────
    output logic [26:0] prog_rom_addr,
    input  logic [15:0] prog_rom_data,
    output logic        prog_rom_req,
    input  logic        prog_rom_ack,

    // ── Video Output ────────────────────────────────────────────────────────
    output logic  [7:0] rgb_r,
    output logic  [7:0] rgb_g,
    output logic  [7:0] rgb_b,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,

    // ── Video Timing Inputs (from external timing generator) ────────────────
    input  logic        hblank_n_in,
    input  logic        vblank_n_in,
    input  logic  [8:0] hpos,
    input  logic  [8:0] vpos,
    input  logic        hsync_n_in,
    input  logic        vsync_n_in,

    // ── Player Inputs ───────────────────────────────────────────────────────
    // Standard 8-way joystick + 4 fire buttons per player (active low)
    input  logic  [7:0] joystick_p1,
    input  logic  [7:0] joystick_p2,
    input  logic  [1:0] coin,           // [0]=COIN1, [1]=COIN2 (active low)
    input  logic        service,        // Service button (active low)
    input  logic  [7:0] dipsw1,
    input  logic  [7:0] dipsw2,

    // ── Audio Output ────────────────────────────────────────────────────────
    output logic signed [15:0] snd_left,
    output logic signed [15:0] snd_right,

    // ── Sound ROM SDRAM Interface ───────────────────────────────────────────
    // M6502 sound CPU ROM at 0x8000–0xFFFF (32 KB)
    output logic [15:0] snd_rom_addr,   // 16-bit address from Z80
    output logic        snd_rom_req,
    input  logic  [7:0] snd_rom_data,
    input  logic        snd_rom_ack
);

// =============================================================================
// Internal Signal Declarations
// =============================================================================

logic        rst;                    // Active-high reset
logic [23:0] cpu_addr_byte;          // Word address converted to byte address

// Address decoding
logic        rom_cs;                 // ROM selected (0x000000–0x05FFFF)
logic        gfx_cs;                 // Graphics control (0x240000–0x24FFFF)
logic        io_cs;                  // I/O control (0x30C000–0x30C0FF)
logic        pal_cs;                 // Palette RAM (0x310000–0x3107FF)
logic        pal_ext_cs;             // Extended palette (0x314000–0x3147FF)
logic        main_ram_cs;            // Main RAM (0x318000–0x31BFFF or 0xFF8000–0xFFBFFF)
logic        spr_ram_cs;             // Sprite RAM (0x31C000–0x31C7FF or 0xFFC000–0xFFC7FF)
logic        rotary_cs;              // Rotary input (0x300000–0x300009)

// ROM interface
logic [15:0] rom_data;
logic        rom_ok;

// RAM ports
logic [15:0] main_ram_dout;
logic        main_ram_ok;
logic [15:0] pal_ram_dout;
logic [15:0] spr_ram_dout;

// I/O register write strobes
logic        io_write;               // Write to I/O at any _CS
logic        priority_we;            // Write to priority register (0x30C010)
logic        sound_latch_we;         // Write to sound latch (0x30C014)
logic        vblank_ack_we;          // Write to VBLANK ack (0x30C018)

// Interrupt signals
logic        vblank_rising;
logic        vblank_r;
logic        ipl6_n;                 // VBLANK IRQ (active low, IPL level 2)
logic        inta_n;                 // IACK detect (FC=7, ASn=0)

// Control register storage
logic [15:0] priority_reg;            // Sprite/tilemap priority control
logic [7:0]  sound_latch_main;        // Sound latch write from main CPU
logic [7:0]  sound_latch_mcu;         // Pseudo-MCU command echo

// Video timing
logic        hblank_n;
logic        vblank_n;

// =============================================================================
// Reset and Clock Domain
// =============================================================================

assign rst = ~reset_n;

// Synchronize async reset to sys clock
// (In actual implementation, use a 2-stage synchronizer)
// For now, direct assignment for clarity

// =============================================================================
// Address Decoder (Byte Address Format)
// =============================================================================
//
// cpu_addr[23:1] is word address; multiply by 2 for byte address.
// cpu_addr[23:16] selects 64K regions; lower bits select within.

assign cpu_addr_byte = {cpu_addr, 1'b0};  // Byte address

always_comb begin
    rom_cs       = (cpu_addr[23:19] == 5'h00) && !cpu_as_n;  // 0x000000–0x07FFFF (512 KB space for 384 KB ROM)
    gfx_cs       = (cpu_addr[23:16] == 8'h24) && !cpu_as_n;  // 0x240000–0x24FFFF
    rotary_cs    = (cpu_addr[23:16] == 8'h30 && cpu_addr[15:8] == 8'h00) && !cpu_as_n;  // 0x300000–0x3000FF
    io_cs        = (cpu_addr[23:16] == 8'h30 && cpu_addr[15:8] == 8'h0C) && !cpu_as_n;  // 0x30C000–0x30C0FF
    pal_cs       = (cpu_addr[23:16] == 8'h31 && cpu_addr[15:10] == 6'h00) && !cpu_as_n; // 0x310000–0x3107FF
    pal_ext_cs   = (cpu_addr[23:16] == 8'h31 && cpu_addr[15:11] == 5'h08) && !cpu_as_n; // 0x314000–0x3147FF
    main_ram_cs  = ((cpu_addr[23:16] == 8'h31 && cpu_addr[15:14] == 2'b10) ||           // 0x318000–0x31BFFF
                    (cpu_addr[23:16] == 8'hFF && cpu_addr[15:14] == 2'b10)) && !cpu_as_n; // 0xFF8000–0xFFBFFF
    spr_ram_cs   = ((cpu_addr[23:16] == 8'h31 && cpu_addr[15:11] == 5'h18) ||           // 0x31C000–0x31C7FF
                    (cpu_addr[23:16] == 8'hFF && cpu_addr[15:11] == 5'h18)) && !cpu_as_n; // 0xFFC000–0xFFC7FF
end

// =============================================================================
// CPU Data Output Multiplexer (Read Path)
// =============================================================================

always_comb begin
    if (rom_cs)
        cpu_dout = rom_data;
    else if (pal_cs || pal_ext_cs)
        cpu_dout = pal_ram_dout;
    else if (main_ram_cs)
        cpu_dout = main_ram_dout;
    else if (spr_ram_cs)
        cpu_dout = spr_ram_dout;
    else if (io_cs)
        cpu_dout = io_read_mux();      // I/O read mux (defined below)
    else if (rotary_cs)
        cpu_dout = 16'hFFFF;            // Rotary not yet implemented
    else if (gfx_cs)
        cpu_dout = 16'hFFFF;            // Graphics control (stub)
    else
        cpu_dout = 16'hFFFF;            // Open bus pull-up
end

// =============================================================================
// Program ROM Interface (via SDRAM)
// =============================================================================

assign prog_rom_addr = {2'b00, cpu_addr[18:1]};  // Convert word addr to byte addr in SDRAM
assign prog_rom_req  = rom_cs && cpu_rw && !cpu_dtack_n;  // Request on read when not ready
assign rom_ok        = prog_rom_ack;
assign rom_data      = prog_rom_data;

// =============================================================================
// Main RAM (16 KB Block RAM at 0x318000 / 0xFF8000)
// =============================================================================

logic [13:0] main_ram_addr;
logic [15:0] main_ram_din;
logic        main_ram_we_u;
logic        main_ram_we_l;

assign main_ram_addr = cpu_addr[14:1];  // 14-bit address (16K = 2^14 words)
assign main_ram_din  = cpu_din;
assign main_ram_we_u = main_ram_cs && !cpu_rw && !cpu_uds_n;
assign main_ram_we_l = main_ram_cs && !cpu_rw && !cpu_lds_n;

// Instantiate dual-port RAM (BRAM)
// Port A = CPU write path (byteena). Port B = CPU read path (same address, one-cycle latency).
// GUARDRAILS Rule 3/4: altsyncram in QUARTUS mode; register read output before use.
dual_port_ram_16x16k u_main_ram (
    .clk_a   (clk_sys),
    .addr_a  (main_ram_addr),
    .din_a   (main_ram_din),
    .we_u_a  (main_ram_we_u),
    .we_l_a  (main_ram_we_l),
    .dout_a  (),              // Port A write-only in QUARTUS altsyncram mode

    .clk_b   (clk_sys),       // Port B: CPU read path (registered 1 cycle)
    .addr_b  (main_ram_addr),
    .din_b   (16'h0),
    .we_u_b  (1'b0),
    .we_l_b  (1'b0),
    .dout_b  (main_ram_dout)
);

// =============================================================================
// Palette RAM (1024 entries at 0x310000; 2 KB = 2^11 bytes = 2^10 words)
// =============================================================================

logic [9:0]  pal_addr;
logic [15:0] pal_din;
logic        pal_we_u;
logic        pal_we_l;

assign pal_addr = cpu_addr[10:1];  // 10-bit address
assign pal_din  = cpu_din;
assign pal_we_u = (pal_cs || pal_ext_cs) && !cpu_rw && !cpu_uds_n;
assign pal_we_l = (pal_cs || pal_ext_cs) && !cpu_rw && !cpu_lds_n;

// Port A = CPU write; Port B = CPU read (same address, 1-cycle latency)
dual_port_ram_16x1k u_pal_ram (
    .clk_a   (clk_sys),
    .addr_a  (pal_addr),
    .din_a   (pal_din),
    .we_u_a  (pal_we_u),
    .we_l_a  (pal_we_l),
    .dout_a  (),

    .clk_b   (clk_sys),
    .addr_b  (pal_addr),
    .din_b   (16'h0),
    .we_u_b  (1'b0),
    .we_l_b  (1'b0),
    .dout_b  (pal_ram_dout)
);

// =============================================================================
// Sprite RAM (2 KB at 0x31C000; 256 sprites × 8 bytes)
// =============================================================================

logic [10:0] spr_addr;
logic [15:0] spr_din;
logic        spr_we_u;
logic        spr_we_l;

assign spr_addr = cpu_addr[11:1];  // 11-bit address
assign spr_din  = cpu_din;
assign spr_we_u = spr_ram_cs && !cpu_rw && !cpu_uds_n;
assign spr_we_l = spr_ram_cs && !cpu_rw && !cpu_lds_n;

// Port A = CPU write; Port B = CPU read (same address, 1-cycle latency)
dual_port_ram_16x2k u_spr_ram (
    .clk_a   (clk_sys),
    .addr_a  (spr_addr),
    .din_a   (spr_din),
    .we_u_a  (spr_we_u),
    .we_l_a  (spr_we_l),
    .dout_a  (),

    .clk_b   (clk_sys),
    .addr_b  (spr_addr),
    .din_b   (16'h0),
    .we_u_b  (1'b0),
    .we_l_b  (1'b0),
    .dout_b  (spr_ram_dout)
);

// =============================================================================
// I/O Control Register Writes and Reads
// =============================================================================

// Write strobes for specific I/O addresses
assign io_write = io_cs && !cpu_rw;

always_comb begin
    priority_we     = io_write && (cpu_addr[4:1] == 4'h0);  // 0x30C010
    sound_latch_we  = io_write && (cpu_addr[4:1] == 4'h2);  // 0x30C014
    vblank_ack_we   = io_write && (cpu_addr[4:1] == 4'h4);  // 0x30C018
end

// Control register storage (latches written values)
always @(posedge clk_sys or posedge rst) begin
    if (rst) begin
        priority_reg        <= 16'h0000;
        sound_latch_main    <= 8'h00;
        sound_latch_mcu     <= 8'h00;
    end else begin
        if (priority_we && !cpu_uds_n)
            priority_reg[15:8] <= cpu_din[15:8];
        if (priority_we && !cpu_lds_n)
            priority_reg[7:0]  <= cpu_din[7:0];

        if (sound_latch_we && !cpu_lds_n)
            sound_latch_main <= cpu_din[7:0];

        // Pseudo-MCU: echo back a test response (not real MCU)
        if (io_write && (cpu_addr[4:1] == 4'h6))  // 0x30C01C MCU write
            sound_latch_mcu <= cpu_din[7:0] ^ 8'h55;  // XOR as test
    end
end

// I/O read multiplexer
function logic [15:0] io_read_mux();
    logic [15:0] result;
    logic [2:0]  offset;

    offset = cpu_addr[4:2];

    case(offset)
        3'b000:  // 0x30C000 — INPUTS
                 result = {~joystick_p2[7:0], ~joystick_p1[7:0]};

        3'b001:  // 0x30C002 — SYSTEM (coins, start, vblank)
                 result = {~vblank_n, ~service, 1'b1, 1'b1,
                          ~coin[1], ~coin[0], ~joystick_p2[7], ~joystick_p1[7]};

        3'b010:  // 0x30C004 — DSW (dipswitches)
                 result = {~dipsw2[7:0], ~dipsw1[7:0]};

        3'b100:  // 0x30C008 — MCU return value (pseudo)
                 result = {8'h00, ~sound_latch_mcu};

        default: result = 16'hFFFF;  // Unmapped I/O
    endcase

    return result;
endfunction

// =============================================================================
// Video Timing and Sync
// =============================================================================

always @(posedge clk_sys or posedge rst) begin
    if (rst) begin
        hblank_n <= 1'b1;
        vblank_n <= 1'b1;
        vblank_r <= 1'b1;
    end else begin
        hblank_n <= hblank_n_in;
        vblank_n <= vblank_n_in;
        vblank_r <= vblank_n;
    end
end

assign hblank = ~hblank_n;
assign vblank = ~vblank_n;
assign hsync_n = hsync_n_in;
assign vsync_n = vsync_n_in;

// Detect VBLANK falling edge (transition from active to inactive)
assign vblank_rising = vblank_r && ~vblank_n;  // 0 -> 1 transition (rising edge of vblank_n)

// =============================================================================
// Main CPU Interrupt Handling (VBLANK IRQ6 / IPL Level 2)
// =============================================================================
//
// Pattern from COMMUNITY_PATTERNS.md Section 1.2:
// - IACK detection: FC[2:0] == 3'b111 and ASn == 0
// - IPL latch: SET on VBLANK falling edge, CLEAR on IACK only
// - VPAn = autovector signal = IACK detection

assign inta_n = ~&{cpu_fc[2], cpu_fc[1], cpu_fc[0], ~cpu_as_n};  // IACK detect

// IPL6 latch for VBLANK interrupt (active low, IPL level 2)
always @(posedge clk_sys or posedge rst) begin
    if (rst) begin
        ipl6_n <= 1'b1;  // Inactive at reset
    end else begin
        if (!inta_n) begin
            ipl6_n <= 1'b1;              // Clear on IACK
        end else if (vblank_rising) begin
            ipl6_n <= 1'b0;              // Set on VBLANK rising edge (end of vblank period)
        end
    end
end

// Wire IPL lines: IPL[2:0] = 3'b101 for level 2 VBLANK interrupt
assign cpu_ipl_n = {1'b1, ipl6_n, 1'b1};  // IPL[2:0] = {IPL2n, IPL1n, IPL0n}

// =============================================================================
// DTACK Generation (Data Transfer Acknowledge)
// =============================================================================
//
// Simplified: assert DTACK when bus data is ready.
// For SDRAM reads: wait for prog_rom_ack.
// For BRAM: data available next cycle (registered output).

logic        bus_ready;
logic [1:0]  dtack_counter;
logic        dtack_active;

assign bus_ready = rom_cs ? rom_ok : 1'b1;  // SDRAM requires ack; BRAM is immediate

always @(posedge clk_sys or posedge rst) begin
    if (rst) begin
        dtack_counter <= 2'b00;
        dtack_active  <= 1'b0;
    end else begin
        if (!cpu_as_n && !dtack_active) begin
            if (bus_ready) begin
                dtack_counter <= 2'b01;  // 1 wait state minimum
                dtack_active <= 1'b1;
            end
        end else if (dtack_active) begin
            if (dtack_counter == 2'b01) begin
                dtack_counter <= 2'b00;
                dtack_active  <= 1'b0;
            end else begin
                dtack_counter <= dtack_counter + 1'b1;
            end
        end
    end
end

assign cpu_dtack_n = ~dtack_active;

// =============================================================================
// Video Output Stubs (Placeholder for Graphics Subsystem)
// =============================================================================
//
// BAC06 tile generators and MXC06 sprite generator will be instantiated here.
// For now: generate a test pattern or solid color.

always @(posedge clk_pix) begin
    rgb_r <= (hpos[7:4] & vpos[7:4]) ? 8'hFF : 8'h00;
    rgb_g <= (hpos[7:4] ^ vpos[7:4]) ? 8'hFF : 8'h00;
    rgb_b <= (hpos[7:4] | vpos[7:4]) ? 8'hFF : 8'h00;
end

// =============================================================================
// Sound CPU Interface (M6502 / RP65C02A) — Stub for Now
// =============================================================================
//
// The sound CPU runs at 1.5 MHz. Full integration requires:
// - M6502 core (or T65 equivalent)
// - Sound ROM (32 KB at 0x8000–0xFFFF in 6502 address space)
// - YM2203, YM3812, OKI M6295 interfaces
// - Sound latch communication from main CPU at 0x30C014
//
// This is stubbed here; will be added in follow-up tasks.

assign snd_left  = 16'h0000;
assign snd_right = 16'h0000;
assign snd_rom_addr = 16'h0000;
assign snd_rom_req  = 1'b0;

// =============================================================================
// Graphics Control Registers (BAC06 Tilegen Stub)
// =============================================================================
//
// The DECO16IC (BAC06) tile generator family requires:
// - 3 × 16x16 tile layers with 8×8 or 16×16 tile size selection
// - Row/column scroll RAM
// - Tile color banking
// - Priority control
//
// Register map (per instance):
//   +0: Control 0 (tile size, enable, color bank)
//   +2: Control 1 (fine scroll X/Y, scroll enables)
//   +8/+0x400: Column/row scroll RAM
//   +0x2000: Tile data RAM
//
// This is stubbed; will be implemented in TASK-223 (BAC06 tile generator).

// Graphics register write capture (stub)
logic [15:0] gfx_regs [0:15];

always @(posedge clk_sys or posedge rst) begin
    if (rst) begin
        integer i;
        for (i = 0; i < 16; i = i + 1)
            gfx_regs[i] <= 16'h0000;
    end else if (gfx_cs && !cpu_rw) begin
        gfx_regs[cpu_addr[4:1]] <= cpu_din;
    end
end

// =============================================================================
// Module-end
// =============================================================================

endmodule

// =============================================================================
// Helper: Dual-Port RAM (16-bit × 16K words = 32 KB) — Main RAM
// GUARDRAILS Rule 3: explicit altsyncram for Quartus; behavioral for simulation.
// =============================================================================

module dual_port_ram_16x16k (
    input  logic        clk_a,
    input  logic [13:0] addr_a,
    input  logic [15:0] din_a,
    input  logic        we_u_a,
    input  logic        we_l_a,
    output logic [15:0] dout_a,

    input  logic        clk_b,
    input  logic [13:0] addr_b,
    input  logic [15:0] din_b,
    input  logic        we_u_b,
    input  logic        we_l_b,
    output logic [15:0] dout_b
);

`ifdef QUARTUS
// ── Synthesis: altsyncram DUAL_PORT with byte-enable (byteena_a=2) ──────────
// Write port A (CPU write), read port B (CPU read, video read).
// GUARDRAILS Rule 3: explicit altsyncram; byte-enable writes; M10K.
// GUARDRAILS Rule 6: byteena_b = 1'b1 on read-only DUAL_PORT port.
altsyncram #(
    .operation_mode             ("DUAL_PORT"),
    .width_a                    (16), .widthad_a (14), .numwords_a (16384),
    .width_b                    (16), .widthad_b (14), .numwords_b (16384),
    .outdata_reg_b              ("CLOCK1"), .address_reg_b ("CLOCK1"),
    .clock_enable_input_a       ("BYPASS"), .clock_enable_input_b ("BYPASS"),
    .clock_enable_output_b      ("BYPASS"),
    .intended_device_family     ("Cyclone V"),
    .lpm_type                   ("altsyncram"), .ram_block_type ("M10K"),
    .width_byteena_a            (2), .power_up_uninitialized ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) u_main_ram_inst (
    .clock0   (clk_a), .clock1   (clk_b),
    .address_a(addr_a), .data_a  (din_a),
    .wren_a   (we_u_a | we_l_a), .byteena_a({we_u_a, we_l_a}),
    .address_b(addr_b), .q_b     (dout_b),
    .wren_b   (1'b0),   .data_b  (16'd0), .q_a (),
    .byteena_b(1'b1),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
    .eccstatus(), .rden_a(), .rden_b(1'b1)
);
assign dout_a = 16'hFFFF;  // Port A is write-only in DUAL_PORT mode
`else
// ── Simulation: behavioral DP-RAM with byte enable ──────────────────────────
logic [15:0] mem [0:16383];  // 16K × 16-bit

always @(posedge clk_a) begin
    if (we_u_a) mem[addr_a][15:8] <= din_a[15:8];
    if (we_l_a) mem[addr_a][ 7:0] <= din_a[ 7:0];
    dout_a <= mem[addr_a];
end

always @(posedge clk_b) begin
    if (we_u_b) mem[addr_b][15:8] <= din_b[15:8];
    if (we_l_b) mem[addr_b][ 7:0] <= din_b[ 7:0];
    dout_b <= mem[addr_b];
end
`endif

endmodule

// =============================================================================
// Helper: Dual-Port RAM (16-bit × 1K words = 2 KB, for Palette)
// GUARDRAILS Rule 3: explicit altsyncram for Quartus; behavioral for simulation.
// =============================================================================

module dual_port_ram_16x1k (
    input  logic       clk_a,
    input  logic [9:0] addr_a,
    input  logic [15:0] din_a,
    input  logic       we_u_a,
    input  logic       we_l_a,
    output logic [15:0] dout_a,

    input  logic       clk_b,
    input  logic [9:0] addr_b,
    input  logic [15:0] din_b,
    input  logic       we_u_b,
    input  logic       we_l_b,
    output logic [15:0] dout_b
);

`ifdef QUARTUS
altsyncram #(
    .operation_mode             ("DUAL_PORT"),
    .width_a                    (16), .widthad_a (10), .numwords_a (1024),
    .width_b                    (16), .widthad_b (10), .numwords_b (1024),
    .outdata_reg_b              ("CLOCK1"), .address_reg_b ("CLOCK1"),
    .clock_enable_input_a       ("BYPASS"), .clock_enable_input_b ("BYPASS"),
    .clock_enable_output_b      ("BYPASS"),
    .intended_device_family     ("Cyclone V"),
    .lpm_type                   ("altsyncram"), .ram_block_type ("M10K"),
    .width_byteena_a            (2), .power_up_uninitialized ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) u_pal_ram_inst (
    .clock0   (clk_a), .clock1   (clk_b),
    .address_a(addr_a), .data_a  (din_a),
    .wren_a   (we_u_a | we_l_a), .byteena_a({we_u_a, we_l_a}),
    .address_b(addr_b), .q_b     (dout_b),
    .wren_b   (1'b0),   .data_b  (16'd0), .q_a (),
    .byteena_b(1'b1),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
    .eccstatus(), .rden_a(), .rden_b(1'b1)
);
assign dout_a = 16'hFFFF;
`else
logic [15:0] mem [0:1023];  // 1K × 16-bit

always @(posedge clk_a) begin
    if (we_u_a) mem[addr_a][15:8] <= din_a[15:8];
    if (we_l_a) mem[addr_a][ 7:0] <= din_a[ 7:0];
    dout_a <= mem[addr_a];
end

always @(posedge clk_b) begin
    if (we_u_b) mem[addr_b][15:8] <= din_b[15:8];
    if (we_l_b) mem[addr_b][ 7:0] <= din_b[ 7:0];
    dout_b <= mem[addr_b];
end
`endif

endmodule

// =============================================================================
// Helper: Dual-Port RAM (16-bit × 2K words = 4 KB, for Sprite RAM)
// GUARDRAILS Rule 3: explicit altsyncram for Quartus; behavioral for simulation.
// =============================================================================

module dual_port_ram_16x2k (
    input  logic        clk_a,
    input  logic [10:0] addr_a,
    input  logic [15:0] din_a,
    input  logic        we_u_a,
    input  logic        we_l_a,
    output logic [15:0] dout_a,

    input  logic        clk_b,
    input  logic [10:0] addr_b,
    input  logic [15:0] din_b,
    input  logic        we_u_b,
    input  logic        we_l_b,
    output logic [15:0] dout_b
);

`ifdef QUARTUS
altsyncram #(
    .operation_mode             ("DUAL_PORT"),
    .width_a                    (16), .widthad_a (11), .numwords_a (2048),
    .width_b                    (16), .widthad_b (11), .numwords_b (2048),
    .outdata_reg_b              ("CLOCK1"), .address_reg_b ("CLOCK1"),
    .clock_enable_input_a       ("BYPASS"), .clock_enable_input_b ("BYPASS"),
    .clock_enable_output_b      ("BYPASS"),
    .intended_device_family     ("Cyclone V"),
    .lpm_type                   ("altsyncram"), .ram_block_type ("M10K"),
    .width_byteena_a            (2), .power_up_uninitialized ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) u_spr_ram_inst (
    .clock0   (clk_a), .clock1   (clk_b),
    .address_a(addr_a), .data_a  (din_a),
    .wren_a   (we_u_a | we_l_a), .byteena_a({we_u_a, we_l_a}),
    .address_b(addr_b), .q_b     (dout_b),
    .wren_b   (1'b0),   .data_b  (16'd0), .q_a (),
    .byteena_b(1'b1),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
    .eccstatus(), .rden_a(), .rden_b(1'b1)
);
assign dout_a = 16'hFFFF;
`else
logic [15:0] mem [0:2047];  // 2K × 16-bit

always @(posedge clk_a) begin
    if (we_u_a) mem[addr_a][15:8] <= din_a[15:8];
    if (we_l_a) mem[addr_a][ 7:0] <= din_a[ 7:0];
    dout_a <= mem[addr_a];
end

always @(posedge clk_b) begin
    if (we_u_b) mem[addr_b][15:8] <= din_b[15:8];
    if (we_l_b) mem[addr_b][ 7:0] <= din_b[ 7:0];
    dout_b <= mem[addr_b];
end
`endif

endmodule
