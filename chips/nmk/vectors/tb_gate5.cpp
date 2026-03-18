// =============================================================================
// NMK16 Gate 5 — Verilator testbench
//
// Reads gate5_vectors.jsonl and exercises the priority mixer (Gate 5).
//
// Gate 5 is purely combinational.  It reads:
//   spr_rd_valid / spr_rd_color / spr_rd_priority  (Gate 3 scanline buffer)
//   bg_pix_valid / bg_pix_color                    (Gate 4 pipeline outputs)
// and produces:
//   final_valid, final_color
//
// Test strategy: use the full DUT (Gates 1-4 are all present in nmk16.sv)
// to produce known sprite and BG pixel values, then check Gate 5 output.
//
// Supported op codes:
//
//   reset                          — pulse rst_n low then high
//   vsync_pulse                    — assert vsync_n falling edge → shadow→active
//   write_tram  layer, row, col, data — write tilemap RAM word (Gate 4)
//   write_bg_rom  addr, data       — write BG tile ROM byte
//   write_spr_rom addr, data       — write sprite ROM byte (Gate 3)
//   write_sram  addr, data         — write sprite RAM word (Gate 2/3)
//   vblank_scan                    — assert vblank, wait for display_list_ready
//   scan_line   scanline           — pulse scan_trigger, wait for spr_render_done
//   set_spr_rd_addr  x             — set spr_rd_addr (Gate 3 pixel read-back)
//   set_bg      bg_x, bg_y        — drive bg_x / bg_y (Gate 4 pixel inputs)
//   clock_n     n                  — advance n clock cycles
//   check_final exp_valid, exp_color — check Gate 5 outputs
//   comment     text               — ignored (human-readable annotation)
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

// Timing constants
static constexpr int VBLANK_CYCLES = 512;
static constexpr int SCAN_TIMEOUT  = 4096;

// ROM sizes
static constexpr int SPR_ROM_SIZE = 1 << 21;   // 2 MB
static constexpr int BG_ROM_SIZE  = 1 << 17;   // 128 KB

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

    std::vector<uint8_t> spr_rom;
    std::vector<uint8_t> bg_rom;

    uint8_t vsync_n_prev;

    DUT() : cycle(0), failures(0), checks(0), vsync_n_prev(1) {
        top = new Vnmk16();
        spr_rom.assign(SPR_ROM_SIZE, 0);
        bg_rom.assign(BG_ROM_SIZE, 0);
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
        top->cs_n             = 1;
        top->rd_n             = 1;
        top->wr_n             = 1;
        top->lds_n            = 0;
        top->uds_n            = 0;
        top->addr             = 0;
        top->din              = 0;
        top->vsync_n          = 1;
        top->vsync_n_r        = 1;
        top->vblank_irq       = 0;
        top->sprite_done_irq  = 0;
        top->sprite_data_rd   = 0;
        top->scan_trigger     = 0;
        top->current_scanline = 0;
        top->spr_rom_data     = 0;
        top->spr_rd_addr      = 0;
        top->bg_x             = 0;
        top->bg_y             = 0;
        top->bg_rom_data      = 0;
        vsync_n_prev          = 1;
    }

    // Tick one clock.  Drive both ROMs combinationally (zero-latency model):
    //   negedge: eval, look up ROM arrays, drive data
    //   posedge: eval (FFs sample the data)
    void clk_tick(int n = 1) {
        for (int i = 0; i < n; i++) {
            top->clk = 0;
            top->eval();
            // Sprite ROM
            uint32_t sa = top->spr_rom_addr & (SPR_ROM_SIZE - 1);
            top->spr_rom_data = spr_rom[sa];
            // BG tile ROM
            uint32_t ba = top->bg_rom_addr & (BG_ROM_SIZE - 1);
            top->bg_rom_data = bg_rom[ba];
            top->clk = 1;
            top->eval();
            ++cycle;
        }
    }

    // Settle combinational outputs without advancing the clock
    void settle() {
        top->clk = 0;
        top->eval();
        uint32_t sa = top->spr_rom_addr & (SPR_ROM_SIZE - 1);
        top->spr_rom_data = spr_rom[sa];
        uint32_t ba = top->bg_rom_addr & (BG_ROM_SIZE - 1);
        top->bg_rom_data = bg_rom[ba];
        top->eval();
    }

    void do_reset() {
        reset_inputs();
        clk_tick(4);
        top->rst_n = 1;
        clk_tick(4);
    }

    // ── vsync pulse: latch shadow → active registers ──────────────────────
    void vsync_pulse() {
        top->vsync_n_r = 1;
        top->vsync_n   = 0;
        vsync_n_prev   = 0;
        top->cs_n = 1;
        top->wr_n = 1;
        top->rd_n = 1;
        clk_tick(2);
        top->vsync_n_r = 0;
        top->vsync_n   = 1;
        vsync_n_prev   = 1;
        clk_tick(2);
    }

    // ── Generic CPU bus write ─────────────────────────────────────────────
    void cpu_write(uint32_t byte_addr, uint16_t data) {
        top->addr         = (byte_addr >> 1) & 0x0FFFFF;
        top->din          = data;
        top->cs_n         = 0;
        top->wr_n         = 0;
        top->rd_n         = 1;
        top->vsync_n_r    = vsync_n_prev;
        top->vsync_n      = 1;
        clk_tick(1);
        top->cs_n = 1;
        top->wr_n = 1;
        clk_tick(1);
    }

    // ── Tilemap RAM write: $110000 + (layer*1024 + row*32 + col) * 2 ─────
    void write_tram(int layer, int row, int col, uint16_t data) {
        uint32_t word_idx  = (uint32_t)(layer * 1024 + row * 32 + col);
        uint32_t byte_addr = 0x110000 + word_idx * 2;
        cpu_write(byte_addr, data);
    }

    // ── Sprite RAM write: $130000 + word_idx * 2 ─────────────────────────
    void write_sram(int word_idx, uint16_t data) {
        uint32_t byte_addr = 0x130000 + (uint32_t)word_idx * 2;
        cpu_write(byte_addr, data);
    }

    // ── Vblank scan: assert vblank IRQ, wait for display_list_ready ───────
    void vblank_scan() {
        top->vblank_irq = 1;
        bool done = false;
        for (int i = 0; i < VBLANK_CYCLES && !done; i++) {
            clk_tick(1);
            if (top->display_list_ready) done = true;
        }
        top->vblank_irq = 0;
        clk_tick(4);
        if (!done) {
            fprintf(stderr, "WARNING: vblank_scan: display_list_ready not seen "
                    "within %d cycles\n", VBLANK_CYCLES);
        }
    }

    // ── Scan line: trigger Gate 3 rasterizer ──────────────────────────────
    bool scan_line(int scanline) {
        top->current_scanline = (uint16_t)(scanline & 0x1FF);
        top->scan_trigger     = 1;
        clk_tick(1);
        top->scan_trigger     = 0;
        for (int i = 0; i < SCAN_TIMEOUT; i++) {
            clk_tick(1);
            if (top->spr_render_done) {
                clk_tick(1);
                return true;
            }
        }
        fprintf(stderr, "WARNING: scan_line(%d): spr_render_done not seen "
                "within %d cycles\n", scanline, SCAN_TIMEOUT);
        return false;
    }

    // ── Set spr_rd_addr and settle combinational Gate 5 paths ─────────────
    void set_spr_rd_addr(int x) {
        top->spr_rd_addr = (uint16_t)(x & 0x1FF);
        settle();
    }

    // ── Check helper ──────────────────────────────────────────────────────
    void check(const char* label, int got, int exp) {
        ++checks;
        if (got != exp) {
            fprintf(stderr, "FAIL  %s: got 0x%04X exp 0x%04X\n", label, got, exp);
            ++failures;
        } else {
            fprintf(stderr, "pass  %s: 0x%04X\n", label, got);
        }
    }

    int get_final_color() { return (int)(uint8_t)top->final_color; }
    int get_final_valid() { return (int)(top->final_valid & 1); }
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

        std::string op = jstr(line, "op");

        if (op == "comment") {
            // Human-readable annotation — print as section header
            std::string text = jstr(line, "text");
            fprintf(stderr, "-- %s --\n", text.c_str());

        } else if (op == "reset") {
            dut.do_reset();

        } else if (op == "vsync_pulse") {
            dut.vsync_pulse();

        } else if (op == "write_tram") {
            int layer = jint(line, "layer", 0);
            int row   = jint(line, "row",   0);
            int col   = jint(line, "col",   0);
            int data  = jint(line, "data",  0);
            dut.write_tram(layer, row, col, (uint16_t)(data & 0xFFFF));

        } else if (op == "write_bg_rom") {
            int addr = jint(line, "addr", 0);
            int data = jint(line, "data", 0);
            uint32_t a = (uint32_t)addr & (BG_ROM_SIZE - 1);
            dut.bg_rom[a] = (uint8_t)(data & 0xFF);

        } else if (op == "write_spr_rom") {
            int addr = jint(line, "addr", 0);
            int data = jint(line, "data", 0);
            uint32_t a = (uint32_t)addr & (SPR_ROM_SIZE - 1);
            dut.spr_rom[a] = (uint8_t)(data & 0xFF);

        } else if (op == "write_sram") {
            int addr = jint(line, "addr", 0);
            int data = jint(line, "data", 0);
            dut.write_sram(addr, (uint16_t)(data & 0xFFFF));

        } else if (op == "vblank_scan") {
            dut.vblank_scan();

        } else if (op == "scan_line") {
            int scanline = jint(line, "scanline", 0);
            dut.scan_line(scanline);

        } else if (op == "set_spr_rd_addr") {
            int x = jint(line, "x", 0);
            dut.set_spr_rd_addr(x);

        } else if (op == "set_bg") {
            int bg_x = jint(line, "bg_x", 0);
            int bg_y = jint(line, "bg_y", 0);
            dut.top->bg_x = (uint16_t)(bg_x & 0x1FF);
            dut.top->bg_y = (uint8_t) (bg_y & 0xFF);

        } else if (op == "clock_n") {
            int n = jint(line, "n", 1);
            dut.clk_tick(n);

        } else if (op == "check_final") {
            int exp_valid = jint(line, "exp_valid", 0);
            int exp_color = jint(line, "exp_color", 0);

            // Settle combinational outputs (Gate 5 is always_comb)
            dut.settle();

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
