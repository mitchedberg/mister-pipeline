`default_nettype none
// =============================================================================
// X1-001A / X1-002A — Taito X Sprite Generator
// =============================================================================
//
// Phase 1: Sprite RAM + CPU interface.
//
// The X1-001A is a dedicated sprite generator used in Taito X arcade hardware
// (Superman, Twin Hawk, Gigandes, Balloon Brothers, etc.).
//
// Architecture (from MAME src/devices/video/x1_001.cpp):
//
//   Two CPU-addressable RAMs:
//     spriteylow[0x300 bytes]   — Y coords + BG scroll RAM
//     spritecode[0x2000 words]  — Tile codes, X coords, flip, color, BG tiles
//   Four control registers (spritectrl[0..3])
//
// Sprite entry format (foreground, 512 entries):
//   spritecode[i]          word:  [15]=FlipX, [14]=FlipY, [13:0]=tile_code
//   spritecode[0x200+i]    word:  [15:11]=color(5b), [8]=X_sign, [7:0]=X_low
//   spriteylow[i]          byte:  [7:0]=Y position
//
//   Effective X = (x_low & 0xFF) - (x_low & 0x100)   (9-bit signed)
//   Effective Y on screen = max_y - ((Y + yoffs) & 0xFF)
//
// Control registers at 0xD00600–0xD00607:
//   ctrl[0] bit[6]    = screen flip
//   ctrl[0] bits[1:0] = BG start column offset
//   ctrl[1] bits[3:0] = BG num columns (0=off, 1=16)
//   ctrl[1] bit[6]    = double-buffer bank select (XOR formula)
//   ctrl[2,3]         = upper column scroll mask
//
// Priority: index 0 = highest priority (drawn last, overwrites all others)
// Transparency: pen 0 in palette = transparent
// Zoom: none (16×16 fixed)
// Double buffer: bank_size = 0x1000 words
//
// MAME reference: src/devices/video/x1_001.cpp
// Driver:         src/mame/taito/taito_x.cpp
//
// Phase 1 scope:
//   [X] Sprite Y RAM   — 0x300-byte dual-port BRAM (CPU write, scanner read)
//   [X] Sprite code RAM — 0x2000-word dual-port BRAM (CPU write, scanner read)
//   [X] CPU interface  — chip-select, read/write, byte-enable
//   [X] Control registers — spritectrl[0..3]
//
// Phase 2 (future): scanner FSM, tile fetch, line buffer, pixel output
// =============================================================================

module x1_001a (
    input  logic        clk,
    input  logic        rst_n,

    // ── Sprite Y-coordinate RAM CPU port ─────────────────────────────────────
    // Maps to 68000 address 0xD00000 – 0xD005FF (byte-addressed)
    // The 68000 uses 16-bit word accesses; byte enables select high/low byte.
    input  logic        yram_cs,          // chip select
    input  logic        yram_we,          // write enable
    input  logic  [8:0] yram_addr,        // word address [8:0] (max 0x17F = 383)
    input  logic [15:0] yram_din,         // write data (16-bit word)
    output logic [15:0] yram_dout,        // read data
    input  logic  [1:0] yram_be,          // byte enables [1]=high byte, [0]=low byte

    // ── Sprite code / attribute RAM CPU port ─────────────────────────────────
    // Maps to 68000 address 0xE00000 – 0xE03FFF (word-addressed)
    input  logic        cram_cs,          // chip select
    input  logic        cram_we,          // write enable
    input  logic [12:0] cram_addr,        // word address [12:0]
    input  logic [15:0] cram_din,         // write data
    output logic [15:0] cram_dout,        // read data
    input  logic  [1:0] cram_be,          // byte enables

    // ── Control register CPU port ─────────────────────────────────────────────
    // Maps to 68000 address 0xD00600 – 0xD00607 (4 × 16-bit registers)
    input  logic        ctrl_cs,          // chip select
    input  logic        ctrl_we,          // write enable
    input  logic  [1:0] ctrl_addr,        // register index 0–3
    input  logic [15:0] ctrl_din,         // write data
    output logic [15:0] ctrl_dout,        // read data
    input  logic  [1:0] ctrl_be,          // byte enables

    // ── Internal scanner read ports (Phase 2 will use these) ─────────────────
    // Y RAM scanner port (word address)
    input  logic  [8:0] scan_yram_addr,
    output logic [15:0] scan_yram_data,

    // Code RAM scanner port (word-addressed)
    input  logic [12:0] scan_cram_addr,
    output logic [15:0] scan_cram_data,

    // ── Decoded control register outputs ─────────────────────────────────────
    output logic        flip_screen,      // ctrl[0] bit 6
    output logic  [1:0] bg_startcol,      // ctrl[0] bits [1:0]
    output logic  [3:0] bg_numcol,        // ctrl[1] bits [3:0]
    output logic        frame_bank,       // double-buffer active bank (computed)
    output logic [15:0] col_upper_mask    // ctrl[3:2] — 16-bit column scroll mask
);

    // =========================================================================
    // Sprite Y-coordinate RAM
    // 0x300 bytes = 768 bytes.
    // Stored as 0x180 (384) 16-bit words, word address [9:0] uses bits [8:0]
    // (top bit is spare, max used word addr = 0x17F).
    // CPU and scanner use the same physical RAM with independent read ports.
    // =========================================================================

    logic [7:0] yram_lo [0:383];   // byte 0 (low)
    logic [7:0] yram_hi [0:383];   // byte 1 (high)

    // CPU write port
    always_ff @(posedge clk) begin
        if (yram_cs && yram_we) begin
            if (yram_be[0]) yram_lo[yram_addr[8:0]] <= yram_din[7:0];
            if (yram_be[1]) yram_hi[yram_addr[8:0]] <= yram_din[15:8];
        end
    end

    // CPU read port (synchronous)
    always_ff @(posedge clk) begin
        if (yram_cs && !yram_we)
            yram_dout <= { yram_hi[yram_addr[8:0]], yram_lo[yram_addr[8:0]] };
    end

    // Scanner read port (synchronous)
    always_ff @(posedge clk) begin
        scan_yram_data <= { yram_hi[scan_yram_addr[8:0]], yram_lo[scan_yram_addr[8:0]] };
    end

    // =========================================================================
    // Sprite code / attribute RAM
    // 0x2000 × 16-bit words = 16 KB.
    // =========================================================================

    logic [7:0] cram_lo [0:8191];  // low bytes
    logic [7:0] cram_hi [0:8191];  // high bytes

    // CPU write port
    always_ff @(posedge clk) begin
        if (cram_cs && cram_we) begin
            if (cram_be[0]) cram_lo[cram_addr] <= cram_din[7:0];
            if (cram_be[1]) cram_hi[cram_addr] <= cram_din[15:8];
        end
    end

    // CPU read port (synchronous)
    always_ff @(posedge clk) begin
        if (cram_cs && !cram_we)
            cram_dout <= { cram_hi[cram_addr], cram_lo[cram_addr] };
    end

    // Scanner read port (synchronous)
    always_ff @(posedge clk) begin
        scan_cram_data <= { cram_hi[scan_cram_addr], cram_lo[scan_cram_addr] };
    end

    // =========================================================================
    // Control registers  spritectrl[0..3]
    // Four 16-bit registers exposed at four word addresses.
    // MAME uses only the low byte of each word for decoded logic; the full
    // 16-bit word is stored so both byte-enables are meaningful.
    // =========================================================================

    logic [15:0] spritectrl [0:3];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spritectrl[0] <= 16'hFFFF;
            spritectrl[1] <= 16'hFFFF;
            spritectrl[2] <= 16'hFFFF;
            spritectrl[3] <= 16'hFFFF;
        end else if (ctrl_cs && ctrl_we) begin
            if (ctrl_be[0]) spritectrl[ctrl_addr][ 7:0] <= ctrl_din[7:0];
            if (ctrl_be[1]) spritectrl[ctrl_addr][15:8] <= ctrl_din[15:8];
        end
    end

    // Control register read (combinational, no wait state needed)
    always_comb begin
        ctrl_dout = 16'h0000;
        if (ctrl_cs && !ctrl_we)
            ctrl_dout = spritectrl[ctrl_addr];
    end

    // =========================================================================
    // Decoded control outputs (low byte of each register, per MAME)
    // =========================================================================

    // Screen flip: ctrl[0] bit 6
    assign flip_screen   = spritectrl[0][6];

    // BG start column: ctrl[0] bits [1:0]
    assign bg_startcol   = spritectrl[0][1:0];

    // BG column count: ctrl[1] bits [3:0]
    assign bg_numcol     = spritectrl[1][3:0];

    // Upper column scroll mask: ctrl[3] low byte : ctrl[2] low byte
    assign col_upper_mask = {spritectrl[3][7:0], spritectrl[2][7:0]};

    // Double-buffer bank select.
    // MAME formula: bank = (((ctrl2 ^ (~ctrl2 << 1)) & 0x40) != 0)
    // where ctrl2 = spritectrl[1][7:0].
    //
    // Expand bit 6 of (c ^ ~(c<<1)):
    //   (c<<1)[6] = c[5]         (left-shift by 1 in 8-bit)
    //   ~(c<<1)[6] = ~c[5]
    //   result[6] = c[6] ^ ~c[5]
    assign frame_bank = spritectrl[1][6] ^ (~spritectrl[1][5]);

endmodule
