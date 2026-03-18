// =============================================================================
// Kaneko16 Gate 4 — Verilator testbench
//
// Reads gate4_vectors.jsonl and drives the kaneko16 DUT through the BG
// tilemap renderer (Gate 4) path.
//
// Supported op codes:
//
//   reset              — pulse rst_n low then high
//   vsync_pulse        — pulse vsync_n low for 4 cycles, then high (shadow→active latch)
//   write_tilemap      — layer, row, col, data: write 16-bit VRAM word to tilemap
//   write_scroll       — layer, axis("x"/"y"), data: write scroll register
//   write_bg_rom       — addr, data: write one byte into testbench BG tile ROM
//   set_pixel          — layer, hpos, vpos: set inputs and clock 3 cycles
//                        (pipeline: 2 registered stages + settle)
//   check_bg_valid     — layer, exp: check bg_pix_valid[layer]
//   check_bg_color     — layer, exp: check bg_pix_color[layer]
//
// BG Tile ROM model:
//   1MB byte array in testbench.  bg_tile_rom_data is driven combinationally
//   (zero latency) after each clock edge: read byte at bg_tile_rom_addr.
//
// Pipeline timing:
//   Stage 0 (comb):  hpos/vpos/layer → scroll add → VRAM read → ROM addr (comb)
//   Stage 1 (posedge): latch ROM addr → bg_tile_rom_addr updates
//   Stage 2 (comb):  ROM data → nybble unpack
//   Output FF (posedge): write bg_pix_valid / bg_pix_color
//
//   So after set_pixel drives hpos/vpos/layer and we tick 2 clocks:
//     clock 1: Stage 1 fires → bg_tile_rom_addr latched, ROM data settles combinationally
//     clock 2: Output FF fires → bg_pix_valid/color updated
//   Then check.
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
#include <vector>

// BG tile ROM: 2MB byte-addressed
static constexpr int BG_ROM_SIZE = 1 << 21;

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

struct DUT {
    Vkaneko16*           top;
    uint64_t             cycle;
    int                  failures;
    int                  checks;

    // BG tile ROM (2 MB)
    std::vector<uint8_t> bg_rom;

    DUT() : cycle(0), failures(0), checks(0) {
        top = new Vkaneko16();
        bg_rom.assign(BG_ROM_SIZE, 0);
        reset_inputs();
        do_reset();
    }

    ~DUT() {
        top->final();
        delete top;
    }

    void reset_inputs() {
        top->rst_n         = 0;
        top->clk           = 0;
        top->cpu_cs_n      = 1;
        top->cpu_rd_n      = 1;
        top->cpu_wr_n      = 1;
        top->cpu_lds_n     = 0;
        top->cpu_uds_n     = 0;
        top->cpu_addr      = 0;
        top->cpu_din       = 0;
        top->vsync_n       = 1;
        top->hsync_n       = 1;
        top->scan_trigger  = 0;
        top->current_scanline = 0;
        top->spr_rom_data  = 0;
        top->spr_rd_addr   = 0;
        // Gate 4 inputs
        top->bg_layer_sel  = 0;
        top->bg_row_sel    = 0;
        top->bg_col_sel    = 0;
        top->bg_vram_din   = 0;
        top->bg_vram_wr    = 0;
        top->bg_hpos       = 0;
        top->bg_vpos       = 0;
        top->bg_layer_query = 0;
        top->bg_tile_rom_data = 0;
    }

    // Drive BG tile ROM combinationally
    void drive_bg_rom() {
        uint32_t a = top->bg_tile_rom_addr & (uint32_t)(BG_ROM_SIZE - 1);
        top->bg_tile_rom_data = bg_rom[a];
    }

    // Tick one clock; drive BG ROM before rising edge
    void clk_tick(int n = 1) {
        for (int i = 0; i < n; i++) {
            top->clk = 0;
            top->eval();
            drive_bg_rom();
            top->clk = 1;
            top->eval();
            ++cycle;
        }
    }

    void do_reset() {
        reset_inputs();
        clk_tick(4);
        top->rst_n = 1;
        clk_tick(4);
    }

    // ── VSync pulse (shadow → active latch) ──────────────────────────────────
    void vsync_pulse() {
        top->vsync_n = 0;
        clk_tick(4);
        top->vsync_n = 1;
        clk_tick(4);
    }

    // ── Write tilemap VRAM word ───────────────────────────────────────────────
    void write_tilemap(int layer, int row, int col, int data) {
        top->bg_layer_sel = (uint8_t)(layer & 3);
        top->bg_row_sel   = (uint8_t)(row   & 0x1F);
        top->bg_col_sel   = (uint8_t)(col   & 0x1F);
        top->bg_vram_din  = (uint16_t)(data & 0xFFFF);
        top->bg_vram_wr   = 1;
        clk_tick(1);
        top->bg_vram_wr   = 0;
        clk_tick(1);
    }

    // ── Write scroll register (uses CPU bus) ─────────────────────────────────
    // Scroll regs in kaneko16 are at 0x130000 + layer*0x100 + {0=X, 2=Y}
    void write_scroll(int layer, const std::string& axis, int data) {
        // Byte offset within 0x130000 region: layer*0x100 + (axis=="y" ? 2 : 0)
        uint32_t byte_off = (uint32_t)(layer * 0x100) + (axis == "y" ? 2u : 0u);
        uint32_t byte_addr = 0x130000 | byte_off;
        top->cpu_addr  = byte_addr & 0x1FFFFF;
        top->cpu_din   = (uint16_t)(data & 0xFFFF);
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

    // ── Set hpos/vpos/layer, tick 2 clocks to push through pipeline ──────────
    // Pipeline latency: 2 registered stages.
    //   clk1: Stage 1 FF fires → bg_tile_rom_addr updated; ROM driven comb.
    //   clk2: Output FF fires → bg_pix_valid/color updated.
    void set_pixel(int layer, int hpos, int vpos) {
        top->bg_layer_query = (uint8_t)(layer & 3);
        top->bg_hpos        = (uint16_t)(hpos & 0x1FF);
        top->bg_vpos        = (uint16_t)(vpos & 0x1FF);
        clk_tick(2);
    }

    // ── Check helper ──────────────────────────────────────────────────────────
    void check(const char* label, int got, int exp) {
        ++checks;
        if (got != exp) {
            fprintf(stderr, "FAIL  %s: got 0x%04X exp 0x%04X\n", label, got, exp);
            ++failures;
        } else {
            fprintf(stderr, "pass  %s: 0x%04X\n", label, got);
        }
    }

    int get_bg_valid(int layer) {
        return (int)((top->bg_pix_valid >> layer) & 1);
    }

    int get_bg_color(int layer) {
        return (int)(uint8_t)top->bg_pix_color[layer];
    }
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

    while (std::getline(f, line)) {
        ++line_num;
        if (line.empty() || line[0] == '#') continue;

        std::string op   = jstr(line, "op");
        int layer_val    = jint(line, "layer",  0);
        int exp_val      = jint(line, "exp",    0);

        if (op == "reset") {
            dut.do_reset();

        } else if (op == "vsync_pulse") {
            dut.vsync_pulse();

        } else if (op == "write_tilemap") {
            int row  = jint(line, "row",  0);
            int col  = jint(line, "col",  0);
            int data = jint(line, "data", 0);
            dut.write_tilemap(layer_val, row, col, data);

        } else if (op == "write_scroll") {
            std::string axis = jstr(line, "axis");
            int data = jint(line, "data", 0);
            dut.write_scroll(layer_val, axis, data);

        } else if (op == "write_bg_rom") {
            int addr = jint(line, "addr", 0);
            int data = jint(line, "data", 0);
            uint32_t a = (uint32_t)addr & (BG_ROM_SIZE - 1);
            dut.bg_rom[a] = (uint8_t)(data & 0xFF);

        } else if (op == "set_pixel") {
            int hpos = jint(line, "hpos", 0);
            int vpos = jint(line, "vpos", 0);
            dut.set_pixel(layer_val, hpos, vpos);

        } else if (op == "check_bg_valid") {
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "bg_valid[%d]", layer_val);
            dut.check(lbl, dut.get_bg_valid(layer_val), exp_val);

        } else if (op == "check_bg_color") {
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "bg_color[%d]", layer_val);
            dut.check(lbl, dut.get_bg_color(layer_val), exp_val);

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
        fprintf(stderr, "Usage: %s <gate4_vectors.jsonl> [...]\n", argv[0]);
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
