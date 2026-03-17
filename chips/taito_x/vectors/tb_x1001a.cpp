// =============================================================================
// X1-001A Phase 1 — Verilator testbench
//
// Reads gate1_vectors.jsonl and gate4_vectors.jsonl.
//
// Supported op codes:
//
// Gate 1 (Y RAM):
//   zero_yram      — clear Y RAM in DUT via CPU writes
//   yram_write     — addr, data, be
//   yram_read      — addr, exp
//   yram_scan_rd   — addr, exp  (internal scanner read port)
//
// Gate 4 (All RAMs + control registers):
//   reset          — pulse rst_n low then high
//   yram_write     — addr, data, be
//   yram_read      — addr, exp
//   yram_scan_rd   — addr, exp
//   cram_write     — addr, data, be
//   cram_read      — addr, exp
//   cram_scan_rd   — addr, exp
//   ctrl_write     — addr, data, be
//   ctrl_read      — addr, exp
//   check_flip_screen    — exp (0 or 1)
//   check_bg_startcol    — exp (0..3)
//   check_bg_numcol      — exp (0..15)
//   check_frame_bank     — exp (0 or 1)
//   check_col_upper_mask — exp (16-bit)
//
// Exit: 0 = all pass, 1 = any failure.
// =============================================================================

#include "Vx1_001a.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdint.h>
#include <string>
#include <fstream>
#include <vector>

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

static int jint(const std::string& s, const std::string& key, int dflt = -999) {
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
    Vx1_001a* top;
    uint64_t cycle;
    int      failures;
    int      checks;

    DUT() : cycle(0), failures(0), checks(0) {
        top = new Vx1_001a();
        reset();
    }

    ~DUT() { delete top; }

    void clk(int n = 1) {
        for (int i = 0; i < n; i++) {
            top->clk = 0; top->eval();
            top->clk = 1; top->eval();
            cycle++;
        }
    }

    void reset() {
        top->rst_n       = 0;
        top->yram_cs     = 0;
        top->yram_we     = 0;
        top->yram_addr   = 0;
        top->yram_din    = 0;
        top->yram_be     = 3;
        top->cram_cs     = 0;
        top->cram_we     = 0;
        top->cram_addr   = 0;
        top->cram_din    = 0;
        top->cram_be     = 3;
        top->ctrl_cs     = 0;
        top->ctrl_we     = 0;
        top->ctrl_addr   = 0;
        top->ctrl_din    = 0;
        top->ctrl_be     = 3;
        top->scan_yram_addr = 0;
        top->scan_cram_addr = 0;
        clk(4);
        top->rst_n = 1;
        clk(4);
    }

    // ── Y RAM access ──────────────────────────────────────────────────────────
    void yram_write(int addr, int data, int be = 3) {
        top->yram_cs   = 1;
        top->yram_we   = 1;
        top->yram_addr = addr & 0x3FF;
        top->yram_din  = data & 0xFFFF;
        top->yram_be   = be & 3;
        clk(2);
        top->yram_cs = 0;
        top->yram_we = 0;
    }

    uint16_t yram_read(int addr) {
        top->yram_cs   = 1;
        top->yram_we   = 0;
        top->yram_addr = addr & 0x3FF;
        top->yram_be   = 3;
        clk(2);  // registered read — data appears 1 cycle after address
        uint16_t d = top->yram_dout;
        top->yram_cs = 0;
        return d;
    }

    uint16_t yram_scan_read(int addr) {
        top->scan_yram_addr = addr & 0x3FF;
        clk(2);
        return top->scan_yram_data;
    }

    void zero_yram() {
        for (int a = 0; a < 0x180; a++) {
            top->yram_cs   = 1;
            top->yram_we   = 1;
            top->yram_addr = a;
            top->yram_din  = 0;
            top->yram_be   = 3;
            clk(1);
        }
        top->yram_cs = 0;
        top->yram_we = 0;
        clk(1);
    }

    // ── Code RAM access ───────────────────────────────────────────────────────
    void cram_write(int addr, int data, int be = 3) {
        top->cram_cs   = 1;
        top->cram_we   = 1;
        top->cram_addr = addr & 0x1FFF;
        top->cram_din  = data & 0xFFFF;
        top->cram_be   = be & 3;
        clk(2);
        top->cram_cs = 0;
        top->cram_we = 0;
    }

    uint16_t cram_read(int addr) {
        top->cram_cs   = 1;
        top->cram_we   = 0;
        top->cram_addr = addr & 0x1FFF;
        top->cram_be   = 3;
        clk(2);
        uint16_t d = top->cram_dout;
        top->cram_cs = 0;
        return d;
    }

    uint16_t cram_scan_read(int addr) {
        top->scan_cram_addr = addr & 0x1FFF;
        clk(2);
        return top->scan_cram_data;
    }

    // ── Control register access ───────────────────────────────────────────────
    void ctrl_write(int addr, int data, int be = 3) {
        top->ctrl_cs   = 1;
        top->ctrl_we   = 1;
        top->ctrl_addr = addr & 3;
        top->ctrl_din  = data & 0xFFFF;
        top->ctrl_be   = be & 3;
        clk(2);
        top->ctrl_cs = 0;
        top->ctrl_we = 0;
    }

    uint16_t ctrl_read(int addr) {
        top->ctrl_cs   = 1;
        top->ctrl_we   = 0;
        top->ctrl_addr = addr & 3;
        top->ctrl_be   = 3;
        clk(2);
        uint16_t d = top->ctrl_dout;
        top->ctrl_cs = 0;
        return d;
    }

    // ── Check helper ──────────────────────────────────────────────────────────
    void check(const char* label, int got, int exp) {
        checks++;
        if (got != exp) {
            fprintf(stderr, "FAIL  %s: got 0x%04X exp 0x%04X\n", label, got, exp);
            failures++;
        } else {
            fprintf(stderr, "pass  %s: 0x%04X\n", label, got);
        }
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
        line_num++;
        if (line.empty() || line[0] == '#') continue;

        std::string op = jstr(line, "op");
        int addr = jint(line, "addr", 0);
        int data = jint(line, "data", 0);
        int be   = jint(line, "be",   3);
        int exp  = jint(line, "exp",  0);

        if (op == "zero_yram") {
            dut.zero_yram();

        } else if (op == "reset") {
            dut.reset();

        } else if (op == "yram_write") {
            dut.yram_write(addr, data, be);

        } else if (op == "yram_read") {
            uint16_t got = dut.yram_read(addr);
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "yram_rd[0x%03X]", addr);
            dut.check(lbl, got, exp);

        } else if (op == "yram_scan_rd") {
            uint16_t got = dut.yram_scan_read(addr);
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "yram_scan[0x%03X]", addr);
            dut.check(lbl, got, exp);

        } else if (op == "cram_write") {
            dut.cram_write(addr, data, be);

        } else if (op == "cram_read") {
            uint16_t got = dut.cram_read(addr);
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "cram_rd[0x%04X]", addr);
            dut.check(lbl, got, exp);

        } else if (op == "cram_scan_rd") {
            uint16_t got = dut.cram_scan_read(addr);
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "cram_scan[0x%04X]", addr);
            dut.check(lbl, got, exp);

        } else if (op == "ctrl_write") {
            dut.ctrl_write(addr, data, be);

        } else if (op == "ctrl_read") {
            uint16_t got = dut.ctrl_read(addr);
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "ctrl_rd[%d]", addr);
            dut.check(lbl, got, exp);

        } else if (op == "check_flip_screen") {
            int got = (int)dut.top->flip_screen;
            dut.check("flip_screen", got, exp);

        } else if (op == "check_bg_startcol") {
            int got = (int)dut.top->bg_startcol;
            dut.check("bg_startcol", got, exp);

        } else if (op == "check_bg_numcol") {
            int got = (int)dut.top->bg_numcol;
            dut.check("bg_numcol", got, exp);

        } else if (op == "check_frame_bank") {
            int got = (int)dut.top->frame_bank;
            dut.check("frame_bank", got, exp);

        } else if (op == "check_col_upper_mask") {
            int got = (int)dut.top->col_upper_mask;
            dut.check("col_upper_mask", got, exp);

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
        fprintf(stderr, "Usage: %s <vec1.jsonl> [vec2.jsonl ...]\n", argv[0]);
        return 1;
    }

    DUT dut;
    int err = 0;

    for (int i = 1; i < argc; i++) {
        err |= run_vectors(dut, argv[i]);
    }

    fprintf(stderr, "\n=== Results: %d checks, %d failures ===\n",
            dut.checks, dut.failures);

    if (dut.failures > 0 || err) {
        fprintf(stderr, "FAIL\n");
        return 1;
    }
    fprintf(stderr, "PASS\n");
    return 0;
}
