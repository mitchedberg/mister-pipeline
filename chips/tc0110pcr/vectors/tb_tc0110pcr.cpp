// =============================================================================
// Gate 4: Verilator testbench for tc0110pcr.sv
//
// Reads tier1_vectors.jsonl. Each line:
//   {"addr": N, "data": N, "exp_r": N, "exp_g": N, "exp_b": N,
//    "exp_cpu_dout": N, "note": "..."}
//
// Per-vector test sequence (STEP_MODE=0, cpu_din = addr << 1):
//
//   tick 1: addr_write  cpu_cs=1 cpu_we=1 cpu_addr=0 cpu_din=addr<<1
//              posedge: addr_reg ← addr
//   tick 2: data_write  cpu_cs=1 cpu_we=1 cpu_addr=1 cpu_din=data
//              posedge: pal_ram[addr_reg] ← data
//   tick 3: idle
//              posedge: pal_ram_cpu_rd ← pal_ram[addr_reg] = data (new)
//   tick 4: idle
//              posedge: cpu_dout ← pal_ram_cpu_rd = data  → READ cpu_dout
//   tick 5: pxl_in=addr, pxl_valid=1
//              posedge: pal_ram_pxl_rd ← pal_ram[addr] = data
//   tick 6: pxl_in=addr, pxl_valid=1
//              posedge: color_reg ← pal_ram_pxl_rd = data  → READ r/g/b
//
// Additionally tests:
//   - Post-reset state (all outputs 0)
//   - pxl_valid=0 hold (color_reg does not update)
//   - Bit 15 stored in cpu_dout but not reflected in R/G/B
// =============================================================================

#include "Vtc0110pcr.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdint.h>
#include <vector>
#include <string>

// ---------------------------------------------------------------------------
// Minimal JSON field extraction (integer and string from flat JSON line)
// ---------------------------------------------------------------------------
static size_t jfind(const std::string& s, const std::string& key) {
    std::string pat = "\"" + key + "\"";
    auto p = s.find(pat);
    if (p == std::string::npos) return std::string::npos;
    p += pat.size();
    while (p < s.size() && (s[p]==' '||s[p]==':')) ++p;
    return p;
}

static int jint(const std::string& s, const std::string& key, int dflt = 0) {
    auto p = jfind(s, key);
    if (p == std::string::npos || p >= s.size()) return dflt;
    return (int)strtol(s.c_str() + p, nullptr, 0);
}

static std::string jstr(const std::string& s, const std::string& key) {
    auto p = jfind(s, key);
    if (p == std::string::npos || p >= s.size() || s[p] != '"') return "";
    ++p;
    auto e = s.find('"', p);
    return (e == std::string::npos) ? "" : s.substr(p, e - p);
}

// ---------------------------------------------------------------------------
// Test vector record
// ---------------------------------------------------------------------------
struct Vec {
    int addr, data;
    int exp_r, exp_g, exp_b;
    int exp_cpu_dout;
    std::string note;
};

// ---------------------------------------------------------------------------
// DUT helpers
// ---------------------------------------------------------------------------
static Vtc0110pcr* dut = nullptr;

static void tick() {
    dut->clk = 0;
    dut->eval();
    dut->clk = 1;
    dut->eval();
}

static void reset() {
    dut->async_rst_n = 0;
    dut->cpu_cs = 0;
    dut->cpu_we = 0;
    dut->cpu_addr = 0;
    dut->cpu_din = 0;
    dut->pxl_in = 0;
    dut->pxl_valid = 0;
    for (int i = 0; i < 4; i++) tick();
    dut->async_rst_n = 1;
    for (int i = 0; i < 2; i++) tick();
}

// Write palette address latch (A0=0): addr_reg ← addr (STEP_MODE=0: cpu_din=addr<<1)
static void write_addr(int addr) {
    dut->cpu_cs   = 1;
    dut->cpu_we   = 1;
    dut->cpu_addr = 0;
    dut->cpu_din  = (uint16_t)((addr & 0xFFF) << 1);
    tick();
    dut->cpu_cs = 0;
    dut->cpu_we = 0;
}

// Write palette data (A0=1): pal_ram[addr_reg] ← data
static void write_data(int data) {
    dut->cpu_cs   = 1;
    dut->cpu_we   = 1;
    dut->cpu_addr = 1;
    dut->cpu_din  = (uint16_t)(data & 0xFFFF);
    tick();
    dut->cpu_cs = 0;
    dut->cpu_we = 0;
}

// Idle tick (bus deselected)
static void idle() {
    dut->cpu_cs  = 0;
    dut->cpu_we  = 0;
    dut->pxl_valid = 0;
    tick();
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <tier1_vectors.jsonl>\n", argv[0]);
        return 1;
    }

    // Load vectors
    std::vector<Vec> vecs;
    FILE* fp = fopen(argv[1], "r");
    if (!fp) { perror(argv[1]); return 1; }
    char line[1024];
    while (fgets(line, sizeof(line), fp)) {
        std::string s(line);
        if (s.empty() || s[0] == '#') continue;
        Vec v;
        v.addr        = jint(s, "addr");
        v.data        = jint(s, "data");
        v.exp_r       = jint(s, "exp_r");
        v.exp_g       = jint(s, "exp_g");
        v.exp_b       = jint(s, "exp_b");
        v.exp_cpu_dout = jint(s, "exp_cpu_dout");
        v.note        = jstr(s, "note");
        vecs.push_back(v);
    }
    fclose(fp);
    printf("Loaded %zu test vectors\n", vecs.size());

    Verilated::commandArgs(argc, argv);
    dut = new Vtc0110pcr;

    int pass = 0, fail = 0;

    // ────────────────────────────────────────────────────────────────────────
    // Reset sanity check
    // ────────────────────────────────────────────────────────────────────────
    reset();

    // After reset: cpu_dout, r_out, g_out, b_out should all be 0
    {
        bool ok = (dut->cpu_dout == 0) && (dut->r_out == 0) &&
                  (dut->g_out == 0) && (dut->b_out == 0);
        if (ok) { ++pass; }
        else {
            ++fail;
            printf("FAIL [reset] cpu_dout=0x%04X r=%u g=%u b=%u (expected all 0)\n",
                   dut->cpu_dout, dut->r_out, dut->g_out, dut->b_out);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Per-vector tests: write then read/lookup
    // ────────────────────────────────────────────────────────────────────────
    for (size_t vi = 0; vi < vecs.size(); vi++) {
        const Vec& v = vecs[vi];

        // tick 1: write address latch
        write_addr(v.addr);

        // tick 2: write data
        write_data(v.data);

        // tick 3: idle — pal_ram_cpu_rd captures new data
        idle();

        // tick 4: idle — cpu_dout captures pal_ram_cpu_rd  → READ cpu_dout
        idle();
        int got_cpu_dout = dut->cpu_dout;

        // tick 5: pxl lookup — pal_ram_pxl_rd captures data
        dut->pxl_in    = (uint16_t)(v.addr & 0xFFF);
        dut->pxl_valid = 1;
        dut->cpu_cs    = 0;
        dut->cpu_we    = 0;
        tick();

        // tick 6: pxl valid again — color_reg captures pal_ram_pxl_rd → READ r/g/b
        dut->pxl_in    = (uint16_t)(v.addr & 0xFFF);
        dut->pxl_valid = 1;
        tick();
        dut->pxl_valid = 0;

        int got_r = dut->r_out;
        int got_g = dut->g_out;
        int got_b = dut->b_out;

        bool cpu_ok = (got_cpu_dout == v.exp_cpu_dout);
        bool rgb_ok = (got_r == v.exp_r) && (got_g == v.exp_g) && (got_b == v.exp_b);

        if (cpu_ok && rgb_ok) {
            ++pass;
        } else {
            ++fail;
            printf("FAIL [%zu] %s\n"
                   "  addr=0x%03X data=0x%04X\n",
                   vi, v.note.c_str(), v.addr, v.data);
            if (!cpu_ok)
                printf("  cpu_dout: got=0x%04X exp=0x%04X\n", got_cpu_dout, v.exp_cpu_dout);
            if (!rgb_ok)
                printf("  r: got=%u exp=%u  g: got=%u exp=%u  b: got=%u exp=%u\n",
                       got_r, v.exp_r, got_g, v.exp_g, got_b, v.exp_b);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // pxl_valid=0 hold test
    // Write a known color to addr 0x300, lookup it, then assert pxl_valid=0
    // while presenting a different pxl_in — color_reg must not change.
    // ────────────────────────────────────────────────────────────────────────
    {
        int hold_addr = 0x300;
        int hold_data = 0x6B5A;  // R=26, G=26, B=26
        int hold_r = hold_data & 0x1F;
        int hold_g = (hold_data >> 5) & 0x1F;
        int hold_b = (hold_data >> 10) & 0x1F;

        write_addr(hold_addr);
        write_data(hold_data);
        idle(); idle();

        // 2 cycles to latch color
        dut->pxl_in    = (uint16_t)hold_addr;
        dut->pxl_valid = 1;
        tick();
        dut->pxl_in    = (uint16_t)hold_addr;
        dut->pxl_valid = 1;
        tick();
        dut->pxl_valid = 0;

        // 3 cycles with pxl_valid=0 and a different pxl_in (addr 0 = 0 from prev test)
        for (int i = 0; i < 3; i++) {
            dut->pxl_in    = 0x000;
            dut->pxl_valid = 0;
            tick();
        }

        int got_r = dut->r_out, got_g = dut->g_out, got_b = dut->b_out;
        bool ok = (got_r == hold_r) && (got_g == hold_g) && (got_b == hold_b);
        if (ok) { ++pass; }
        else {
            ++fail;
            printf("FAIL [pxl_valid=0 hold] got r=%u g=%u b=%u exp r=%u g=%u b=%u\n",
                   got_r, got_g, got_b, hold_r, hold_g, hold_b);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Bit 15 round-trip: bit 15 must NOT appear in r/g/b but MUST appear in cpu_dout
    // ────────────────────────────────────────────────────────────────────────
    {
        int bit15_addr = 0x3FF;
        int bit15_data = 0x8015;  // bit15 set, R=21, G=0, B=0

        write_addr(bit15_addr);
        write_data(bit15_data);
        idle(); idle();
        int got_cpu_dout = dut->cpu_dout;

        dut->pxl_in = (uint16_t)bit15_addr; dut->pxl_valid = 1; tick();
        dut->pxl_in = (uint16_t)bit15_addr; dut->pxl_valid = 1; tick();
        dut->pxl_valid = 0;

        bool cpu_ok = ((got_cpu_dout & 0x8000) != 0);       // bit 15 preserved
        bool b_ok   = (dut->b_out == 0);                     // bit 15 NOT in B
        bool r_ok   = (dut->r_out == (bit15_data & 0x1F));   // R correct

        if (cpu_ok && b_ok && r_ok) { ++pass; }
        else {
            ++fail;
            printf("FAIL [bit15 round-trip] cpu_dout=0x%04X (bit15=%d) r=%u b=%u\n",
                   got_cpu_dout, (got_cpu_dout >> 15) & 1, dut->r_out, dut->b_out);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Summary
    // ────────────────────────────────────────────────────────────────────────
    int total = pass + fail;
    printf("\n%s: %d/%d tests passed\n",
           (fail == 0) ? "PASS" : "FAIL", pass, total);

    delete dut;
    return (fail == 0) ? 0 : 1;
}
