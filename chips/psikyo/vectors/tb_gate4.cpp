// =============================================================================
// Psikyo Gate 4 — Verilator testbench: BG Tilemap Renderer
//
// Reads gate4_vectors.jsonl and drives the psikyo_gate4 DUT.
//
// Supported ops:
//   reset          — pulse rst_n low then high
//   write_vram     — layer, cell, data: write VRAM entry (14-bit addr)
//   write_rom_byte — addr, data: write tile ROM byte
//   set_scroll     — layer, sx, sy: set integer scroll registers
//   set_pixel      — hpos, vpos, hblank, vblank: drive pixel position
//   clock_n        — n: advance n clock cycles
//   check_bg_valid — layer, exp: check bg_pix_valid[layer]
//   check_bg_color — layer, exp: check bg_pix_color[layer]
//   check_bg_prio  — layer, exp: check bg_pix_priority[layer]
//   comment        — text: section marker (printed to stderr)
//
// Tile ROM model:
//   The testbench holds a 1MB ROM array.
//   bg_rom_data is driven combinationally (zero latency): on each negedge,
//   we look up tile_rom[bg_rom_addr] and update bg_rom_data before the posedge
//   eval so the Stage-1 FF samples the correct data.
//
// VRAM encoding:
//   vram_wr_addr = {layer[0], cell[11:0]}  (14-bit)
//   vram_wr_data = tilemap entry word
//
// Exit: 0 = all pass, 1 = any failure.
// =============================================================================

#include "Vpsikyo_gate4.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdint.h>
#include <string>
#include <fstream>
#include <vector>

// ─── Timing constants ────────────────────────────────────────────────────────

static constexpr int TILE_ROM_SIZE = 1 << 20;  // 1 MB

// ─── Minimal JSON field extractors ───────────────────────────────────────────

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
    ++p;
    auto end = s.find('"', p);
    if (end == std::string::npos) return "";
    return s.substr(p, end - p);
}

// ─── DUT wrapper ─────────────────────────────────────────────────────────────

struct DUT {
    Vpsikyo_gate4*       top;
    uint64_t             cycle;
    int                  failures;
    int                  checks;

    // Tile ROM: 1MB, 4bpp packed
    std::vector<uint8_t> tile_rom;

    // Scroll registers mirrored in testbench to drive DUT inputs
    uint16_t scroll_x[2];
    uint16_t scroll_y[2];

    DUT() : cycle(0), failures(0), checks(0) {
        top = new Vpsikyo_gate4();
        tile_rom.assign(TILE_ROM_SIZE, 0);
        scroll_x[0] = scroll_x[1] = 0;
        scroll_y[0] = scroll_y[1] = 0;
        reset_inputs();
        do_reset();
    }

    ~DUT() {
        top->final();
        delete top;
    }

    void reset_inputs() {
        top->rst_n       = 0;
        top->clk         = 0;
        top->hpos        = 0;
        top->vpos        = 0;
        top->hblank      = 0;
        top->vblank      = 0;
        top->scroll_x[0] = 0;
        top->scroll_x[1] = 0;
        top->scroll_y[0] = 0;
        top->scroll_y[1] = 0;
        top->vram_wr_addr = 0;
        top->vram_wr_data = 0;
        top->vram_wr_en   = 0;
        top->bg_rom_data  = 0;
    }

    // Tick one clock, driving tile ROM combinationally.
    // negedge: eval combinational paths, update bg_rom_data from ROM array.
    // posedge: eval — FFs sample the updated ROM data.
    void clk_tick(int n = 1) {
        for (int i = 0; i < n; i++) {
            top->clk = 0;
            top->eval();
            // Drive ROM data from address (zero latency)
            uint32_t rom_addr = top->bg_rom_addr & (TILE_ROM_SIZE - 1);
            top->bg_rom_data  = tile_rom[rom_addr];
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

    // Write VRAM: addr = {layer[0], cell[11:0]}  (13-bit, fits in 14-bit input port)
    void write_vram(int layer, int cell, int data) {
        int addr = ((layer & 1) << 12) | (cell & 0xFFF);
        top->vram_wr_addr = (uint32_t)(addr & 0x1FFF);  // 13-bit address
        top->vram_wr_data = (uint16_t)(data & 0xFFFF);
        top->vram_wr_en   = 1;
        clk_tick(1);
        top->vram_wr_en   = 0;
        clk_tick(1);
    }

    // Update scroll registers (drives DUT inputs directly)
    void set_scroll(int layer, int sx, int sy) {
        // Scroll register: [15:8] = integer part, [7:0] = 0
        scroll_x[layer & 1] = (uint16_t)((sx & 0xFF) << 8);
        scroll_y[layer & 1] = (uint16_t)((sy & 0xFF) << 8);
        top->scroll_x[0] = scroll_x[0];
        top->scroll_x[1] = scroll_x[1];
        top->scroll_y[0] = scroll_y[0];
        top->scroll_y[1] = scroll_y[1];
        top->eval();
    }

    // Check helper
    void check(const char* label, int got, int exp) {
        ++checks;
        if (got != exp) {
            fprintf(stderr, "FAIL  %s: got 0x%04X exp 0x%04X\n", label, got, exp);
            ++failures;
        } else {
            fprintf(stderr, "pass  %s: 0x%04X\n", label, got);
        }
    }

    int get_bg_valid(int layer)  { return (int)((top->bg_pix_valid >> layer) & 1); }
    int get_bg_color(int layer)  { return (int)(uint8_t)top->bg_pix_color[layer]; }
    int get_bg_prio(int layer)   { return (int)top->bg_pix_priority[layer]; }
};

// ─── Process one vector file ──────────────────────────────────────────────────

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

        std::string op = jstr(line, "op");

        if (op == "reset") {
            dut.do_reset();

        } else if (op == "write_vram") {
            int layer = jint(line, "layer", 0);
            int cell  = jint(line, "cell",  0);
            int data  = jint(line, "data",  0);
            dut.write_vram(layer, cell, data);

        } else if (op == "write_rom_byte") {
            int addr = jint(line, "addr", 0);
            int data = jint(line, "data", 0);
            uint32_t a = (uint32_t)addr & (TILE_ROM_SIZE - 1);
            dut.tile_rom[a] = (uint8_t)(data & 0xFF);

        } else if (op == "set_scroll") {
            int layer = jint(line, "layer", 0);
            int sx    = jint(line, "sx",    0);
            int sy    = jint(line, "sy",    0);
            dut.set_scroll(layer, sx, sy);

        } else if (op == "set_pixel") {
            int hpos_v   = jint(line, "hpos",   0);
            int vpos_v   = jint(line, "vpos",   0);
            int hblank_v = jint(line, "hblank", 0);
            int vblank_v = jint(line, "vblank", 0);
            dut.top->hpos   = (uint16_t)(hpos_v & 0x3FF);
            dut.top->vpos   = (uint16_t)(vpos_v & 0x1FF);
            dut.top->hblank = (uint8_t)(hblank_v & 1);
            dut.top->vblank = (uint8_t)(vblank_v & 1);
            dut.top->eval();

        } else if (op == "clock_n") {
            int n = jint(line, "n", 1);
            dut.clk_tick(n);

        } else if (op == "check_bg_valid") {
            int layer = jint(line, "layer", 0);
            int exp   = jint(line, "exp",   0);
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "bg_pix_valid[%d]", layer);
            dut.check(lbl, dut.get_bg_valid(layer), exp);

        } else if (op == "check_bg_color") {
            int layer = jint(line, "layer", 0);
            int exp   = jint(line, "exp",   0);
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "bg_pix_color[%d]", layer);
            dut.check(lbl, dut.get_bg_color(layer), exp);

        } else if (op == "check_bg_prio") {
            int layer = jint(line, "layer", 0);
            int exp   = jint(line, "exp",   0);
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "bg_pix_priority[%d]", layer);
            dut.check(lbl, dut.get_bg_prio(layer), exp);

        } else if (op == "comment") {
            std::string text = jstr(line, "text");
            fprintf(stderr, "\n--- %s ---\n", text.c_str());

        } else {
            fprintf(stderr, "WARNING: unknown op '%s' at line %d\n",
                    op.c_str(), line_num);
        }
    }

    return 0;
}

// ─── main ─────────────────────────────────────────────────────────────────────

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
