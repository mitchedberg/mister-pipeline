`default_nettype none
// =============================================================================
// TC0630FDP — Taito F3 Display Processor (Step 2: Text Layer)
// =============================================================================
// Integrates all video functions for Taito F3 arcade hardware (1992–1997):
//   · 4 scrolling tilemap layers (PF1–PF4), 16×16 tiles, 4/5/6bpp
//   · Text layer (64×64 8×8 tiles, CPU-writable characters)       ← STEP 2 ✓
//   · Pivot/pixel layer (64×32 8×8 tiles, column-major, CPU-writable)
//   · Sprite engine: 17-bit tile codes, 8-bit zoom, 4 priority groups, alpha blend
//   · Per-scanline Line RAM: rowscroll, colscroll, zoom, priority, clip, alpha, mosaic
//   · Layer compositor with 4 clip planes and full alpha blending
//
// MAME source: src/mame/taito/taito_f3.cpp + taito_f3_v.cpp
// Games: RayForce, Darius Gaiden, Elevator Action Returns, Bubble Symphony, etc.
//
// CPU address map (chip-relative 18-bit word addresses, i.e. cpu_addr[18:1]):
//   0x00000–0x0DFFF: (Sprite RAM, PF RAM — added in later steps)
//   0x0E000–0x0EFFF: Text RAM      (4096 × 16-bit words, 8KB)  ← STEP 2
//   0x0F000–0x0FFFF: Character RAM (4096 × 16-bit words = 8192 bytes) ← STEP 2
//   0x00000–0x0000F: Display control registers (testbench word addr 0–15)
//
// Video timing (pixel clock domain):
//   Pixel clock: 26.686 MHz / 4 = 6.6715 MHz
//   H total: 432 pixels, H active: 320 pixels, H start: pixel 46
//   V total: 262 lines,  V active: 232 lines,  V start: line 24
//   Refresh: ~58.97 Hz
//
// Step 2 additions:
//   · Text RAM (4096 × 16-bit) with CPU read/write
//   · Character RAM (2048 × 32-bit = 8KB) with CPU read/write
//   · tc0630fdp_text submodule instantiated and wired
//   · text_pixel_out port exposes text layer pixel for testbench validation
// =============================================================================

module tc0630fdp (
    // ── Clocks and Reset ───────────────────────────────────────────────────
    input  logic        clk,            // pixel clock (6.6715 MHz in hardware)
    input  logic        async_rst_n,

    // ── CPU Interface (68EC020 bus, 16-bit) ────────────────────────────────
    input  logic        cpu_cs,         // chip select (active high)
    input  logic        cpu_rw,         // 1=read, 0=write
    input  logic [18:1] cpu_addr,       // word address within chip window
    input  logic [15:0] cpu_din,        // write data
    input  logic        cpu_lds_n,      // lower byte select (active low)
    input  logic        cpu_uds_n,      // upper byte select (active low)
    output logic [15:0] cpu_dout,       // read data
    output logic        cpu_dtack_n,    // data transfer acknowledge (active low)

    // ── Video Timing Outputs ───────────────────────────────────────────────
    output logic        hblank,         // horizontal blank (active high)
    output logic        vblank,         // vertical blank   (active high)
    output logic        hsync,          // horizontal sync  (active high)
    output logic        vsync,          // vertical sync    (active high)
    output logic [ 9:0] hpos,           // pixel counter within H total (0..431)
    output logic [ 8:0] vpos,           // line counter within V total  (0..261)

    // ── Interrupt Outputs ──────────────────────────────────────────────────
    output logic        int_vblank,     // INT2: fires at VBLANK start
    output logic        int_hblank,     // INT3: pseudo-hblank (~10K CPU cycles after INT2)

    // ── GFX ROM Interface (stub — driven 0 until PF layer step) ──────────
    output logic [24:0] gfx_lo_addr,    // GFX ROM low-plane byte address
    output logic        gfx_lo_rd,      // GFX ROM low-plane read strobe
    input  logic [ 7:0] gfx_lo_data,   // GFX ROM low-plane read data

    output logic [24:0] gfx_hi_addr,   // GFX ROM hi-plane byte address
    output logic        gfx_hi_rd,     // GFX ROM hi-plane read strobe
    input  logic [ 7:0] gfx_hi_data,  // GFX ROM hi-plane read data

    // ── Palette Interface (stub — driven 0 until compositor step) ─────────
    output logic [14:0] pal_addr,       // palette RAM address
    output logic        pal_rd,         // palette read strobe
    input  logic [15:0] pal_data,       // palette read data

    // ── Video Output (stub — driven 0 until compositor step) ─────────────
    output logic [23:0] rgb_out,        // 24-bit RGB to TC0650FDA DAC
    output logic        pixel_valid,    // high during active display

    // ── Text Layer Pixel Output (Step 2) ──────────────────────────────────
    // Exposes the text layer line buffer pixel at the current hpos.
    // Format: {color[4:0], pen[3:0]}  (pen==0 → transparent)
    // Used by the testbench to validate tile rendering.
    output logic [ 8:0] text_pixel_out
);

// =============================================================================
// Reset synchronizer (2-FF)
// =============================================================================
logic [1:0] rst_pipe;
always_ff @(posedge clk or negedge async_rst_n) begin
    if (!async_rst_n) rst_pipe <= 2'b00;
    else              rst_pipe <= {rst_pipe[0], 1'b1};
end
logic rst_n;
assign rst_n = rst_pipe[1];

// =============================================================================
// Video Timing Generator
// =============================================================================
// H timing (pixel clock domain):
//   H total:   432 pixels (0..431)
//   H active:  pixels 46..365  (320 pixels)
//   H blank:   pixels 0..45 and 366..431
//   H sync:    pixels 0..31  (within blanking period)
//
// V timing:
//   V total:   262 lines (0..261)
//   V active:  lines 24..255  (232 lines)
//   V blank:   lines 0..23 and 256..261
//   V sync:    lines 0..3  (within blanking period)
//
// Derived from MAME: screen.set_raw(26.686_MHz_XTAL/4, 432, 46, 320+46, 262, 24, 232+24)
// =============================================================================

localparam int H_TOTAL   = 432;
localparam int H_START   = 46;
localparam int H_END     = 366;
localparam int H_SYNC_E  = 32;
localparam int V_TOTAL   = 262;
localparam int V_START   = 24;
localparam int V_END     = 256;
localparam int V_SYNC_E  = 4;

// H/V counters
always_ff @(posedge clk) begin
    if (!rst_n) begin
        hpos <= 10'b0;
        vpos <=  9'b0;
    end else begin
        if (hpos == 10'(H_TOTAL - 1)) begin
            hpos <= 10'b0;
            if (vpos == 9'(V_TOTAL - 1))
                vpos <= 9'b0;
            else
                vpos <= vpos + 9'b1;
        end else begin
            hpos <= hpos + 10'b1;
        end
    end
end

// Timing outputs (combinational)
always_comb begin
    hblank = (hpos < 10'(H_START)) || (hpos >= 10'(H_END));
    vblank = (vpos <  9'(V_START)) || (vpos >=  9'(V_END));
    hsync  = (hpos < 10'(H_SYNC_E));
    vsync  = (vpos <  9'(V_SYNC_E));
end

assign pixel_valid = !hblank && !vblank;

// =============================================================================
// Interrupt Generation
// =============================================================================
logic vblank_r;
always_ff @(posedge clk) begin
    if (!rst_n) vblank_r <= 1'b0;
    else        vblank_r <= vblank;
end
logic vblank_rise;
assign vblank_rise = vblank & ~vblank_r;

localparam int INT3_DELAY = 2500;
logic [11:0] int3_cnt;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        int_vblank <= 1'b0;
        int_hblank <= 1'b0;
        int3_cnt   <= 12'b0;
    end else begin
        int_vblank <= 1'b0;
        int_hblank <= 1'b0;
        if (vblank_rise) begin
            int_vblank <= 1'b1;
            int3_cnt   <= 12'(INT3_DELAY);
        end
        if (int3_cnt != 12'b0) begin
            int3_cnt <= int3_cnt - 12'b1;
            if (int3_cnt == 12'd1)
                int_hblank <= 1'b1;
        end
    end
end

// =============================================================================
// CPU Address Decode
// =============================================================================
// cpu_addr[18:1] is the word address within the TC0630FDP chip window.
// The full F3 CPU map is:
//   0x600000–0x60FFFF → Sprite RAM     (word addr 0x00000–0x07FFF, 32K words)
//   0x610000–0x61BFFF → Playfield RAM  (word addr 0x08000–0x0DFFF, 24K words)
//   0x61C000–0x61DFFF → Text RAM       (word addr 0x0E000–0x0EFFF,  4K words)
//   0x61E000–0x61FFFF → Character RAM  (word addr 0x0F000–0x0FFFF,  4K words = 4096×16b)
//   ...
//   0x660000–0x66001F → Display ctrl   (word addr 0x30000–0x3000F, 16 words)
//
// For testbench simplicity (cpu_addr is 18-bit), we map:
//   Text RAM:    cpu_addr[18:13] = 6'b000_111_0 (addr[18:12]=0x0E xxx → bits[18:12]=b0001110)
//     → cpu_addr[18:12] == 7'b000_1110 → addr range 0x0E000–0x0EFFF
//   Char RAM:    cpu_addr[18:12] == 7'b000_1111 → addr range 0x0F000–0x0FFFF
//   Ctrl regs:   cpu_addr[18:4]  == 15'h3000x
//
// Simplified decode: use cpu_addr[18:12] for region selection.
// =============================================================================
logic cs_ctrl;     // display control registers
logic cs_text;     // text RAM
logic cs_char;     // character RAM

always_comb begin
    cs_ctrl = 1'b0;
    cs_text = 1'b0;
    cs_char = 1'b0;
    if (cpu_cs) begin
        // cpu_addr[18:1] is the 18-bit word address within the chip window.
        // Region decode using cpu_addr[18:13] (6 bits = top 6 of 18):
        //   Text RAM : 0x0E000–0x0EFFF → cpu_addr[18:13] = 6'b001110 = 6'h0E
        //   Char RAM : 0x0F000–0x0FFFF → cpu_addr[18:13] = 6'b001111 = 6'h0F
        //   Ctrl regs: 0x00000–0x0000F → cpu_addr[18:13] = 6'h00
        //              (testbench drives addr 0..15 directly for ctrl accesses)
        if      (cpu_addr[18:13] == 6'h0f) cs_char = 1'b1;
        else if (cpu_addr[18:13] == 6'h0e) cs_text = 1'b1;
        else                                cs_ctrl = 1'b1;
    end
end

// =============================================================================
// Display Control Register Bank
// =============================================================================
logic [15:0] ctrl [0:15];

logic [1:0] cpu_be;
assign cpu_be = {~cpu_uds_n, ~cpu_lds_n};

logic [3:0] ctrl_idx;
assign ctrl_idx = cpu_addr[4:1];

// Write
always_ff @(posedge clk) begin
    if (!rst_n) begin
        for (int i = 0; i < 16; i++) ctrl[i] <= 16'b0;
    end else if (cs_ctrl && !cpu_rw) begin
        if (ctrl_idx != 4'd8  && ctrl_idx != 4'd9  &&
            ctrl_idx != 4'd10 && ctrl_idx != 4'd11 &&
            ctrl_idx != 4'd14) begin
            if (cpu_be[1]) ctrl[ctrl_idx][15:8] <= cpu_din[15:8];
            if (cpu_be[0]) ctrl[ctrl_idx][ 7:0] <= cpu_din[ 7:0];
        end
    end
end

// Read + DTACK
logic [15:0] ctrl_rdata;
always_ff @(posedge clk) begin
    if (!rst_n) begin
        ctrl_rdata <= 16'b0;
    end else if (cs_ctrl && cpu_rw) begin
        ctrl_rdata <= ctrl[ctrl_idx];
    end
end

always_ff @(posedge clk) begin
    if (!rst_n)      cpu_dtack_n <= 1'b1;
    else if (cpu_cs) cpu_dtack_n <= 1'b0;
    else             cpu_dtack_n <= 1'b1;
end

// Decoded control outputs
logic [15:0] pf_xscroll [0:3];
assign pf_xscroll[0] = ctrl[0];
assign pf_xscroll[1] = ctrl[1];
assign pf_xscroll[2] = ctrl[2];
assign pf_xscroll[3] = ctrl[3];

logic [15:0] pf_yscroll [0:3];
assign pf_yscroll[0] = ctrl[4];
assign pf_yscroll[1] = ctrl[5];
assign pf_yscroll[2] = ctrl[6];
assign pf_yscroll[3] = ctrl[7];

logic [15:0] pixel_xscroll;
logic [15:0] pixel_yscroll;
assign pixel_xscroll = ctrl[12];
assign pixel_yscroll = ctrl[13];

logic extend_mode;
assign extend_mode = ctrl[15][7];

// =============================================================================
// Text RAM (4096 × 16-bit = 8KB)
// CPU address range: cpu_addr[18:12]==0x0E → word index cpu_addr[11:0]
// =============================================================================
logic [15:0] text_ram [0:4095];

logic [11:0] text_wr_addr;
logic [11:0] text_cpu_raddr;
assign text_wr_addr   = cpu_addr[12:1];   // bits[12:1] = word index within text RAM
assign text_cpu_raddr = cpu_addr[12:1];

// CPU write to Text RAM
always_ff @(posedge clk) begin
    if (!rst_n) begin
        // No reset needed for RAM; initial contents are undefined (same as BRAM)
    end else if (cs_text && !cpu_rw) begin
        if (cpu_be[1]) text_ram[text_wr_addr][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) text_ram[text_wr_addr][ 7:0] <= cpu_din[ 7:0];
    end
end

// CPU read from Text RAM (registered, 1-cycle latency)
logic [15:0] text_cpu_rdata;
always_ff @(posedge clk) begin
    if (!rst_n)
        text_cpu_rdata <= 16'b0;
    else if (cs_text && cpu_rw)
        text_cpu_rdata <= text_ram[text_cpu_raddr];
end

// Async read port for tc0630fdp_text submodule
logic [11:0] text_rd_addr_w;
logic [15:0] text_q_w;
assign text_q_w = text_ram[text_rd_addr_w];

// =============================================================================
// Character RAM (256 tiles × 8 rows × 4 bytes = 2048 words × 32-bit = 8KB)
// CPU address range: cpu_addr[18:12]==0x0F → word index cpu_addr[11:1]
// CPU accesses are 16-bit (big-endian words); two 16-bit writes fill one 32-bit word.
// char_ram is organized as 2048 × 32-bit words:
//   word index = {char_code[7:0], fetch_py[2:0]} (11 bits)
//   within each word: bits[31:24]=b3, [23:16]=b2, [15:8]=b1, [7:0]=b0
// CPU word address cpu_addr[12:1] maps to half-word:
//   upper 32-bit word = cpu_addr[12:2] (10 bits)
//   upper/lower 16-bit half = cpu_addr[1]
// =============================================================================
// We store character RAM as 4096 × 8-bit bytes to simplify CPU 16-bit write access.
// The text submodule reads it as 2048 × 32-bit words.
logic [7:0] char_ram [0:8191];

// char_word_addr: 12-bit word address within char RAM (2 bytes per word → 4096 words max,
// but char RAM is only 8KB = 4096 bytes = 2048 16-bit words → addr[12:1]).
// cpu_addr[13:1] gives word address; [0] = 0 always (16-bit aligned access).
// char_word_addr: 12-bit word index within char RAM (4096 × 16-bit words = 8KB).
// cpu_addr[12:1] gives the word address; cpu_addr[13] selects char RAM region.
logic [11:0] char_word_addr;
assign char_word_addr = cpu_addr[12:1];   // 12-bit word index (0..4095)

// CPU write to Character RAM (byte-lane aware)
// Each 16-bit CPU word writes two consecutive bytes at byte offset = char_word_addr*2.
always_ff @(posedge clk) begin
    if (!rst_n) begin
        // No reset for RAM
    end else if (cs_char && !cpu_rw) begin
        if (cpu_be[1]) char_ram[{char_word_addr, 1'b0}] <= cpu_din[15:8];
        if (cpu_be[0]) char_ram[{char_word_addr, 1'b1}] <= cpu_din[ 7:0];
    end
end

// CPU read from Character RAM (registered, 1-cycle)
logic [15:0] char_cpu_rdata;
always_ff @(posedge clk) begin
    if (!rst_n)
        char_cpu_rdata <= 16'b0;
    else if (cs_char && cpu_rw) begin
        char_cpu_rdata <= {char_ram[{char_word_addr, 1'b0}],
                           char_ram[{char_word_addr, 1'b1}]};
    end
end

// Async 32-bit read port for tc0630fdp_text submodule
// char_rd_addr[10:0] = {char_code[7:0], fetch_py[2:0]} → byte_base = addr * 4
// char_q[31:0] is LITTLE-ENDIAN: char_q[7:0]=b0, [15:8]=b1, [23:16]=b2, [31:24]=b3
// where b0..b3 are sequential bytes starting at byte_base:
//   b0 = char_ram[byte_base+0], b1 = char_ram[byte_base+1],
//   b2 = char_ram[byte_base+2], b3 = char_ram[byte_base+3]
// The CPU writes b0/b1 as one 16-bit word (cpu_din[15:8]=b0, cpu_din[7:0]=b1)
// and b2/b3 as the next word.
logic [10:0] char_rd_addr_w;
logic [31:0] char_q_w;
assign char_q_w = {char_ram[{char_rd_addr_w, 2'd3}],   // char_q[31:24] = b3
                   char_ram[{char_rd_addr_w, 2'd2}],   // char_q[23:16] = b2
                   char_ram[{char_rd_addr_w, 2'd1}],   // char_q[15:8]  = b1
                   char_ram[{char_rd_addr_w, 2'd0}]};  // char_q[7:0]   = b0

// =============================================================================
// CPU read data mux
// =============================================================================
always_comb begin
    unique case (1'b1)
        cs_ctrl: cpu_dout = ctrl_rdata;
        cs_text: cpu_dout = text_cpu_rdata;
        cs_char: cpu_dout = char_cpu_rdata;
        default: cpu_dout = 16'b0;
    endcase
end

// =============================================================================
// tc0630fdp_text — Text layer engine (Step 2)
// =============================================================================
tc0630fdp_text u_text (
    .clk          (clk),
    .rst_n        (rst_n),
    .hblank       (hblank),
    .vpos         (vpos),
    .text_rd_addr (text_rd_addr_w),
    .text_q       (text_q_w),
    .char_rd_addr (char_rd_addr_w),
    .char_q       (char_q_w),
    .hpos         (hpos),
    .text_pixel   (text_pixel_out)
);

// =============================================================================
// GFX ROM / Palette / RGB stubs (driven 0 until later steps)
// =============================================================================
assign gfx_lo_addr = 25'b0;
assign gfx_lo_rd   = 1'b0;
assign gfx_hi_addr = 25'b0;
assign gfx_hi_rd   = 1'b0;
assign pal_addr    = 15'b0;
assign pal_rd      = 1'b0;
assign rgb_out     = 24'b0;

// =============================================================================
// Suppress unused-signal warnings
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused;
assign _unused = ^{gfx_lo_data,
                   gfx_hi_data,
                   pal_data,
                   pf_xscroll[0], pf_xscroll[1], pf_xscroll[2], pf_xscroll[3],
                   pf_yscroll[0], pf_yscroll[1], pf_yscroll[2], pf_yscroll[3],
                   pixel_xscroll, pixel_yscroll,
                   extend_mode,
                   vblank_rise};
/* verilator lint_on UNUSED */

endmodule
