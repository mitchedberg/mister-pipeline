// =============================================================================
// Kaneko16 Gate 5 — Verilator testbench
//
// Reads gate5_vectors.jsonl and exercises the priority mixer (Gate 5).
//
// Gate 5 is purely combinational: it reads
//   spr_rd_valid / spr_rd_color / spr_rd_priority   (Gate 3 read-back)
//   bg_pix_valid / bg_pix_color[*]                  (Gate 4 outputs, per layer)
//   layer_ctrl                                       (active register from Gate 1)
// and produces:
//   final_valid, final_color
//
// Injection strategy:
//   For SPRITE pixels: program sprite RAM + sprite ROM, vblank_scan + scan_line(0),
//     then set spr_rd_addr=0 to read pixel at X=0.  Sprite prio is stored alongside
//     color/valid in spr_pix_priority[].
//
//   For BG pixels: write tile ROM bytes + VRAM word, write scroll=0 via CPU bus,
//     then issue a vsync_pulse (to latch scroll shadow→active) and clock 2 cycles
//     (Gate 4 pipeline latency) for each layer.
//
//   ORDER: Always prime sprite FIRST (long operation: 512+ cycles), then prime all
//     4 BG layers (short: ~20 cycles each).  This ensures BG state is fresh when
//     Gate 5 is evaluated.
//
// Supported op codes:
//
//   reset                              — pulse rst_n low then high
//   set_spr   color, valid, prio       — record desired sprite pixel
//   set_bg    layer, color, valid      — record desired BG layer pixel
//   set_layer_ctrl  data               — record layer_ctrl value
//   check_final  exp_valid, exp_color  — prime DUT, settle, verify final_valid/color
//
// Exit: 0 = all pass, 1 = any failure.
// =============================================================================

#include "Vkaneko16.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdint.h>
#include <string>
#include <fstream>

// ---------------------------------------------------------------------------
// Minimal JSON field extractors
// ---------------------------------------------------------------------------

static size_t jfind(const std::string& s, const std::string& key) {
    std::string pat = "\"" + key + "\"";
    auto p = s.find(pat);
    if (p == std::string::npos) return std::string::npos;
    p += pat.size();
    while (p < s.size() && (s[p] == ' ' || s[p] == ':')) ++p;
    return p;
}

static int jint(const std::string& s, const std::string& key, int dflt = -1) {
    auto p = jfind(s, key);
    if (p == std::string::npos) return dflt;
    return (int)strtol(s.c_str() + p, nullptr, 0);
}

static std::string jstr(const std::string& s, const std::string& key) {
    auto p = jfind(s, key);
    if (p == std::string::npos || s[p] != '"') return "";
    p++;
    auto end = s.find('"', p);
    if (end == std::string::npos) return "";
    return s.substr(p, end - p);
}

// ---------------------------------------------------------------------------
// DUT wrapper
// ---------------------------------------------------------------------------

static constexpr int SPR_ROM_SIZE = 1 << 20;  // 1 MB sprite ROM
static constexpr int BG_ROM_SIZE  = 1 << 21;  // 2 MB BG tile ROM

struct DUT {
    Vkaneko16*   top;
    uint64_t     cycle;
    int          failures;
    int          checks;

    uint8_t spr_rom[SPR_ROM_SIZE];
    uint8_t bg_rom[BG_ROM_SIZE];

    DUT() : cycle(0), failures(0), checks(0) {
        top = new Vkaneko16();
        memset(spr_rom, 0, sizeof(spr_rom));
        memset(bg_rom,  0, sizeof(bg_rom));
        reset_inputs();
        do_reset();
    }

    ~DUT() {
        top->final();
        delete top;
    }

    void reset_inputs() {
        top->rst_n            = 0;
        top->clk              = 0;
        top->cpu_cs_n         = 1;
        top->cpu_rd_n         = 1;
        top->cpu_wr_n         = 1;
        top->cpu_lds_n        = 0;
        top->cpu_uds_n        = 0;
        top->cpu_addr         = 0;
        top->cpu_din          = 0;
        top->vsync_n          = 1;
        top->hsync_n          = 1;
        top->scan_trigger     = 0;
        top->current_scanline = 0;
        top->spr_rom_data     = 0;
        top->spr_rd_addr      = 0;
        top->bg_layer_sel     = 0;
        top->bg_row_sel       = 0;
        top->bg_col_sel       = 0;
        top->bg_vram_din      = 0;
        top->bg_vram_wr       = 0;
        top->bg_hpos          = 0;
        top->bg_vpos          = 0;
        top->bg_layer_query   = 0;
        top->bg_tile_rom_data = 0;
        top->layer_ctrl       = 0;
    }

    // ── Clock with ROM drives ─────────────────────────────────────────────────
    void clk_tick(int n = 1) {
        for (int i = 0; i < n; i++) {
            top->clk = 0;
            top->eval();
            // Drive sprite ROM (32-bit wide)
            uint32_t sa = top->spr_rom_addr & (SPR_ROM_SIZE - 1);
            top->spr_rom_data = (uint32_t)spr_rom[sa]
                              | ((uint32_t)spr_rom[(sa+1) & (SPR_ROM_SIZE-1)] << 8)
                              | ((uint32_t)spr_rom[(sa+2) & (SPR_ROM_SIZE-1)] << 16)
                              | ((uint32_t)spr_rom[(sa+3) & (SPR_ROM_SIZE-1)] << 24);
            // Drive BG tile ROM (8-bit wide)
            uint32_t ba = top->bg_tile_rom_addr & (BG_ROM_SIZE - 1);
            top->bg_tile_rom_data = bg_rom[ba];
            top->clk = 1;
            top->eval();
            ++cycle;
        }
    }

    void settle() {
        top->clk = 0;
        uint32_t sa = top->spr_rom_addr & (SPR_ROM_SIZE - 1);
        top->spr_rom_data = (uint32_t)spr_rom[sa]
                          | ((uint32_t)spr_rom[(sa+1) & (SPR_ROM_SIZE-1)] << 8)
                          | ((uint32_t)spr_rom[(sa+2) & (SPR_ROM_SIZE-1)] << 16)
                          | ((uint32_t)spr_rom[(sa+3) & (SPR_ROM_SIZE-1)] << 24);
        uint32_t ba = top->bg_tile_rom_addr & (BG_ROM_SIZE - 1);
        top->bg_tile_rom_data = bg_rom[ba];
        top->eval();
    }

    void do_reset() {
        reset_inputs();
        clk_tick(4);
        top->rst_n = 1;
        clk_tick(4);
    }

    // ── CPU register write ────────────────────────────────────────────────────
    void cpu_write(uint32_t byte_addr, uint16_t data) {
        top->cpu_addr  = byte_addr & 0x1FFFFF;
        top->cpu_din   = data;
        top->cpu_cs_n  = 0;
        top->cpu_wr_n  = 0;
        top->cpu_rd_n  = 1;
        top->cpu_lds_n = 0;
        top->cpu_uds_n = 0;
        clk_tick(1);
        top->cpu_cs_n  = 1;
        top->cpu_wr_n  = 1;
        clk_tick(1);
    }

    // ── VSync pulse (shadow→active latch, also triggers Gate 2 scan) ─────────
    void vsync_pulse() {
        top->vsync_n = 0;
        for (int i = 0; i < 512; i++) {
            clk_tick(1);
            if (top->display_list_ready) break;
        }
        top->vsync_n = 1;
        clk_tick(4);
    }

    // ── Gate 3 scanline render ────────────────────────────────────────────────
    void scan_line(int scanline) {
        top->current_scanline = (uint16_t)(scanline & 0x1FF);
        top->scan_trigger = 1;
        clk_tick(1);
        top->scan_trigger = 0;
        bool render_done = false;
        for (int i = 0; i < 4096; i++) {
            clk_tick(1);
            if (top->spr_render_done) {
                render_done = true;
                break;
            }
        }
        if (!render_done) {
            fprintf(stderr, "TIMEOUT: scan_line(%d) — spr_render_done not seen!\n", scanline);
        }
        clk_tick(2);
    }

    // ── Write tilemap VRAM word ───────────────────────────────────────────────
    void write_tilemap(int layer, int row, int col, uint16_t data) {
        top->bg_layer_sel = (uint8_t)(layer & 3);
        top->bg_row_sel   = (uint8_t)(row   & 0x1F);
        top->bg_col_sel   = (uint8_t)(col   & 0x1F);
        top->bg_vram_din  = data;
        top->bg_vram_wr   = 1;
        clk_tick(1);
        top->bg_vram_wr   = 0;
        clk_tick(1);
    }

    // ── Inject sprite pixel into scanline buffer at X=0 ──────────────────────
    // color_byte = {palette[3:0], nybble[3:0]}
    // valid: 0 = transparent (Y=0x1FF sentinel), 1 = opaque
    // prio: 4-bit sprite priority (0..15)
    //
    // Sprite RAM word layout (word_index = slot*8 + offset):
    //   word 0: Y[8:0]          — 0x1FF = inactive sentinel
    //   word 1: tile_num[15:0]
    //   word 2: X[8:0]
    //   word 3: palette[3:0] | flip_x[4] | flip_y[5] | priority[9:6] | size[13:10]
    //   words 4-7: reserved (0)
    //
    // cpu_addr[12:0] is the WORD INDEX into sprite_ram_mem[].
    // cpu_write(0x120000 + word_idx, data) writes sprite_ram_mem[word_idx].
    // Use consecutive word offsets (+1 per word), NOT byte offsets (+2 per word).
    void prime_sprite(int color_byte, int valid, int prio) {
        // Reset DUT to ensure the Gate 2 scanner is idle (in SPRITE_IDLE state).
        // Without this, a vsync pulse from a previous prime_bg call may have left
        // the scanner mid-scan, so the new vsync_pulse below would not restart it
        // (SPRITE_SCAN ignores vblank_rising), and the scan would complete using
        // stale sprite RAM data written by a previous prime_sprite call.
        do_reset();

        if (valid) {
            int palette = (color_byte >> 4) & 0xF;
            int nybble  =  color_byte       & 0xF;
            if (nybble == 0) nybble = 1;  // ensure opaque

            // Write sprite ROM tile 0, all bytes = (nybble<<4)|nybble
            uint8_t byte_val = (uint8_t)(((nybble & 0xF) << 4) | (nybble & 0xF));
            for (int b = 0; b < 128; b++) spr_rom[b] = byte_val;

            // Sprite RAM slot 0: word indices 0..7
            //   word 3: size[13:10]=0, prio[9:6], flip_y[5]=0, flip_x[4]=0, palette[3:0]
            uint16_t w3 = (uint16_t)((palette & 0xF) | ((prio & 0xF) << 6));
            cpu_write(0x120000 + 0, 0x0000);  // word 0: Y=0 (intersects scanline 0)
            cpu_write(0x120000 + 1, 0x0000);  // word 1: tile=0
            cpu_write(0x120000 + 2, 0x0000);  // word 2: X=0
            cpu_write(0x120000 + 3, w3);      // word 3: attribs
            cpu_write(0x120000 + 4, 0x0000);  // word 4: reserved
            cpu_write(0x120000 + 5, 0x0000);  // word 5: reserved
            cpu_write(0x120000 + 6, 0x0000);  // word 6: reserved
            cpu_write(0x120000 + 7, 0x0000);  // word 7: reserved
        } else {
            // Transparent: Y = 0x01FF (sentinel → scanner skips this slot)
            cpu_write(0x120000 + 0, 0x01FF);  // word 0: Y = sentinel
            cpu_write(0x120000 + 1, 0x0000);  // word 1
            cpu_write(0x120000 + 2, 0x0000);  // word 2
            cpu_write(0x120000 + 3, 0x0000);  // word 3
            cpu_write(0x120000 + 4, 0x0000);  // word 4
            cpu_write(0x120000 + 5, 0x0000);  // word 5
            cpu_write(0x120000 + 6, 0x0000);  // word 6
            cpu_write(0x120000 + 7, 0x0000);  // word 7
        }

        // Build display list + render scanline 0
        vsync_pulse();
        scan_line(0);

        // Point read-back at X=0
        top->spr_rd_addr = 0;
        settle();
    }

    // ── Inject BG pixel for one layer at position (0,0) ──────────────────────
    // color_byte = {palette[3:0], nybble[3:0]}; nybble=0 → transparent.
    // If valid=1 but nybble=0, force nybble=1 to ensure the pixel is opaque
    // (hardware transparency is driven by nybble==0, not a separate valid flag).
    // Does NOT re-trigger vsync or sprite scanner.
    void prime_bg(int layer, int color_byte, int valid) {
        int palette = (color_byte >> 4) & 0xF;
        int nybble  =  color_byte       & 0xF;
        if (!valid) nybble = 0;  // transparent

        // Use tile_num = layer+1 (1..4) to avoid collision between layers
        int tile_num = layer + 1;
        int base = tile_num * 128;
        uint8_t bval = (uint8_t)(((nybble & 0xF) << 4) | (nybble & 0xF));
        for (int b = 0; b < 128; b++) bg_rom[base + b] = bval;

        // VRAM word: [15:8]=tile_num, [7:4]=palette, [3:2]=0
        uint16_t vram_w = (uint16_t)(((tile_num & 0xFF) << 8) | ((palette & 0xF) << 4));
        write_tilemap(layer, 0, 0, vram_w);

        // Write scroll=0 for this layer (shadow register only)
        uint32_t sx_addr = 0x130000 + layer * 0x100;        // scroll_x offset
        uint32_t sy_addr = 0x130000 + layer * 0x100 + 2;    // scroll_y offset
        cpu_write(sx_addr, 0);
        cpu_write(sy_addr, 0);

        // Pulse vsync to latch shadow→active scroll registers.
        // This also triggers Gate 2 sprite scanner — but the sprite RAM already
        // has the correct state (was primed by prime_sprite before prime_bg calls).
        top->vsync_n = 0;
        clk_tick(4);
        top->vsync_n = 1;
        clk_tick(4);

        // Clock Gate 4 pipeline: 2 cycles for hpos=0, vpos=0, layer_query=layer
        top->bg_layer_query = (uint8_t)(layer & 3);
        top->bg_hpos        = 0;
        top->bg_vpos        = 0;
        clk_tick(2);
    }

    // ── Check helper ──────────────────────────────────────────────────────────
    void check(const char* label, int got, int exp) {
        ++checks;
        if (got != exp) {
            fprintf(stderr, "FAIL  %s: got 0x%02X exp 0x%02X\n", label, got, exp);
            ++failures;
        } else {
            fprintf(stderr, "pass  %s: 0x%02X\n", label, got);
        }
    }

    int get_final_color() { return (int)(uint8_t)top->final_color; }
    int get_final_valid() { return (int)(top->final_valid & 1); }
};

// ---------------------------------------------------------------------------
// Pending state for a check_final operation
// ---------------------------------------------------------------------------

struct PendingState {
    int spr_color   = 0;
    int spr_valid   = 0;
    int spr_prio    = 0;
    int bg_color[4] = {};
    int bg_valid[4] = {};
    int layer_ctrl  = 0;
    bool dirty      = false;
};

// ---------------------------------------------------------------------------
// Process one vector file
// ---------------------------------------------------------------------------

static int run_vectors(DUT& dut, const char* path) {
    std::ifstream f(path);
    if (!f.is_open()) {
        fprintf(stderr, "ERROR: cannot open %s\n", path);
        return 1;
    }

    fprintf(stderr, "\n=== %s ===\n", path);
    std::string line;
    int line_num = 0;
    int scenario = 0;

    PendingState st;

    while (std::getline(f, line)) {
        ++line_num;
        if (line.empty() || line[0] == '#') continue;

        std::string op = jstr(line, "op");

        if (op == "reset") {
            dut.do_reset();
            ++scenario;
            st = PendingState{};
            fprintf(stderr, "-- scenario %d --\n", scenario);

        } else if (op == "set_spr") {
            st.spr_color = jint(line, "color", 0);
            st.spr_valid = jint(line, "valid", 0);
            st.spr_prio  = jint(line, "prio",  0);
            st.dirty = true;

        } else if (op == "set_bg") {
            int layer = jint(line, "layer", 0);
            if (layer < 0 || layer > 3) {
                fprintf(stderr, "WARNING: set_bg invalid layer %d at line %d\n",
                        layer, line_num);
                continue;
            }
            st.bg_color[layer] = jint(line, "color", 0);
            st.bg_valid[layer] = jint(line, "valid", 0);
            st.dirty = true;

        } else if (op == "set_layer_ctrl") {
            st.layer_ctrl = jint(line, "data", 0);
            st.dirty = true;

        } else if (op == "check_final") {
            int exp_valid = jint(line, "exp_valid", 0);
            int exp_color = jint(line, "exp_color", 0);

            if (st.dirty) {
                // ── Injection order: sprite FIRST (long), BG layers LAST (short) ──
                // This ensures BG output FFs hold fresh values right before the check.

                // 1. Inject sprite pixel (runs vblank_scan + scan_line: 500+ cycles)
                dut.prime_sprite(st.spr_color, st.spr_valid, st.spr_prio);

                // 2. Inject each BG layer (~20 cycles per layer, sprite state preserved)
                for (int L = 0; L < 4; L++) {
                    dut.prime_bg(L, st.bg_color[L], st.bg_valid[L]);
                }

                // 3. Set layer_ctrl and spr_rd_addr, then settle
                dut.top->layer_ctrl  = (uint16_t)(st.layer_ctrl & 0xFFFF);
                dut.top->spr_rd_addr = 0;
                dut.settle();

                st.dirty = false;
            }

            dut.check("final_valid", dut.get_final_valid(), exp_valid);
            if (exp_valid) {
                dut.check("final_color", dut.get_final_color(), exp_color);
            }

        } else {
            fprintf(stderr, "WARNING: unknown op '%s' at line %d\n",
                    op.c_str(), line_num);
        }
    }

    return 0;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    if (argc < 2) {
        fprintf(stderr, "Usage: %s <gate5_vectors.jsonl> [...]\n", argv[0]);
        return 1;
    }

    DUT dut;
    int err = 0;

    for (int i = 1; i < argc; i++) {
        err |= run_vectors(dut, argv[i]);
    }

    fprintf(stderr, "\n=== Results: %d checks, %d failures ===\n",
            dut.checks, dut.failures);

    printf("Passed: %d\n", dut.checks - dut.failures);
    printf("Failed: %d\n", dut.failures);
    printf("Total: %d/%d\n", dut.checks - dut.failures, dut.checks);

    if (dut.failures > 0 || err) {
        fprintf(stderr, "FAIL\n");
        return 1;
    }
    fprintf(stderr, "PASS\n");
    return 0;
}
