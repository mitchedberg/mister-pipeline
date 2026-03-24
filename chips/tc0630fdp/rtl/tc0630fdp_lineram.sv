`default_nettype none
// =============================================================================
// TC0630FDP — Line RAM Parser  (Step 16: +pivot layer control)
// =============================================================================
// The Line RAM is 64 KB (32768 × 16-bit words) that provides per-scanline
// override of virtually every display parameter.  This module:
//   · Owns the Line RAM BRAM (32K words).
//   · Handles CPU reads and writes.
//   · At every HBLANK falling-edge (hblank_fall), reads the next scanline's
//     rowscroll values (PF1–PF4) and their enable bits, and registers them
//     so that the BG tilemap engines can consume them during the next active
//     scan.
//
// Step 5 implementation: rowscroll + rowscroll-enable + alt-tilemap enable.
// Step 6 addition: per-scanline zoom (X and Y) for PF1–PF4 (section1 §9.9).
//   PF2/PF4 Y-zoom are physically swapped in hardware — corrected here.
// Step 7 addition: per-scanline colscroll (§9.2 bits[8:0]) and palette
//   addition (§9.10) for PF1–PF4.
// Step 11 addition: per-scanline PF priority (§9.12 bits[3:0]) and sprite
//   group priority (§9.8 bits[15:0]) for the compositor.
// Step 12 addition: per-scanline clip plane boundaries (§9.3) and per-layer
//   clip enable/invert flags from §9.12 (PF layers) and §9.7 (sprite layer).
// Step 13 addition: per-scanline alpha blend coefficients (§9.5) and blend
//   mode bits from §9.12 (PF layers, bits[15:14]) and §9.4 (sprite/pivot layer).
//
// §9.5 Alpha blend values: byte 0x6200–0x63FF → word 0x3100 + scan
//   bits[15:12] = B_src (reverse blend source coeff)
//   bits[11:8]  = A_src (normal blend source coeff)
//   bits[7:4]   = B_dst (reverse blend destination coeff)
//   bits[3:0]   = A_dst (normal blend destination coeff)
//   Range 0–8: 0=transparent, 8=fully opaque.
//
// §9.4 Pivot/Sprite blend control: byte 0x6000–0x61FF → word 0x3000 + scan
//   bits[7:6] = blend mode for sprite group 0xC0 (00=opaque,01=blendA,10=blendB,11=opaque)
//   bits[5:4] = blend mode for sprite group 0x80
//   bits[3:2] = blend mode for sprite group 0x40
//   bits[1:0] = blend mode for sprite group 0x00
//
// §9.12 pp_word bits[15:14]: PF blend mode
//   00 = opaque   01 = normal blend A   10 = reverse blend B   11 = opaque (layer mode)
//
// Clip plane data addresses (byte addr → word addr by /2):
//   §9.3 Plane 0: byte 0x5000–0x51FE → word 0x2800 + scan
//   §9.3 Plane 1: byte 0x5200–0x53FE → word 0x2900 + scan
//   §9.3 Plane 2: byte 0x5400–0x55FE → word 0x2A00 + scan
//   §9.3 Plane 3: byte 0x5600–0x57FE → word 0x2B00 + scan
//   Word format: bits[15:8]=right, bits[7:0]=left  (8-bit coordinates)
//
// §9.7 Sprite mix/clip: byte 0x7400–0x75FF → word 0x3A00 + scan
//   bits[11:8]=clip_enable, bits[7:4]=clip_invert, bit[0]=clip_invert_sense
//
// §9.12 PF mix/priority (already in pp_word, extract extra bits):
//   bits[11:8]=clip_enable, bits[7:4]=clip_invert, bit[12]=clip_invert_sense
//   PF1=0x5800, PF2=0x5900, PF3=0x5A00, PF4=0x5B00
//
// Address layout — chip-relative 16-bit WORD addresses within Line RAM BRAM
// (convert from section1 byte addresses by dividing by 2):
//
//   Enable/latch control (lower half, word addrs 0x0000–0x1FFF):
//     Rowscroll enable base  : byte 0x0C00 → word 0x0600  (256 scanlines)
//     Colscroll/alt-tmap en  : byte 0x0000 → word 0x0000  (256 scanlines)
//     Zoom enable base       : byte 0x0800 → word 0x0400  (256 scanlines)
//     Pal-add enable base    : byte 0x0A00 → word 0x0500  (256 scanlines)
//
//   Per-scanline data (upper half, word addrs 0x2000–0x7FFF):
//     Colscroll PF1–PF4 base : byte 0x4000 → word 0x2000  (stride 0x100 per PF)
//     Rowscroll PF1–PF4 base : byte 0xA000 → word 0x5000  (stride 0x100 per PF)
//     Zoom PF1               : byte 0x8000 → word 0x4000  (256 scanlines)
//     Zoom PF3               : byte 0x8200 → word 0x4100  (256 scanlines)
//     Zoom PF2               : byte 0x8400 → word 0x4200  (256 scanlines, PF4 Y-zoom here)
//     Zoom PF4               : byte 0x8600 → word 0x4300  (256 scanlines, PF2 Y-zoom here)
//     Pal-add PF1–PF4 base   : byte 0x9000 → word 0x4800  (stride 0x100 per PF)
//
// section1 §9.1 rowscroll enable:
//   word_addr = 0x0600 + scan,  bits[3:0] = enable per PF (PF1=bit0..PF4=bit3)
//
// section1 §9.1 colscroll/alt-tilemap enable:
//   word_addr = 0x0000 + scan,  bits[7:4] = alt-tmap enable per PF
//   bits[3:0] of same word also used for colscroll enable (§9.1 §9.2 interaction)
//   Note: colscroll enable shares the same enable word as alt-tilemap (bits[3:0])
//
// section1 §9.1 zoom enable:
//   word_addr = 0x0400 + scan,  bits[3:0] = enable per PF (PF1=bit0..PF4=bit3)
//
// section1 §9.1 pal-add enable:
//   word_addr = 0x0500 + scan,  bits[3:0] = enable per PF (PF1=bit0..PF4=bit3)
//
// section1 §9.1 priority enable (for playfield mix §9.12):
//   word_addr = 0x0700 + scan,  bits[3:0] = enable per PF (PF1=bit0..PF4=bit3)
//
// section1 §9.11 rowscroll data:
//   PFn (n=0..3): word_addr = 0x5000 + n*0x100 + scan
//
// section1 §9.2 colscroll data (bits[8:0] = colscroll offset; bit[9] = alt-tilemap flag):
//   PFn (n=0..3): word_addr = 0x2000 + n*0x100 + scan
//   colscroll enable: en_col_word[n] (bit[n] of 0x0000+scan)
//
// section1 §9.9 zoom data (format: bits[15:8]=Y_scale, bits[7:0]=X_scale):
//   PF1: word_addr = 0x4000 + scan
//   PF3: word_addr = 0x4100 + scan
//   PF2: word_addr = 0x4200 + scan  (NOTE: PF4 Y-zoom stored here in hardware)
//   PF4: word_addr = 0x4300 + scan  (NOTE: PF2 Y-zoom stored here in hardware)
//   PF2/PF4 Y-zoom swap: when outputting ls_zoom_y[1] (PF2), read from 0x4300+scan.
//                        when outputting ls_zoom_y[3] (PF4), read from 0x4200+scan.
//   X-zoom is NOT swapped: ls_zoom_x[1] from 0x4200+scan, ls_zoom_x[3] from 0x4300+scan.
//
// section1 §9.10 palette addition data:
//   PFn (n=0..3): word_addr = 0x4800 + n*0x100 + scan
//   Format: raw 16-bit value; the palette-line offset = value / 16 (i.e., divide by 16).
//   Output ls_pal_add[n] passes the raw 16-bit word; BG engine divides by 16.
//
// section1 §9.12 PF mix/priority data:
//   PFn (n=0..3): word_addr = 0x5800 + n*0x100 + scan
//   bits[3:0] = priority value (0–15)
//   Enable: bit[n] of word at 0x0700 + scan
//   Default (disabled): priority = 0.
//
// section1 §9.8 Sprite priority groups:
//   word_addr = 0x3B00 + scan
//   bits[15:12] = priority for group 0xC0
//   bits[11:8]  = priority for group 0x80
//   bits[7:4]   = priority for group 0x40
//   bits[3:0]   = priority for group 0x00
//   Enable: always active (no separate enable bit for sprite priority in §9.1).
// =============================================================================

module tc0630fdp_lineram (
    input  logic        clk,
    input  logic        rst_n,

    // ── CPU Interface ─────────────────────────────────────────────────────────
    input  logic        cpu_cs,         // chip-select (active high)
    input  logic        cpu_rw,         // 1=read, 0=write
    input  logic [15:1] cpu_addr,       // 15-bit word address within Line RAM
    input  logic [15:0] cpu_din,        // write data
    input  logic [ 1:0] cpu_be,         // byte enables [1]=upper, [0]=lower
    output logic [15:0] cpu_dout,       // read data

    // ── Video Timing ──────────────────────────────────────────────────────────
    input  logic [ 8:0] vpos,           // current scanline (0..261)
    input  logic        hblank_fall,    // single-cycle pulse at end of active scan

    // ── Per-scanline outputs (registered at hblank_fall, valid for vpos+1) ─────
    // rowscroll[n]: X-scroll addition for PF(n+1) on the next scanline.
    // Zero when rowscroll is disabled for that PF.
    output logic [3:0][15:0] ls_rowscroll,
    // alt_tilemap[n]: 1 → PF(n+1) reads tile data from +0x1800 offset in PF RAM.
    output logic [3:0]       ls_alt_tilemap,
    // zoom_x[n]: X zoom factor for PF(n+1).  0x00 = no zoom (1:1).
    // Zero (no zoom) when zoom is disabled for that PF.
    output logic [3:0][ 7:0] ls_zoom_x,
    // zoom_y[n]: Y zoom factor for PF(n+1).  0x80 = no zoom (1:1).
    // 0x80 (no zoom) when zoom is disabled for that PF.
    output logic [3:0][ 7:0] ls_zoom_y,
    // colscroll[n]: 9-bit column scroll offset for PF(n+1) (§9.2 bits[8:0]).
    // Zero when colscroll is disabled for that PF.
    output logic [3:0][ 8:0] ls_colscroll,
    // pal_add[n]: raw 16-bit palette addition word for PF(n+1) (§9.10).
    // Zero when pal_add is disabled.  BG engine divides by 16 to get palette-line offset.
    output logic [3:0][15:0] ls_pal_add,
    // pf_prio[n]: priority value 0–15 for PF(n+1) from §9.12 bits[3:0].
    // Zero (lowest) when priority enable is not asserted for this PF/scanline.
    output logic [3:0][ 3:0] ls_pf_prio,
    // spr_prio[n]: priority for sprite group n (0=0x00, 1=0x40, 2=0x80, 3=0xC0)
    // from §9.8.  Always latched (no separate enable bit).
    output logic [3:0][ 3:0] ls_spr_prio,

    // ── Step 12: Clip plane outputs ──────────────────────────────────────────
    // clip_left[p] / clip_right[p]: 8-bit left/right boundary for clip plane p (0–3).
    // Latched at hblank_fall from §9.3 data words.
    output logic [3:0][ 7:0] ls_clip_left,
    output logic [3:0][ 7:0] ls_clip_right,

    // PF clip configuration from §9.12 pp_word:
    //   ls_pf_clip_en[n]     = bits[11:8] — 4-bit enable mask (one bit per clip plane)
    //   ls_pf_clip_inv[n]    = bits[7:4]  — 4-bit invert mask (per clip plane)
    //   ls_pf_clip_sense[n]  = bit[12]    — inversion sense: 1=invert the invert
    output logic [3:0][ 3:0] ls_pf_clip_en,
    output logic [3:0][ 3:0] ls_pf_clip_inv,
    output logic [3:0]       ls_pf_clip_sense,

    // Sprite clip configuration from §9.7:
    //   ls_spr_clip_en    = bits[11:8] — 4-bit enable mask
    //   ls_spr_clip_inv   = bits[7:4]  — 4-bit invert mask
    //   ls_spr_clip_sense = bit[0]     — inversion sense
    output logic [ 3:0] ls_spr_clip_en,
    output logic [ 3:0] ls_spr_clip_inv,
    output logic        ls_spr_clip_sense,

    // ── Step 13: Alpha blend outputs ─────────────────────────────────────────
    // Alpha coefficients from §9.5 (latched per scanline):
    //   A_src: source contribution for normal blend mode A (0=transparent, 8=opaque)
    //   A_dst: destination contribution for normal blend mode A
    output logic [ 3:0] ls_a_src,
    output logic [ 3:0] ls_a_dst,
    // PF blend modes from §9.12 pp_word bits[15:14]:
    //   00=opaque  01=normal blend A  10=reverse blend B  11=opaque-layer
    output logic [3:0][ 1:0] ls_pf_blend,
    // Sprite blend modes from §9.4 bits[7:0] (2 bits per group):
    //   bits[7:6]=group0xC0, bits[5:4]=group0x80, bits[3:2]=group0x40, bits[1:0]=group0x00
    output logic [3:0][1:0]  ls_spr_blend,

    // ── Step 14: Reverse blend B coefficients ────────────────────────────────
    // B_src: source contribution for reverse blend mode B (0=transparent, 8=opaque)
    // B_dst: destination contribution for reverse blend mode B
    // From §9.5 ab_word bits[15:12]=B_src, bits[7:4]=B_dst
    output logic [ 3:0] ls_b_src,
    output logic [ 3:0] ls_b_dst,

    // ── Step 15: Mosaic effect outputs ───────────────────────────────────────
    // From §9.6 mosaic word at byte 0x6400–0x65FF → word 0x3200 + scan:
    //   bits[11:8] = mosaic_rate (0=1px/no effect, F=16px blocks)
    //   bits[3:0]  = PF mosaic enable (bit n = PF(n+1) enable)
    //   bit[8]     = sprite mosaic enable (same bit as rate LSB)
    // ls_mosaic_rate  : 4-bit sample rate (sample_rate = rate + 1)
    // ls_pf_mosaic_en : 4-bit PF enable (bit 0=PF1..bit 3=PF4)
    // ls_spr_mosaic_en: sprite layer mosaic enable
    output logic [ 3:0] ls_mosaic_rate,
    output logic [ 3:0] ls_pf_mosaic_en,
    output logic        ls_spr_mosaic_en,

    // ── Step 16: Pivot layer control outputs ─────────────────────────────────
    // From §9.4 sb_word upper byte (bits[15:8]):
    //   sb_word[13] = bit[5] of upper byte = ls_pivot_en   (1=layer enabled)
    //   sb_word[14] = bit[6] of upper byte = ls_pivot_bank (0=bank0, 1=bank1)
    //   sb_word[ 8] = bit[0] of upper byte = ls_pivot_blend (0=opaque, 1=blend A)
    output logic        ls_pivot_en,
    output logic        ls_pivot_bank,
    output logic        ls_pivot_blend
);

// =============================================================================
// Line RAM: 32768 × 16-bit words (64 KB BRAM)
// Under QUARTUS: explicit altsyncram instances (35 total) for M10K inference.
// Under simulation: behavioral array with CPU write/read always_ff blocks.
// =============================================================================
`ifndef QUARTUS
logic [15:0] line_ram [0:32767];

// CPU write port
always_ff @(posedge clk) begin
    if (cpu_cs && !cpu_rw) begin
        if (cpu_be[1]) line_ram[cpu_addr[15:1]][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) line_ram[cpu_addr[15:1]][ 7:0] <= cpu_din[ 7:0];
    end
end

// CPU read port (registered, one-cycle latency)
always_ff @(posedge clk) begin
    if (!rst_n)
        cpu_dout <= 16'b0;
    else if (cpu_cs && cpu_rw)
        cpu_dout <= line_ram[cpu_addr[15:1]];
end
`endif

// =============================================================================
// HBLANK parser
// =============================================================================
// Scanline index for the NEXT visible line (8-bit; sections have 256 entries).
// vpos is 9-bit (0–261); next_scan = (vpos+1)[7:0] wraps mod 256.
// vpos[8] is intentionally unused — sections only have 256 entries.
/* verilator lint_off UNUSEDSIGNAL */
logic [7:0] next_scan;
/* verilator lint_on UNUSEDSIGNAL */
assign next_scan = vpos[7:0] + 8'd1;

// Intermediate wires for enable and data words read from BRAM.
// These are registered combinationally from the BRAM array inside the
// always_ff block; the array reads are effectively asynchronous in simulation.
logic [15:0] en_row_word;    // rowscroll enable word
logic [15:0] en_col_word;    // colscroll/alt-tilemap enable word
/* verilator lint_off UNUSEDSIGNAL */
logic [15:0] en_zoom_word;   // zoom enable word (Step 6) — only bits[3:0] used
logic [15:0] en_pal_word;    // pal-add enable word (Step 7) — only bits[3:0] used
logic [15:0] en_prio_word;   // pf priority enable word (Step 11) — only bits[3:0] used
/* verilator lint_on UNUSEDSIGNAL */
logic [15:0] rs_word  [0:3]; // rowscroll data per PF
logic [15:0] cs_word  [0:3]; // colscroll data per PF (bits[8:0]=colscroll, bit[9]=alt-tilemap)
logic [15:0] zm_word  [0:3]; // zoom data per PF (bits[15:8]=Y, bits[7:0]=X)
logic [15:0] pa_word  [0:3]; // palette addition data per PF (§9.10)
logic [15:0] pp_word  [0:3]; // pf priority data per PF (§9.12, bits[3:0]=prio)
logic [15:0] sp_word;        // sprite group priority word (§9.8)

// Clip plane boundary data: §9.3
// Plane 0: byte 0x5000 → word 0x2800; plane 1: 0x2900; plane 2: 0x2A00; plane 3: 0x2B00
logic [15:0] cp_word [0:3];  // clip plane data words

// Sprite mix/clip: §9.7  byte 0x7400 → word 0x3A00
/* verilator lint_off UNUSEDSIGNAL */
logic [15:0] sm_word;  // sprite mix word (bits[15:12,3:1] unused in Step 12)
/* verilator lint_on UNUSEDSIGNAL */

// Step 13: Alpha blend coefficients §9.5  byte 0x6200 → word 0x3100
// bits[11:8]=A_src (normal blend), bits[3:0]=A_dst; bits[15:12]=B_src, bits[7:4]=B_dst (Step 14)
/* verilator lint_off UNUSEDSIGNAL */
logic [15:0] ab_word;  // alpha blend word: bits[11:8]=A_src, bits[3:0]=A_dst
/* verilator lint_on UNUSEDSIGNAL */

// Step 13/16: Pivot/sprite blend control §9.4  byte 0x6000 → word 0x3000
// bits[7:0]  = sprite blend mode per group (2 bits each)
// bits[15:8] = pivot/pixel control: bit[5]=enable, bit[6]=bank, bit[0]=blend_select
// bits[15,12:9] are reserved/unused in hardware
/* verilator lint_off UNUSEDSIGNAL */
logic [15:0] sb_word;  // pivot/sprite blend word
/* verilator lint_on UNUSEDSIGNAL */

// Step 15: Mosaic / X-sample §9.6  byte 0x6400 → word 0x3200
// bits[11:8]=mosaic_rate, bits[3:0]=PF mosaic enable, bit[8]=sprite enable
/* verilator lint_off UNUSEDSIGNAL */
logic [15:0] mo_word;  // mosaic word
/* verilator lint_on UNUSEDSIGNAL */

// PF2/PF4 Y-zoom cross-read wires (hardware swap, §9.9):
// PF2 Y-zoom is stored at PF4's RAM address (0x4300+scan).
// PF4 Y-zoom is stored at PF2's RAM address (0x4200+scan).
// Only the Y byte [15:8] is used from each swap wire; X byte [7:0] is unused.
/* verilator lint_off UNUSEDSIGNAL */
logic [15:0] zm_word_pf2_yswap;   // contains PF2 Y-zoom (from PF4's address)
logic [15:0] zm_word_pf4_yswap;   // contains PF4 Y-zoom (from PF2's address)
/* verilator lint_on UNUSEDSIGNAL */

`ifdef QUARTUS
// =============================================================================
// Quartus synthesis: Phase 6 consolidated altsyncram instances.
// 34 × 256×16-bit sections consolidated into 10 × 256×64-bit instances (4 slots
// each, byteena_a selects which 16-bit slot to write).  Plus 1 × 32768×16-bit
// instance for CPU reads.  Total: 11 instances (down from 35).
//
// Groups:
//   en_group  : slots [0x00, 0x04, 0x05, 0x06] → en_col_word, en_zoom_word, en_pal_word, en_row_word
//   aux_group : slots [0x07, 0x3A, 0x3B, --  ] → en_prio_word, sm_word, sp_word, unused
//   blend_grp : slots [0x30, 0x31, 0x32, --  ] → sb_word, ab_word, mo_word, unused
//   cs_group  : slots [0x20, 0x21, 0x22, 0x23] → cs_word[0..3]
//   cp_group  : slots [0x28, 0x29, 0x2A, 0x2B] → cp_word[0..3]
//   zm_group  : slots [0x40, 0x41, 0x42, 0x43] → zm_word[0..3]
//   pa_group  : slots [0x48, 0x49, 0x4A, 0x4B] → pa_word[0..3]
//   rs_group  : slots [0x50, 0x51, 0x52, 0x53] → rs_word[0..3]
//   pp_group  : slots [0x58, 0x59, 0x5A, 0x5B] → pp_word[0..3]
//   cpu_read  : 32768×16-bit for CPU readback
//
// Write enable: byteena_a[i] = 1 iff lram_section matches slot i's section code.
// Read: port B always reads all 64 bits; 16-bit word selected by constant slice.
// =============================================================================

// Shared write-path decode signals
logic        lram_we;
logic [1:0]  lram_be;
logic [7:0]  lram_row;
logic [6:0]  lram_section;
assign lram_we      = cpu_cs && !cpu_rw;
assign lram_be      = cpu_be;
assign lram_row     = cpu_addr[8:1];   // low 8 bits = row within 256-entry section
assign lram_section = cpu_addr[15:9];  // high 7 bits = section selector

// ── Macro: build 4-bit byteena from section match ────────────────────────────
// For a 256×64-bit instance with 4 × 16-bit slots, byteena_a[i] = 1 when
// the current write targets slot i (section code matches).
// lram_be[1:0] controls upper/lower byte within the 16-bit word for that slot.
// We model this as: enable slot i's two bytes when section matches AND lram_be.
// byteena_a is 8 bits (one per byte of 64-bit word); bits [2i+1:2i] = slot i.

// Helper function: compute 8-bit byteena for a 4-slot consolidated instance.
// s0..s3: section codes for slot 0..3.  Slot n occupies bytes [2n+1:2n].
function automatic logic [7:0] byteena4(
    input logic [6:0] section,
    input logic [1:0] be,
    input logic [6:0] s0, s1, s2, s3
);
    logic [7:0] r;
    r = 8'b0;
    if (section == s0) r[1:0] = be;
    if (section == s1) r[3:2] = be;
    if (section == s2) r[5:4] = be;
    if (section == s3) r[7:6] = be;
    return r;
endfunction

// Write data: replicate cpu_din into all 4 slots (only the enabled slot is written)
logic [63:0] lram_din64;
assign lram_din64 = {cpu_din, cpu_din, cpu_din, cpu_din};

// ── Raw 64-bit read outputs ───────────────────────────────────────────────────
logic [63:0] en_grp_q;   // en_col[15:0], en_zoom[31:16], en_pal[47:32], en_row[63:48]
logic [63:0] aux_grp_q;  // en_prio[15:0], sm[31:16], sp[47:32], unused[63:48]
logic [63:0] blend_grp_q; // sb[15:0], ab[31:16], mo[47:32], unused[63:48]
logic [63:0] cs_grp_q;   // cs[0][15:0], cs[1][31:16], cs[2][47:32], cs[3][63:48]
logic [63:0] cp_grp_q;   // cp[0][15:0], cp[1][31:16], cp[2][47:32], cp[3][63:48]
logic [63:0] zm_grp_q;   // zm[0][15:0], zm[1][31:16], zm[2][47:32], zm[3][63:48]
logic [63:0] pa_grp_q;   // pa[0][15:0], pa[1][31:16], pa[2][47:32], pa[3][63:48]
logic [63:0] rs_grp_q;   // rs[0][15:0], rs[1][31:16], rs[2][47:32], rs[3][63:48]
logic [63:0] pp_grp_q;   // pp[0][15:0], pp[1][31:16], pp[2][47:32], pp[3][63:48]

// Extract individual 16-bit words from 64-bit read data
assign en_col_word   = en_grp_q[15:0];
assign en_zoom_word  = en_grp_q[31:16];
assign en_pal_word   = en_grp_q[47:32];
assign en_row_word   = en_grp_q[63:48];

assign en_prio_word  = aux_grp_q[15:0];
assign sm_word       = aux_grp_q[31:16];
assign sp_word       = aux_grp_q[47:32];

assign sb_word       = blend_grp_q[15:0];
assign ab_word       = blend_grp_q[31:16];
assign mo_word       = blend_grp_q[47:32];

assign cs_word[0]    = cs_grp_q[15:0];
assign cs_word[1]    = cs_grp_q[31:16];
assign cs_word[2]    = cs_grp_q[47:32];
assign cs_word[3]    = cs_grp_q[63:48];

assign cp_word[0]    = cp_grp_q[15:0];
assign cp_word[1]    = cp_grp_q[31:16];
assign cp_word[2]    = cp_grp_q[47:32];
assign cp_word[3]    = cp_grp_q[63:48];

assign zm_word[0]    = zm_grp_q[15:0];
assign zm_word[1]    = zm_grp_q[31:16];
assign zm_word[2]    = zm_grp_q[47:32];
assign zm_word[3]    = zm_grp_q[63:48];

assign pa_word[0]    = pa_grp_q[15:0];
assign pa_word[1]    = pa_grp_q[31:16];
assign pa_word[2]    = pa_grp_q[47:32];
assign pa_word[3]    = pa_grp_q[63:48];

assign rs_word[0]    = rs_grp_q[15:0];
assign rs_word[1]    = rs_grp_q[31:16];
assign rs_word[2]    = rs_grp_q[47:32];
assign rs_word[3]    = rs_grp_q[63:48];

assign pp_word[0]    = pp_grp_q[15:0];
assign pp_word[1]    = pp_grp_q[31:16];
assign pp_word[2]    = pp_grp_q[47:32];
assign pp_word[3]    = pp_grp_q[63:48];

// PF2/PF4 Y-zoom cross-reads (hardware swap §9.9)
assign zm_word_pf2_yswap = zm_word[3];  // PF2 Y from PF4's address (zm_grp slot 3 = 0x43)
assign zm_word_pf4_yswap = zm_word[1];  // PF4 Y from PF2's address (zm_grp slot 1 = 0x41)

// ── Consolidated altsyncram instances ─────────────────────────────────────────
// Each instance: 256 words × 64 bits, dual-port, M10K.
// Port A (write): 64-bit data, 8-bit byteena (one per byte = 2 per 16-bit slot).
// Port B (read):  64-bit data, address = next_scan (registered output).
//
// NOTE: Quartus altsyncram with width=64 and width_byteena_a=8 maps to two M10K
// blocks (two 256×32b halves), giving 2 M10K per group.  9 groups = 18 M10K
// (vs 34 M10K before).  Net saving: 16 M10K blocks.

// en_group: slots [0x00, 0x04, 0x05, 0x06]
altsyncram #(
    .operation_mode             ("DUAL_PORT"),
    .width_a                    (64), .widthad_a(8), .numwords_a(256),
    .width_b                    (64), .widthad_b(8), .numwords_b(256),
    .outdata_reg_b              ("CLOCK1"), .address_reg_b("CLOCK1"),
    .clock_enable_input_a       ("BYPASS"), .clock_enable_input_b("BYPASS"),
    .clock_enable_output_b      ("BYPASS"),
    .intended_device_family     ("Cyclone V"),
    .lpm_type                   ("altsyncram"), .ram_block_type("M10K"),
    .width_byteena_a            (8), .power_up_uninitialized("FALSE"),
    .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ")
) en_grp_inst (
    .clock0(clk), .clock1(clk),
    .address_a(lram_row), .data_a(lram_din64),
    .wren_a(lram_we && (lram_section==7'h00 || lram_section==7'h04 ||
                        lram_section==7'h05 || lram_section==7'h06)),
    .byteena_a(byteena4(lram_section, lram_be, 7'h00, 7'h04, 7'h05, 7'h06)),
    .address_b(next_scan), .q_b(en_grp_q),
    .wren_b(1'b0), .data_b(64'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(8'hFF), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);

// aux_group: slots [0x07, 0x3A, 0x3B, --]
altsyncram #(
    .operation_mode             ("DUAL_PORT"),
    .width_a                    (64), .widthad_a(8), .numwords_a(256),
    .width_b                    (64), .widthad_b(8), .numwords_b(256),
    .outdata_reg_b              ("CLOCK1"), .address_reg_b("CLOCK1"),
    .clock_enable_input_a       ("BYPASS"), .clock_enable_input_b("BYPASS"),
    .clock_enable_output_b      ("BYPASS"),
    .intended_device_family     ("Cyclone V"),
    .lpm_type                   ("altsyncram"), .ram_block_type("M10K"),
    .width_byteena_a            (8), .power_up_uninitialized("FALSE"),
    .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ")
) aux_grp_inst (
    .clock0(clk), .clock1(clk),
    .address_a(lram_row), .data_a(lram_din64),
    .wren_a(lram_we && (lram_section==7'h07 || lram_section==7'h3A ||
                        lram_section==7'h3B)),
    .byteena_a(byteena4(lram_section, lram_be, 7'h07, 7'h3A, 7'h3B, 7'h7F)),
    .address_b(next_scan), .q_b(aux_grp_q),
    .wren_b(1'b0), .data_b(64'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(8'hFF), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);

// blend_group: slots [0x30, 0x31, 0x32, --]
altsyncram #(
    .operation_mode             ("DUAL_PORT"),
    .width_a                    (64), .widthad_a(8), .numwords_a(256),
    .width_b                    (64), .widthad_b(8), .numwords_b(256),
    .outdata_reg_b              ("CLOCK1"), .address_reg_b("CLOCK1"),
    .clock_enable_input_a       ("BYPASS"), .clock_enable_input_b("BYPASS"),
    .clock_enable_output_b      ("BYPASS"),
    .intended_device_family     ("Cyclone V"),
    .lpm_type                   ("altsyncram"), .ram_block_type("M10K"),
    .width_byteena_a            (8), .power_up_uninitialized("FALSE"),
    .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ")
) blend_grp_inst (
    .clock0(clk), .clock1(clk),
    .address_a(lram_row), .data_a(lram_din64),
    .wren_a(lram_we && (lram_section==7'h30 || lram_section==7'h31 ||
                        lram_section==7'h32)),
    .byteena_a(byteena4(lram_section, lram_be, 7'h30, 7'h31, 7'h32, 7'h7F)),
    .address_b(next_scan), .q_b(blend_grp_q),
    .wren_b(1'b0), .data_b(64'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(8'hFF), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);

// cs_group: slots [0x20, 0x21, 0x22, 0x23]
altsyncram #(
    .operation_mode             ("DUAL_PORT"),
    .width_a                    (64), .widthad_a(8), .numwords_a(256),
    .width_b                    (64), .widthad_b(8), .numwords_b(256),
    .outdata_reg_b              ("CLOCK1"), .address_reg_b("CLOCK1"),
    .clock_enable_input_a       ("BYPASS"), .clock_enable_input_b("BYPASS"),
    .clock_enable_output_b      ("BYPASS"),
    .intended_device_family     ("Cyclone V"),
    .lpm_type                   ("altsyncram"), .ram_block_type("M10K"),
    .width_byteena_a            (8), .power_up_uninitialized("FALSE"),
    .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ")
) cs_grp_inst (
    .clock0(clk), .clock1(clk),
    .address_a(lram_row), .data_a(lram_din64),
    .wren_a(lram_we && (lram_section==7'h20 || lram_section==7'h21 ||
                        lram_section==7'h22 || lram_section==7'h23)),
    .byteena_a(byteena4(lram_section, lram_be, 7'h20, 7'h21, 7'h22, 7'h23)),
    .address_b(next_scan), .q_b(cs_grp_q),
    .wren_b(1'b0), .data_b(64'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(8'hFF), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);

// cp_group: slots [0x28, 0x29, 0x2A, 0x2B]
altsyncram #(
    .operation_mode             ("DUAL_PORT"),
    .width_a                    (64), .widthad_a(8), .numwords_a(256),
    .width_b                    (64), .widthad_b(8), .numwords_b(256),
    .outdata_reg_b              ("CLOCK1"), .address_reg_b("CLOCK1"),
    .clock_enable_input_a       ("BYPASS"), .clock_enable_input_b("BYPASS"),
    .clock_enable_output_b      ("BYPASS"),
    .intended_device_family     ("Cyclone V"),
    .lpm_type                   ("altsyncram"), .ram_block_type("M10K"),
    .width_byteena_a            (8), .power_up_uninitialized("FALSE"),
    .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ")
) cp_grp_inst (
    .clock0(clk), .clock1(clk),
    .address_a(lram_row), .data_a(lram_din64),
    .wren_a(lram_we && (lram_section==7'h28 || lram_section==7'h29 ||
                        lram_section==7'h2A || lram_section==7'h2B)),
    .byteena_a(byteena4(lram_section, lram_be, 7'h28, 7'h29, 7'h2A, 7'h2B)),
    .address_b(next_scan), .q_b(cp_grp_q),
    .wren_b(1'b0), .data_b(64'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(8'hFF), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);

// zm_group: slots [0x40, 0x41, 0x42, 0x43]
altsyncram #(
    .operation_mode             ("DUAL_PORT"),
    .width_a                    (64), .widthad_a(8), .numwords_a(256),
    .width_b                    (64), .widthad_b(8), .numwords_b(256),
    .outdata_reg_b              ("CLOCK1"), .address_reg_b("CLOCK1"),
    .clock_enable_input_a       ("BYPASS"), .clock_enable_input_b("BYPASS"),
    .clock_enable_output_b      ("BYPASS"),
    .intended_device_family     ("Cyclone V"),
    .lpm_type                   ("altsyncram"), .ram_block_type("M10K"),
    .width_byteena_a            (8), .power_up_uninitialized("FALSE"),
    .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ")
) zm_grp_inst (
    .clock0(clk), .clock1(clk),
    .address_a(lram_row), .data_a(lram_din64),
    .wren_a(lram_we && (lram_section==7'h40 || lram_section==7'h41 ||
                        lram_section==7'h42 || lram_section==7'h43)),
    .byteena_a(byteena4(lram_section, lram_be, 7'h40, 7'h41, 7'h42, 7'h43)),
    .address_b(next_scan), .q_b(zm_grp_q),
    .wren_b(1'b0), .data_b(64'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(8'hFF), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);

// pa_group: slots [0x48, 0x49, 0x4A, 0x4B]
altsyncram #(
    .operation_mode             ("DUAL_PORT"),
    .width_a                    (64), .widthad_a(8), .numwords_a(256),
    .width_b                    (64), .widthad_b(8), .numwords_b(256),
    .outdata_reg_b              ("CLOCK1"), .address_reg_b("CLOCK1"),
    .clock_enable_input_a       ("BYPASS"), .clock_enable_input_b("BYPASS"),
    .clock_enable_output_b      ("BYPASS"),
    .intended_device_family     ("Cyclone V"),
    .lpm_type                   ("altsyncram"), .ram_block_type("M10K"),
    .width_byteena_a            (8), .power_up_uninitialized("FALSE"),
    .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ")
) pa_grp_inst (
    .clock0(clk), .clock1(clk),
    .address_a(lram_row), .data_a(lram_din64),
    .wren_a(lram_we && (lram_section==7'h48 || lram_section==7'h49 ||
                        lram_section==7'h4A || lram_section==7'h4B)),
    .byteena_a(byteena4(lram_section, lram_be, 7'h48, 7'h49, 7'h4A, 7'h4B)),
    .address_b(next_scan), .q_b(pa_grp_q),
    .wren_b(1'b0), .data_b(64'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(8'hFF), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);

// rs_group: slots [0x50, 0x51, 0x52, 0x53]
altsyncram #(
    .operation_mode             ("DUAL_PORT"),
    .width_a                    (64), .widthad_a(8), .numwords_a(256),
    .width_b                    (64), .widthad_b(8), .numwords_b(256),
    .outdata_reg_b              ("CLOCK1"), .address_reg_b("CLOCK1"),
    .clock_enable_input_a       ("BYPASS"), .clock_enable_input_b("BYPASS"),
    .clock_enable_output_b      ("BYPASS"),
    .intended_device_family     ("Cyclone V"),
    .lpm_type                   ("altsyncram"), .ram_block_type("M10K"),
    .width_byteena_a            (8), .power_up_uninitialized("FALSE"),
    .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ")
) rs_grp_inst (
    .clock0(clk), .clock1(clk),
    .address_a(lram_row), .data_a(lram_din64),
    .wren_a(lram_we && (lram_section==7'h50 || lram_section==7'h51 ||
                        lram_section==7'h52 || lram_section==7'h53)),
    .byteena_a(byteena4(lram_section, lram_be, 7'h50, 7'h51, 7'h52, 7'h53)),
    .address_b(next_scan), .q_b(rs_grp_q),
    .wren_b(1'b0), .data_b(64'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(8'hFF), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);

// pp_group: slots [0x58, 0x59, 0x5A, 0x5B]
altsyncram #(
    .operation_mode             ("DUAL_PORT"),
    .width_a                    (64), .widthad_a(8), .numwords_a(256),
    .width_b                    (64), .widthad_b(8), .numwords_b(256),
    .outdata_reg_b              ("CLOCK1"), .address_reg_b("CLOCK1"),
    .clock_enable_input_a       ("BYPASS"), .clock_enable_input_b("BYPASS"),
    .clock_enable_output_b      ("BYPASS"),
    .intended_device_family     ("Cyclone V"),
    .lpm_type                   ("altsyncram"), .ram_block_type("M10K"),
    .width_byteena_a            (8), .power_up_uninitialized("FALSE"),
    .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ")
) pp_grp_inst (
    .clock0(clk), .clock1(clk),
    .address_a(lram_row), .data_a(lram_din64),
    .wren_a(lram_we && (lram_section==7'h58 || lram_section==7'h59 ||
                        lram_section==7'h5A || lram_section==7'h5B)),
    .byteena_a(byteena4(lram_section, lram_be, 7'h58, 7'h59, 7'h5A, 7'h5B)),
    .address_b(next_scan), .q_b(pp_grp_q),
    .wren_b(1'b0), .data_b(64'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(8'hFF), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);

// Full 32768×16-bit instance for CPU reads
logic [15:0] cpu_dout_r;
altsyncram #(
    .operation_mode             ("DUAL_PORT"),
    .width_a                    (16), .widthad_a(15), .numwords_a(32768),
    .width_b                    (16), .widthad_b(15), .numwords_b(32768),
    .outdata_reg_b              ("CLOCK1"), .address_reg_b("CLOCK1"),
    .clock_enable_input_a       ("BYPASS"), .clock_enable_input_b("BYPASS"),
    .clock_enable_output_b      ("BYPASS"),
    .intended_device_family     ("Cyclone V"),
    .lpm_type                   ("altsyncram"), .ram_block_type("M10K"),
    .width_byteena_a            (2), .power_up_uninitialized("FALSE"),
    .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ")
) cpu_read_inst (
    .clock0(clk), .clock1(clk),
    .address_a(cpu_addr[15:1]), .data_a(cpu_din),
    .wren_a(lram_we), .byteena_a(lram_be),
    .address_b(cpu_addr[15:1]), .q_b(cpu_dout_r),
    .wren_b(1'b0), .data_b(16'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);
assign cpu_dout = cpu_dout_r;

`else
// =============================================================================
// Simulation: combinational (asynchronous) reads — instant access for verilator/
// iverilog.  Address arithmetic: 15-bit = base + {7'b0, next_scan}
// =============================================================================
assign en_row_word       = line_ram[15'h0600 + {7'b0, next_scan}];
assign en_col_word       = line_ram[15'h0000 + {7'b0, next_scan}];
assign en_zoom_word      = line_ram[15'h0400 + {7'b0, next_scan}];  // §9.1 zoom enable
assign en_pal_word       = line_ram[15'h0500 + {7'b0, next_scan}];  // §9.1 pal-add enable
assign en_prio_word      = line_ram[15'h0700 + {7'b0, next_scan}];  // §9.1 pf-prio enable
assign rs_word[0]        = line_ram[15'h5000 + {7'b0, next_scan}];
assign rs_word[1]        = line_ram[15'h5100 + {7'b0, next_scan}];
assign rs_word[2]        = line_ram[15'h5200 + {7'b0, next_scan}];
assign rs_word[3]        = line_ram[15'h5300 + {7'b0, next_scan}];
assign cs_word[0]        = line_ram[15'h2000 + {7'b0, next_scan}];
assign cs_word[1]        = line_ram[15'h2100 + {7'b0, next_scan}];
assign cs_word[2]        = line_ram[15'h2200 + {7'b0, next_scan}];
assign cs_word[3]        = line_ram[15'h2300 + {7'b0, next_scan}];
// Zoom data: PF1=0x4000, PF3=0x4100, PF2=0x4200, PF4=0x4300  (§9.9)
assign zm_word[0]        = line_ram[15'h4000 + {7'b0, next_scan}];  // PF1
assign zm_word[1]        = line_ram[15'h4200 + {7'b0, next_scan}];  // PF2 (X here; Y physically at PF4 addr)
assign zm_word[2]        = line_ram[15'h4100 + {7'b0, next_scan}];  // PF3
assign zm_word[3]        = line_ram[15'h4300 + {7'b0, next_scan}];  // PF4 (X here; Y physically at PF2 addr)
// Palette addition data: §9.10  PF1=0x4800, PF2=0x4900, PF3=0x4A00, PF4=0x4B00
assign pa_word[0]        = line_ram[15'h4800 + {7'b0, next_scan}];  // PF1
assign pa_word[1]        = line_ram[15'h4900 + {7'b0, next_scan}];  // PF2
assign pa_word[2]        = line_ram[15'h4A00 + {7'b0, next_scan}];  // PF3
assign pa_word[3]        = line_ram[15'h4B00 + {7'b0, next_scan}];  // PF4
// PF mix/priority data: §9.12  PF1=0x5800, PF2=0x5900, PF3=0x5A00, PF4=0x5B00
assign pp_word[0]        = line_ram[15'h5800 + {7'b0, next_scan}];  // PF1
assign pp_word[1]        = line_ram[15'h5900 + {7'b0, next_scan}];  // PF2
assign pp_word[2]        = line_ram[15'h5A00 + {7'b0, next_scan}];  // PF3
assign pp_word[3]        = line_ram[15'h5B00 + {7'b0, next_scan}];  // PF4
// Sprite group priority: §9.8  word_addr=0x3B00+scan
assign sp_word           = line_ram[15'h3B00 + {7'b0, next_scan}];
assign cp_word[0]        = line_ram[15'h2800 + {7'b0, next_scan}];
assign cp_word[1]        = line_ram[15'h2900 + {7'b0, next_scan}];
assign cp_word[2]        = line_ram[15'h2A00 + {7'b0, next_scan}];
assign cp_word[3]        = line_ram[15'h2B00 + {7'b0, next_scan}];
assign sm_word           = line_ram[15'h3A00 + {7'b0, next_scan}];
assign ab_word           = line_ram[15'h3100 + {7'b0, next_scan}];
assign sb_word           = line_ram[15'h3000 + {7'b0, next_scan}];
assign mo_word           = line_ram[15'h3200 + {7'b0, next_scan}];
assign zm_word_pf2_yswap = line_ram[15'h4300 + {7'b0, next_scan}];  // PF2 Y from PF4 addr
assign zm_word_pf4_yswap = line_ram[15'h4200 + {7'b0, next_scan}];  // PF4 Y from PF2 addr
`endif

// Register outputs at hblank_fall
always_ff @(posedge clk) begin
    if (!rst_n) begin
        // Explicit element assignments instead of for-loops — avoids Quartus 17
        // Error 10028 / OOM (293007) from constant-driver loops on packed 2D output ports.
        ls_rowscroll[0]    <= 16'b0; ls_rowscroll[1]    <= 16'b0;
        ls_rowscroll[2]    <= 16'b0; ls_rowscroll[3]    <= 16'b0;
        ls_alt_tilemap[0]  <= 1'b0;  ls_alt_tilemap[1]  <= 1'b0;
        ls_alt_tilemap[2]  <= 1'b0;  ls_alt_tilemap[3]  <= 1'b0;
        ls_zoom_x[0]       <= 8'h00; ls_zoom_x[1]       <= 8'h00;
        ls_zoom_x[2]       <= 8'h00; ls_zoom_x[3]       <= 8'h00;
        ls_zoom_y[0]       <= 8'h80; ls_zoom_y[1]       <= 8'h80;
        ls_zoom_y[2]       <= 8'h80; ls_zoom_y[3]       <= 8'h80;
        ls_colscroll[0]    <= 9'b0;  ls_colscroll[1]    <= 9'b0;
        ls_colscroll[2]    <= 9'b0;  ls_colscroll[3]    <= 9'b0;
        ls_pal_add[0]      <= 16'b0; ls_pal_add[1]      <= 16'b0;
        ls_pal_add[2]      <= 16'b0; ls_pal_add[3]      <= 16'b0;
        ls_pf_prio[0]      <= 4'b0;  ls_pf_prio[1]      <= 4'b0;
        ls_pf_prio[2]      <= 4'b0;  ls_pf_prio[3]      <= 4'b0;
        ls_pf_clip_en[0]   <= 4'b0;  ls_pf_clip_en[1]   <= 4'b0;
        ls_pf_clip_en[2]   <= 4'b0;  ls_pf_clip_en[3]   <= 4'b0;
        ls_pf_clip_inv[0]  <= 4'b0;  ls_pf_clip_inv[1]  <= 4'b0;
        ls_pf_clip_inv[2]  <= 4'b0;  ls_pf_clip_inv[3]  <= 4'b0;
        ls_pf_clip_sense[0]<= 1'b0;  ls_pf_clip_sense[1]<= 1'b0;
        ls_pf_clip_sense[2]<= 1'b0;  ls_pf_clip_sense[3]<= 1'b0;
        ls_spr_prio[0]     <= 4'b0;  ls_spr_prio[1]     <= 4'b0;
        ls_spr_prio[2]     <= 4'b0;  ls_spr_prio[3]     <= 4'b0;
        ls_clip_left[0]    <= 8'h00; ls_clip_left[1]    <= 8'h00;
        ls_clip_left[2]    <= 8'h00; ls_clip_left[3]    <= 8'h00;
        ls_clip_right[0]   <= 8'hFF; ls_clip_right[1]   <= 8'hFF;
        ls_clip_right[2]   <= 8'hFF; ls_clip_right[3]   <= 8'hFF;
        ls_spr_clip_en     <= 4'b0;
        ls_spr_clip_inv    <= 4'b0;
        ls_spr_clip_sense  <= 1'b0;
        // Step 13: alpha blend defaults
        ls_a_src           <= 4'd8;  // default: fully opaque source
        ls_a_dst           <= 4'd0;  // default: no destination contribution
        ls_pf_blend[0]     <= 2'b00; ls_pf_blend[1]     <= 2'b00;
        ls_pf_blend[2]     <= 2'b00; ls_pf_blend[3]     <= 2'b00;
        ls_spr_blend[0]    <= 2'b00; ls_spr_blend[1]    <= 2'b00;
        ls_spr_blend[2]    <= 2'b00; ls_spr_blend[3]    <= 2'b00;
        // Step 14: reverse blend B defaults
        ls_b_src           <= 4'd8;  // default: fully opaque source
        ls_b_dst           <= 4'd0;  // default: no destination contribution
        // Step 15: mosaic defaults (no mosaic)
        ls_mosaic_rate     <= 4'b0;
        ls_pf_mosaic_en    <= 4'b0;
        ls_spr_mosaic_en   <= 1'b0;
        // Step 16: pivot defaults (disabled)
        ls_pivot_en        <= 1'b0;
        ls_pivot_bank      <= 1'b0;
        ls_pivot_blend     <= 1'b0;
    end else if (hblank_fall) begin
        for (int n = 0; n < 4; n++) begin
            // Rowscroll: enable bit n of en_row_word[3:0]
            ls_rowscroll[n]   <= en_row_word[n] ? rs_word[n] : 16'b0;
            // Alt-tilemap: enable bit n of en_col_word[7:4], data bit[9] of cs_word
            ls_alt_tilemap[n] <= en_col_word[4+n] ? cs_word[n][9] : 1'b0;
            // Colscroll: enable bit n of en_col_word[3:0], data bits[8:0] of cs_word
            ls_colscroll[n]   <= en_col_word[n] ? cs_word[n][8:0] : 9'b0;
            // Palette addition: enable bit n of en_pal_word[3:0], full 16-bit raw value
            ls_pal_add[n]     <= en_pal_word[n] ? pa_word[n] : 16'b0;
            // PF priority: enable bit n of en_prio_word[3:0], data bits[3:0] of pp_word
            ls_pf_prio[n]     <= en_prio_word[n] ? pp_word[n][3:0] : 4'b0;
        end
        // Sprite group priority: always latched from §9.8 word (no separate enable)
        ls_spr_prio[0]  <= sp_word[3:0];    // group 0x00
        ls_spr_prio[1]  <= sp_word[7:4];    // group 0x40
        ls_spr_prio[2]  <= sp_word[11:8];   // group 0x80
        ls_spr_prio[3]  <= sp_word[15:12];  // group 0xC0
        // Zoom X and Y: enable bit n of en_zoom_word[3:0]
        // X-zoom: not swapped — read from each PF's own address
        // Y-zoom: PF2 and PF4 are physically swapped — use cross-read wires
        if (en_zoom_word[0]) begin
            ls_zoom_x[0] <= zm_word[0][7:0];    // PF1 X: from 0x4000+scan
            ls_zoom_y[0] <= zm_word[0][15:8];   // PF1 Y: from 0x4000+scan (no swap)
        end else begin
            ls_zoom_x[0] <= 8'h00;
            ls_zoom_y[0] <= 8'h80;
        end
        if (en_zoom_word[1]) begin
            ls_zoom_x[1] <= zm_word[1][7:0];           // PF2 X: from 0x4200+scan
            ls_zoom_y[1] <= zm_word_pf2_yswap[15:8];   // PF2 Y: from 0x4300+scan (swap)
        end else begin
            ls_zoom_x[1] <= 8'h00;
            ls_zoom_y[1] <= 8'h80;
        end
        if (en_zoom_word[2]) begin
            ls_zoom_x[2] <= zm_word[2][7:0];    // PF3 X: from 0x4100+scan
            ls_zoom_y[2] <= zm_word[2][15:8];   // PF3 Y: from 0x4100+scan (no swap)
        end else begin
            ls_zoom_x[2] <= 8'h00;
            ls_zoom_y[2] <= 8'h80;
        end
        if (en_zoom_word[3]) begin
            ls_zoom_x[3] <= zm_word[3][7:0];           // PF4 X: from 0x4300+scan
            ls_zoom_y[3] <= zm_word_pf4_yswap[15:8];   // PF4 Y: from 0x4200+scan (swap)
        end else begin
            ls_zoom_x[3] <= 8'h00;
            ls_zoom_y[3] <= 8'h80;
        end

        // ── Step 12: Clip plane boundaries (§9.3) ────────────────────────────
        // Each cp_word: bits[15:8]=right, bits[7:0]=left  (8-bit coordinates)
        for (int k = 0; k < 4; k++) begin
            ls_clip_left[k]  <= cp_word[k][7:0];
            ls_clip_right[k] <= cp_word[k][15:8];
        end

        // ── Step 12: PF clip config from §9.12 pp_word ────────────────────────
        // pp_word bits[11:8]=clip_enable, bits[7:4]=clip_invert, bit[12]=sense
        for (int n = 0; n < 4; n++) begin
            ls_pf_clip_en[n]    <= pp_word[n][11:8];
            ls_pf_clip_inv[n]   <= pp_word[n][7:4];
            ls_pf_clip_sense[n] <= pp_word[n][12];
        end

        // ── Step 12: Sprite clip config from §9.7 sm_word ─────────────────────
        // sm_word bits[11:8]=clip_enable, bits[7:4]=clip_invert, bit[0]=sense
        ls_spr_clip_en    <= sm_word[11:8];
        ls_spr_clip_inv   <= sm_word[7:4];
        ls_spr_clip_sense <= sm_word[0];

        // ── Step 13: Alpha blend coefficients from §9.5 ab_word ───────────────
        // ab_word bits[11:8]=A_src, bits[3:0]=A_dst
        ls_a_src <= ab_word[11:8];
        ls_a_dst <= ab_word[3:0];
        // ── Step 14: Reverse blend B coefficients from §9.5 ab_word ──────────
        // ab_word bits[15:12]=B_src, bits[7:4]=B_dst
        ls_b_src <= ab_word[15:12];
        ls_b_dst <= ab_word[7:4];

        // ── Step 13: PF blend modes from §9.12 pp_word bits[15:14] ───────────
        for (int n = 0; n < 4; n++) begin
            ls_pf_blend[n] <= pp_word[n][15:14];
        end

        // ── Step 13: Sprite blend modes from §9.4 sb_word bits[7:0] ──────────
        // bits[1:0]=group0x00, bits[3:2]=group0x40, bits[5:4]=group0x80, bits[7:6]=group0xC0
        ls_spr_blend[0] <= sb_word[1:0];   // group 0x00
        ls_spr_blend[1] <= sb_word[3:2];   // group 0x40
        ls_spr_blend[2] <= sb_word[5:4];   // group 0x80
        ls_spr_blend[3] <= sb_word[7:6];   // group 0xC0

        // ── Step 15: Mosaic from §9.6 mo_word ────────────────────────────────
        // mo_word bits[11:8]=mosaic_rate, bits[3:0]=PF enable, bit[8]=spr enable
        ls_mosaic_rate   <= mo_word[11:8];
        ls_pf_mosaic_en  <= mo_word[3:0];
        ls_spr_mosaic_en <= mo_word[8];

        // ── Step 16: Pivot layer control from §9.4 sb_word upper byte ─────────
        // sb_word[13]=bit5 of upper byte=enable, sb_word[14]=bit6=bank, sb_word[8]=bit0=blend
        ls_pivot_en    <= sb_word[13];
        ls_pivot_bank  <= sb_word[14];
        ls_pivot_blend <= sb_word[8];
    end
end

// Suppress vpos[8] unused: Line RAM sections have 256 entries, only vpos[7:0] needed.
/* verilator lint_off UNUSEDSIGNAL */
logic _unused_vpos;
assign _unused_vpos = vpos[8];
/* verilator lint_on UNUSEDSIGNAL */

endmodule
