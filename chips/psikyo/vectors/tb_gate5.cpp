// =============================================================================
// Psikyo Gate 5 — Verilator testbench: Priority Mixer / Color Compositor
//
// Reads gate5_vectors.jsonl and drives the psikyo_gate5 DUT.
//
// Gate 5 is purely combinational: no clocks required.
// Each scenario drives all inputs combinationally and reads outputs immediately.
//
// Supported ops:
//   set_inputs   — drive all compositor inputs:
//                  spr_valid, spr_color, spr_prio,
//                  bg0_valid, bg0_color, bg1_valid, bg1_color
//   check_final  — check final_valid and (if exp_valid=1) final_color
//   comment      — text: section marker printed to stderr
//
// Input port layout (psikyo_gate5):
//   spr_rd_color    [7:0]   — sprite pixel color
//   spr_rd_valid    [0]     — sprite pixel valid
//   spr_rd_priority [1:0]   — sprite priority (0–3)
//   bg_pix_color[0] [7:0]   — BG0 pixel color
//   bg_pix_color[1] [7:0]   — BG1 pixel color
//   bg_pix_valid    [1:0]   — [0]=BG0 valid, [1]=BG1 valid
//   bg_pix_priority[0][1:0] — BG0 priority attribute (not used in composition)
//   bg_pix_priority[1][1:0] — BG1 priority attribute (not used in composition)
//
// Output port layout:
//   final_color     [7:0]   — winning pixel color
//   final_valid     [0]     — 1 = at least one opaque layer
//
// Exit: 0 = all pass, 1 = any failure.
// =============================================================================

#include "Vpsikyo_gate5.h"
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
    ++p;
    auto end = s.find('"', p);
    if (end == std::string::npos) return "";
    return s.substr(p, end - p);
}

// ---------------------------------------------------------------------------
// DUT wrapper
// ---------------------------------------------------------------------------

struct DUT {
    Vpsikyo_gate5* top;
    int            failures;
    int            checks;

    DUT() : failures(0), checks(0) {
        top = new Vpsikyo_gate5();
        reset_inputs();
    }

    ~DUT() {
        top->final();
        delete top;
    }

    void reset_inputs() {
        top->spr_rd_color    = 0;
        top->spr_rd_valid    = 0;
        top->spr_rd_priority = 0;
        top->bg_pix_color[0] = 0;
        top->bg_pix_color[1] = 0;
        top->bg_pix_valid    = 0;
        top->bg_pix_priority[0] = 0;
        top->bg_pix_priority[1] = 0;
        top->eval();
    }

    // Drive all compositor inputs and settle combinational paths.
    void set_inputs(int spr_valid, int spr_color, int spr_prio,
                    int bg0_valid, int bg0_color,
                    int bg1_valid, int bg1_color) {
        top->spr_rd_color    = (uint8_t)(spr_color & 0xFF);
        top->spr_rd_valid    = (uint8_t)(spr_valid & 1);
        top->spr_rd_priority = (uint8_t)(spr_prio  & 0x3);

        top->bg_pix_color[0] = (uint8_t)(bg0_color & 0xFF);
        top->bg_pix_color[1] = (uint8_t)(bg1_color & 0xFF);

        // bg_pix_valid: [0]=BG0, [1]=BG1
        uint8_t bv = (uint8_t)(((bg1_valid & 1) << 1) | (bg0_valid & 1));
        top->bg_pix_valid = bv;

        // bg_pix_priority: not used in composition; drive zeros
        top->bg_pix_priority[0] = 0;
        top->bg_pix_priority[1] = 0;

        top->eval();
    }

    // Check helper
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

        if (op == "set_inputs") {
            int spr_valid = jint(line, "spr_valid", 0);
            int spr_color = jint(line, "spr_color", 0);
            int spr_prio  = jint(line, "spr_prio",  0);
            int bg0_valid = jint(line, "bg0_valid", 0);
            int bg0_color = jint(line, "bg0_color", 0);
            int bg1_valid = jint(line, "bg1_valid", 0);
            int bg1_color = jint(line, "bg1_color", 0);
            dut.set_inputs(spr_valid, spr_color, spr_prio,
                           bg0_valid, bg0_color,
                           bg1_valid, bg1_color);

        } else if (op == "check_final") {
            int exp_valid = jint(line, "exp_valid", 0);
            int exp_color = jint(line, "exp_color", 0);

            // Settle combinational paths (Gate 5 is pure comb, no clock needed)
            dut.top->eval();

            dut.check("final_valid", dut.get_final_valid(), exp_valid);
            if (exp_valid) {
                dut.check("final_color", dut.get_final_color(), exp_color);
            }

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
