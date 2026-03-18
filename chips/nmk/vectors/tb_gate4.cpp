// =============================================================================
// NMK16 Gate 4 — Verilator testbench
//
// Reads gate4_vectors.jsonl and drives the nmk16 DUT through the BG tilemap
// renderer (Gate 4) path.
//
// Supported op codes:
//
//   reset           — pulse rst_n low then high
//   write_tram      layer, row, col, data
//                   — write one tilemap RAM word via CPU bus ($110000 region)
//   read_tram       layer, row, col, exp
//                   — read tilemap RAM word (combinational dout), check
//   write_bg_rom    addr, data
//                   — write one byte into testbench BG tile ROM
//   write_scroll    layer, axis ("x"|"y"), data
//                   — write scroll register ($120000 region) then vsync_pulse
//   vsync_pulse     — assert vsync_n=0 for a few cycles → latch shadow→active
//   set_bg          bg_x, bg_y
//                   — drive bg_x / bg_y pixel coordinate inputs
//   clock_n         n  — advance n clock cycles
//   check_bg_valid  layer, exp  — check bg_pix_valid[layer]
//   check_bg_color  layer, exp  — check bg_pix_color[layer]
//
// Tile ROM model:
//   The testbench holds a 128 KB ROM array (1024 tiles × 128 bytes).
//   bg_rom_data is driven combinationally (zero latency):
//     - On negedge: eval, look up tile_rom[bg_rom_addr], set bg_rom_data
//     - On posedge: eval — FFs sample the updated bg_rom_data
//   This matches the GP9001 Gate 3 testbench pattern exactly.
//
// CPU address mapping for tilemap RAM writes ($110000-$11FFFF):
//   NMK16 addr port is [ADDR_WIDTH-1:1] = [20:1] (word-aligned).
//   Byte address = $110000 + (layer<<11)*2 + (row<<5)*2 + col*2
//   Word address (addr[20:1]) = (byte_addr >> 1).
//
// CPU address mapping for scroll register writes ($120000-$12FFFF):
//   Scroll0_X = $120000,  Scroll0_Y = $120002
//   Scroll1_X = $120004,  Scroll1_Y = $120006
//
// Exit: 0 = all pass, 1 = any failure.
// =============================================================================

#include "Vnmk16.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdint.h>
#include <string>
#include <fstream>
#include <vector>

// Tile ROM: 128 KB (1024 tiles × 128 bytes each)
static constexpr int BG_ROM_SIZE = 1 << 17;

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
    Vnmk16*              top;
    uint64_t             cycle;
    int                  failures;
    int                  checks;

    // BG Tile ROM: 128 KB
    std::vector<uint8_t> bg_rom;

    // Track previous vsync_n for edge generation
    uint8_t vsync_n_prev;

    DUT() : cycle(0), failures(0), checks(0), vsync_n_prev(1) {
        top = new Vnmk16();
        bg_rom.assign(BG_ROM_SIZE, 0);
        reset_inputs();
        do_reset();
    }

    ~DUT() {
        top->final();
        delete top;
    }

    void reset_inputs() {
        top->rst_n           = 0;
        top->clk             = 0;
        top->cs_n            = 1;
        top->rd_n            = 1;
        top->wr_n            = 1;
        top->lds_n           = 0;
        top->uds_n           = 0;
        top->addr            = 0;
        top->din             = 0;
        top->vsync_n         = 1;
        top->vsync_n_r       = 1;
        top->vblank_irq      = 0;
        top->sprite_done_irq = 0;
        top->sprite_data_rd  = 0;
        top->scan_trigger    = 0;
        top->current_scanline = 0;
        top->spr_rom_data    = 0;
        top->spr_rd_addr     = 0;
        top->bg_x            = 0;
        top->bg_y            = 0;
        top->bg_rom_data     = 0;
        vsync_n_prev         = 1;
    }

    // Tick one clock.
    // Drive bg_rom_data combinationally (zero-latency ROM model):
    //   negedge: eval, update bg_rom_data from bg_rom_addr
    //   posedge: eval (FFs sample the bg_rom_data)
    void clk_tick(int n = 1) {
        for (int i = 0; i < n; i++) {
            top->clk = 0;
            top->eval();
            // Combinational BG ROM read
            uint32_t a = top->bg_rom_addr & (BG_ROM_SIZE - 1);
            top->bg_rom_data = bg_rom[a];
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

    // ── vsync pulse: latch shadow → active scroll registers ──────────────────
    void vsync_pulse() {
        // vsync_n: 1 → 0 (falling edge triggers latch)
        top->vsync_n_r = 1;
        top->vsync_n   = 0;
        vsync_n_prev   = 0;
        top->cs_n = 1;
        top->wr_n = 1;
        top->rd_n = 1;
        clk_tick(2);
        // vsync_n: 0 → 1
        top->vsync_n_r = 0;
        top->vsync_n   = 1;
        vsync_n_prev   = 1;
        clk_tick(2);
    }

    // ── CPU bus write (generic) ───────────────────────────────────────────────
    void cpu_write(uint32_t byte_addr, uint16_t data) {
        // addr port = [20:1] = byte_addr >> 1
        top->addr  = (byte_addr >> 1) & 0x0FFFFF;
        top->din   = data;
        top->cs_n  = 0;
        top->wr_n  = 0;
        top->rd_n  = 1;
        top->vsync_n_r = vsync_n_prev;
        top->vsync_n   = 1;
        clk_tick(1);
        top->cs_n = 1;
        top->wr_n = 1;
        clk_tick(1);
    }

    // ── CPU bus read (combinational dout) ─────────────────────────────────────
    uint16_t cpu_read(uint32_t byte_addr) {
        top->addr  = (byte_addr >> 1) & 0x0FFFFF;
        top->cs_n  = 0;
        top->rd_n  = 0;
        top->wr_n  = 1;
        top->vsync_n_r = vsync_n_prev;
        top->vsync_n   = 1;
        top->clk = 0;
        top->eval();
        uint16_t d = (uint16_t)top->dout;
        top->cs_n = 1;
        top->rd_n = 1;
        // Settle one clock so ROM data gets updated
        clk_tick(1);
        return d;
    }

    // ── Write tilemap RAM word ────────────────────────────────────────────────
    // Byte address = $110000 + (layer * 1024 + row * 32 + col) * 2
    void write_tram(int layer, int row, int col, uint16_t data) {
        uint32_t word_idx  = (uint32_t)(layer * 1024 + row * 32 + col);
        uint32_t byte_addr = 0x110000 + word_idx * 2;
        cpu_write(byte_addr, data);
    }

    // ── Read tilemap RAM word (combinational) ─────────────────────────────────
    uint16_t read_tram(int layer, int row, int col) {
        uint32_t word_idx  = (uint32_t)(layer * 1024 + row * 32 + col);
        uint32_t byte_addr = 0x110000 + word_idx * 2;
        return cpu_read(byte_addr);
    }

    // ── Write scroll register ─────────────────────────────────────────────────
    // Scroll register byte addresses:
    //   Layer 0 X = $120000,  Layer 0 Y = $120002
    //   Layer 1 X = $120004,  Layer 1 Y = $120006
    void write_scroll(int layer, const std::string& axis, uint16_t data) {
        int reg_offset = layer * 4 + (axis == "y" ? 2 : 0);  // byte offset
        uint32_t byte_addr = 0x120000 + reg_offset;
        cpu_write(byte_addr, data);
        vsync_pulse();   // stage shadow → active
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

    // ── BG pixel output accessors ─────────────────────────────────────────────
    int get_bg_pix_valid(int layer) {
        return (int)((top->bg_pix_valid >> layer) & 1);
    }

    int get_bg_pix_color(int layer) {
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

        std::string op  = jstr(line, "op");
        int layer_val   = jint(line, "layer", 0);
        int exp_val     = jint(line, "exp",   0);

        if (op == "reset") {
            dut.do_reset();

        } else if (op == "write_tram") {
            int row  = jint(line, "row",  0);
            int col  = jint(line, "col",  0);
            int data = jint(line, "data", 0);
            dut.write_tram(layer_val, row, col, (uint16_t)(data & 0xFFFF));

        } else if (op == "read_tram") {
            int row = jint(line, "row", 0);
            int col = jint(line, "col", 0);
            uint16_t got = dut.read_tram(layer_val, row, col);
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "tram[L%d R%d C%d]", layer_val, row, col);
            dut.check(lbl, got, exp_val);

        } else if (op == "write_bg_rom") {
            int addr = jint(line, "addr", 0);
            int data = jint(line, "data", 0);
            uint32_t a = (uint32_t)addr & (BG_ROM_SIZE - 1);
            dut.bg_rom[a] = (uint8_t)(data & 0xFF);

        } else if (op == "write_scroll") {
            std::string axis = jstr(line, "axis");
            int data = jint(line, "data", 0);
            dut.write_scroll(layer_val, axis, (uint16_t)(data & 0xFFFF));

        } else if (op == "vsync_pulse") {
            dut.vsync_pulse();

        } else if (op == "set_bg") {
            int bg_x = jint(line, "bg_x", 0);
            int bg_y = jint(line, "bg_y", 0);
            dut.top->bg_x = (uint16_t)(bg_x & 0x1FF);
            dut.top->bg_y = (uint8_t) (bg_y & 0xFF);

        } else if (op == "clock_n") {
            int n = jint(line, "n", 1);
            dut.clk_tick(n);

        } else if (op == "check_bg_valid") {
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "bg_pix_valid[%d]", layer_val);
            dut.check(lbl, dut.get_bg_pix_valid(layer_val), exp_val);

        } else if (op == "check_bg_color") {
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "bg_pix_color[%d]", layer_val);
            dut.check(lbl, dut.get_bg_pix_color(layer_val), exp_val);

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
