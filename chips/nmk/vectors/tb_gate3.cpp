// =============================================================================
// NMK16 Gate 3 — Verilator testbench
//
// Reads gate3_vectors.jsonl and drives the nmk16 DUT through the sprite
// rasterizer (Gate 3) path.
//
// Supported op codes:
//
//   reset            — pulse rst_n low then high
//   vblank_scan      — assert vsync_n=0 for ~1100 cycles so Gate 2 FSM scans
//                      all 256 sprites and sets display_list_ready; then
//                      deassert vsync_n=1
//   write_sram       — addr, data: write sprite RAM word (CPU bus write to
//                      $130000 + addr*2)
//   write_spr_rom    — addr, data: write one byte into testbench sprite ROM
//   scan_line        — scanline: pulse scan_trigger=1 for 1 cycle, then clock
//                      until spr_render_done or SCAN_TIMEOUT cycles
//   check_spr        — x, exp_valid, exp_color: set spr_rd_addr=x, evaluate
//                      combinationally, check spr_rd_valid and spr_rd_color
//
// Sprite ROM model:
//   2 MB byte array in testbench.  spr_rom_data is driven combinationally
//   (zero latency) after each negedge: look up spr_rom[spr_rom_addr].
//
// Timing for vblank_scan:
//   Assert vsync_n=0 for VBLANK_CYCLES clocks (≥1025 to scan all 256
//   sprites × 4 words).  Clock until display_list_ready pulses or timeout.
//
// Timing for scan_line:
//   Pulse scan_trigger=1 for 1 cycle with current_scanline set.
//   Then clock until spr_render_done goes high (or SCAN_TIMEOUT).
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
static constexpr int VBLANK_CYCLES = 1200;   // enough for Gate 2 to scan all 256 sprites
static constexpr int SCAN_TIMEOUT  = 4096;   // max cycles for Gate 3 to finish one scanline

// Sprite ROM: 2MB
static constexpr int SPR_ROM_SIZE = 1 << 21;

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

    // Sprite ROM: 2MB, combinationally read by Gate 3
    std::vector<uint8_t> spr_rom;

    // Track previous vsync_n for edge generation
    uint8_t              vsync_n_prev;

    DUT() : cycle(0), failures(0), checks(0), vsync_n_prev(1) {
        top = new Vnmk16();
        spr_rom.assign(SPR_ROM_SIZE, 0);
        reset_inputs();
        do_reset();
    }

    ~DUT() {
        top->final();
        delete top;
    }

    void reset_inputs() {
        top->rst_n        = 0;
        top->clk          = 0;
        top->cs_n         = 1;
        top->rd_n         = 1;
        top->wr_n         = 1;
        top->lds_n        = 0;
        top->uds_n        = 0;
        top->addr         = 0;
        top->din          = 0;
        top->vsync_n      = 1;
        top->vsync_n_r    = 1;
        top->vblank_irq   = 0;
        top->sprite_done_irq = 0;
        top->sprite_data_rd = 0;
        top->scan_trigger   = 0;
        top->current_scanline = 0;
        top->spr_rom_data   = 0;
        top->spr_rd_addr    = 0;
        vsync_n_prev        = 1;
    }

    // Tick one clock.  Drive sprite ROM combinationally.
    void clk_tick(int n = 1) {
        for (int i = 0; i < n; i++) {
            top->clk = 0;
            top->eval();
            // Combinational sprite ROM read
            uint32_t a = top->spr_rom_addr & (SPR_ROM_SIZE - 1);
            top->spr_rom_data = spr_rom[a];
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

    // ── CPU bus write to sprite RAM ($130000 + addr*2) ────────────────────
    void write_sram(int word_idx, int data) {
        // Sprite RAM is mapped at $130000 → addr[20:16]=10011
        // addr[10:1] = word_idx within sprite RAM
        uint32_t byte_addr = 0x130000 + (word_idx & 0x3FF) * 2;
        top->addr   = (byte_addr >> 1) & 0x0FFFFF;  // drop bit 0
        top->din    = (uint16_t)(data & 0xFFFF);
        top->cs_n   = 0;
        top->wr_n   = 0;
        top->rd_n   = 1;
        top->vsync_n_r = vsync_n_prev;
        top->vsync_n   = 1;
        vsync_n_prev   = 1;
        clk_tick(1);
        top->cs_n  = 1;
        top->wr_n  = 1;
        clk_tick(1);
    }

    // ── Assert VBLANK for VBLANK_CYCLES, wait for display_list_ready ──────
    void vblank_scan() {
        // vsync_n: 1 → 0  (falling edge triggers Gate 2 FSM)
        top->vsync_n_r = 1;
        top->vsync_n   = 0;
        vsync_n_prev   = 0;
        top->cs_n = 1;
        top->wr_n = 1;
        top->rd_n = 1;

        bool done = false;
        for (int i = 0; i < VBLANK_CYCLES && !done; i++) {
            clk_tick(1);
            top->vsync_n_r = vsync_n_prev;
            if (top->display_list_ready) {
                done = true;
            }
        }

        // End VBLANK: vsync_n 0 → 1
        top->vsync_n_r = 0;
        top->vsync_n   = 1;
        vsync_n_prev   = 1;
        clk_tick(4);   // settle

        if (!done) {
            fprintf(stderr, "WARNING: vblank_scan: display_list_ready not seen "
                    "within %d cycles\n", VBLANK_CYCLES);
        }
    }

    // ── Pulse scan_trigger, clock until spr_render_done ──────────────────
    bool scan_line(int scanline) {
        top->current_scanline = (uint16_t)(scanline & 0x1FF);
        top->scan_trigger     = 1;
        top->vsync_n_r = vsync_n_prev;
        top->vsync_n   = 1;
        clk_tick(1);
        top->scan_trigger = 0;

        for (int i = 0; i < SCAN_TIMEOUT; i++) {
            clk_tick(1);
            if (top->spr_render_done) {
                clk_tick(1);   // let outputs settle
                return true;
            }
        }
        fprintf(stderr, "WARNING: scan_line(%d): spr_render_done not seen "
                "within %d cycles\n", scanline, SCAN_TIMEOUT);
        return false;
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

    // ── Read one pixel from the sprite scanline buffer ────────────────────
    void set_rd_addr(int x) {
        top->spr_rd_addr = (uint16_t)(x & 0x1FF);
        top->clk = 0;
        top->eval();
        uint32_t a = top->spr_rom_addr & (SPR_ROM_SIZE - 1);
        top->spr_rom_data = spr_rom[a];
        top->clk = 0;
        top->eval();   // settle combinational
    }

    int get_spr_color() { return (int)(uint8_t)top->spr_rd_color; }
    int get_spr_valid() { return (int)(top->spr_rd_valid & 1); }
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

        if (op == "reset") {
            dut.do_reset();

        } else if (op == "write_sram") {
            int addr = jint(line, "addr", 0);
            int data = jint(line, "data", 0);
            dut.write_sram(addr, data);

        } else if (op == "write_spr_rom") {
            int addr = jint(line, "addr", 0);
            int data = jint(line, "data", 0);
            uint32_t a = (uint32_t)addr & (SPR_ROM_SIZE - 1);
            dut.spr_rom[a] = (uint8_t)(data & 0xFF);

        } else if (op == "vblank_scan") {
            dut.vblank_scan();

        } else if (op == "scan_line") {
            int scanline = jint(line, "scanline", 0);
            dut.scan_line(scanline);

        } else if (op == "check_spr") {
            int x         = jint(line, "x",         0);
            int exp_valid = jint(line, "exp_valid",  0);
            int exp_color = jint(line, "exp_color",  0);

            dut.set_rd_addr(x);

            char lbl_v[64], lbl_c[64];
            snprintf(lbl_v, sizeof(lbl_v), "spr_valid[%d]", x);
            snprintf(lbl_c, sizeof(lbl_c), "spr_color[%d]", x);

            dut.check(lbl_v, dut.get_spr_valid(), exp_valid);
            if (exp_valid) {
                dut.check(lbl_c, dut.get_spr_color(), exp_color);
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
        fprintf(stderr, "Usage: %s <gate3_vectors.jsonl> [...]\n", argv[0]);
        return 1;
    }

    DUT dut;
    int err = 0;

    for (int i = 1; i < argc; i++) {
        err |= run_vectors(dut, argv[i]);
    }

    fprintf(stderr, "\n=== Results: %d checks, %d failures ===\n",
            dut.checks, dut.failures);

    // Print summary in format matching existing gate tests
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
