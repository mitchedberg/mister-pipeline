// =============================================================================
// TC0650FDA Step 1 — Verilator testbench
//
// Reads tier1_vectors.jsonl.  Each line is a JSON object with "op" field:
//
//   "write"    — CPU write: drive cpu_cs=1, cpu_we=1, addr, data, be → tick
//   "readback" — CPU read:  read cpu_rd_raw (registered, 1-cycle latency)
//   "lookup"   — pixel pipeline: drive src_pal, pixel_valid=1; advance
//                2 ce_pixel cycles; sample video_r/g/b
//   "reset_check" — verified inline before vector loop
//
// Timing model:
//   tick()        — one system-clock edge (clk 0→1)
//   pixel_tick()  — tick with ce_pixel=1 (advances pixel pipeline)
//
// CPU write:
//   cycle 0: present cpu_cs=1, cpu_we=1, addr, data, be → posedge writes BRAM
//   cycle 1: deassert cpu_we
//
// CPU readback:
//   cycle 0: present cpu_cs=1, cpu_we=0, addr → posedge samples src_bram
//   cycle 1: cpu_rd_raw valid → sample
//
// Pixel lookup pipeline (2 ce_pixel stages):
//   ce0:  present src_pal, pixel_valid=1 → BRAM read addressed
//   ce1:  pal_rd_data registered (BRAM output)
//   ce2:  video_r/g/b registered → SAMPLE
//
// =============================================================================

#include "Vtc0650fda.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdint.h>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// Minimal JSON field extraction
// ---------------------------------------------------------------------------
static size_t jfind(const std::string& s, const std::string& key) {
    std::string pat = "\"" + key + "\"";
    auto p = s.find(pat);
    if (p == std::string::npos) return std::string::npos;
    p += pat.size();
    while (p < s.size() && (s[p]==' '||s[p]==':')) ++p;
    return p;
}

static long long jint(const std::string& s, const std::string& key, long long dflt = 0) {
    auto p = jfind(s, key);
    if (p == std::string::npos) return dflt;
    return (long long)strtoll(s.c_str() + p, nullptr, 0);
}

static std::string jstr(const std::string& s, const std::string& key) {
    auto p = jfind(s, key);
    if (p == std::string::npos || s[p] != '"') return "";
    ++p;
    auto e = s.find('"', p);
    return (e == std::string::npos) ? "" : s.substr(p, e - p);
}

// ---------------------------------------------------------------------------
// Vector record
// ---------------------------------------------------------------------------
struct Vec {
    std::string op;
    int         addr;
    uint32_t    data;
    int         be;
    int         mode_12bit;
    int         exp_r, exp_g, exp_b;
    uint32_t    exp_data;   // for readback
    std::string note;
};

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
static Vtc0650fda* dut = nullptr;

static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
}

// Tick with pixel clock enable asserted
static void pixel_tick() {
    dut->ce_pixel = 1;
    tick();
    dut->ce_pixel = 0;
}

// Idle tick: CPU bus deselected, no pixel clock
static void idle() {
    dut->cpu_cs  = 0;
    dut->cpu_we  = 0;
    dut->ce_pixel = 0;
    tick();
}

static void reset_dut() {
    dut->rst_n       = 0;
    dut->ce_pixel    = 0;
    dut->cpu_cs      = 0;
    dut->cpu_we      = 0;
    dut->cpu_addr    = 0;
    dut->cpu_din     = 0;
    dut->cpu_be      = 0;
    dut->pixel_valid = 0;
    dut->src_pal     = 0;
    dut->dst_pal     = 0;
    dut->src_blend   = 0;
    dut->dst_blend   = 0;
    dut->mode_12bit  = 0;
    for (int i = 0; i < 4; i++) tick();
    dut->rst_n = 1;
    for (int i = 0; i < 2; i++) tick();
}

// ---------------------------------------------------------------------------
// CPU write helper
// ---------------------------------------------------------------------------
static void cpu_write(int addr, uint32_t data, int be) {
    dut->cpu_cs   = 1;
    dut->cpu_we   = 1;
    dut->cpu_addr = (uint16_t)(addr & 0x1FFF);
    dut->cpu_din  = data;
    dut->cpu_be   = (uint8_t)(be & 0xF);
    tick();
    dut->cpu_cs = 0;
    dut->cpu_we = 0;
}

// ---------------------------------------------------------------------------
// CPU readback helper: present address, tick, then read cpu_rd_raw
// Returns the registered BRAM word one cycle after address presentation.
// ---------------------------------------------------------------------------
static uint32_t cpu_readback(int addr) {
    dut->cpu_cs   = 1;
    dut->cpu_we   = 0;
    dut->cpu_addr = (uint16_t)(addr & 0x1FFF);
    dut->cpu_be   = 0xF;
    tick();
    dut->cpu_cs = 0;
    // cpu_rd_raw is now valid (registered on that rising edge)
    return dut->cpu_rd_raw;
}

// ---------------------------------------------------------------------------
// Pixel lookup helper
// Drives src_pal with pixel_valid=1 through 2 ce_pixel cycles.
// Returns {R, G, B} sampled after the second stage.
// ---------------------------------------------------------------------------
static void pixel_lookup(int idx, int mode12,
                          uint8_t& out_r, uint8_t& out_g, uint8_t& out_b) {
    // Stage 0: address BRAM
    dut->src_pal    = (uint16_t)(idx & 0x1FFF);
    dut->mode_12bit = (uint8_t)(mode12 & 1);
    dut->pixel_valid = 1;
    pixel_tick();

    // Stage 1: BRAM output registered (pal_rd_data)
    dut->pixel_valid = 1;
    pixel_tick();

    // Stage 2: RGB output registered — sample here
    dut->pixel_valid = 0;
    // Do NOT clock another ce_pixel — video_r/g/b are already registered
    // from the rising edge of the second pixel_tick above.
    out_r = dut->video_r;
    out_g = dut->video_g;
    out_b = dut->video_b;
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
    char line[512];
    while (fgets(line, sizeof(line), fp)) {
        std::string s(line);
        if (s.empty() || s[0] == '#') continue;
        Vec v;
        v.op         = jstr(s, "op");
        v.addr       = (int)jint(s, "addr");
        v.data       = (uint32_t)jint(s, "data");
        v.be         = (int)jint(s, "be", 0xF);
        v.mode_12bit = (int)jint(s, "mode_12bit", 0);
        v.exp_r      = (int)jint(s, "exp_r");
        v.exp_g      = (int)jint(s, "exp_g");
        v.exp_b      = (int)jint(s, "exp_b");
        v.exp_data   = (uint32_t)jint(s, "exp_data");
        v.note       = jstr(s, "note");
        vecs.push_back(v);
    }
    fclose(fp);
    printf("Loaded %zu test vectors\n", vecs.size());

    Verilated::commandArgs(argc, argv);
    dut = new Vtc0650fda;

    int pass = 0, fail = 0;

    // ────────────────────────────────────────────────────────────────────────
    // Test 0 — Reset state
    // After reset: video_r/g/b must be 0; cpu_dtack_n must be 0.
    // ────────────────────────────────────────────────────────────────────────
    reset_dut();
    {
        bool ok = (dut->video_r == 0) && (dut->video_g == 0) && (dut->video_b == 0)
                  && (dut->cpu_dtack_n == 0);
        if (ok) {
            ++pass;
            printf("PASS [reset] video=0x%02X%02X%02X dtack_n=%d\n",
                   dut->video_r, dut->video_g, dut->video_b, dut->cpu_dtack_n);
        } else {
            ++fail;
            printf("FAIL [reset] video=0x%02X%02X%02X dtack_n=%d (expected 0x000000, dtack=0)\n",
                   dut->video_r, dut->video_g, dut->video_b, dut->cpu_dtack_n);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Test 1 — cpu_dtack_n is always 0 regardless of cpu_cs
    // ────────────────────────────────────────────────────────────────────────
    dut->cpu_cs = 1; tick();
    if (dut->cpu_dtack_n == 0) { ++pass; }
    else { ++fail; printf("FAIL [dtack_n cs=1] expected 0 got %d\n", dut->cpu_dtack_n); }
    dut->cpu_cs = 0; tick();
    if (dut->cpu_dtack_n == 0) { ++pass; }
    else { ++fail; printf("FAIL [dtack_n cs=0] expected 0 got %d\n", dut->cpu_dtack_n); }

    // ────────────────────────────────────────────────────────────────────────
    // Main vector loop
    // ────────────────────────────────────────────────────────────────────────
    for (size_t vi = 0; vi < vecs.size(); vi++) {
        const Vec& v = vecs[vi];

        if (v.op == "write") {
            cpu_write(v.addr, v.data, v.be);
            idle();   // one idle before next op
            ++pass;   // writes are unconditionally accepted (checked by readback/lookup)

        } else if (v.op == "readback") {
            uint32_t got = cpu_readback(v.addr);
            idle();
            bool ok = (got == v.exp_data);
            if (ok) { ++pass; }
            else {
                ++fail;
                printf("FAIL [%zu] readback %s\n  addr=0x%04X got=0x%08X exp=0x%08X\n",
                       vi, v.note.c_str(), v.addr, got, v.exp_data);
            }

        } else if (v.op == "lookup") {
            uint8_t r = 0, g = 0, b = 0;
            pixel_lookup(v.addr, v.mode_12bit, r, g, b);
            idle();
            bool ok = (r == (uint8_t)v.exp_r) && (g == (uint8_t)v.exp_g)
                      && (b == (uint8_t)v.exp_b);
            if (ok) { ++pass; }
            else {
                ++fail;
                printf("FAIL [%zu] lookup %s\n"
                       "  addr=0x%04X mode12=%d\n"
                       "  R: got=0x%02X exp=0x%02X\n"
                       "  G: got=0x%02X exp=0x%02X\n"
                       "  B: got=0x%02X exp=0x%02X\n",
                       vi, v.note.c_str(), v.addr, v.mode_12bit,
                       r, (uint8_t)v.exp_r,
                       g, (uint8_t)v.exp_g,
                       b, (uint8_t)v.exp_b);
            }
        }
        // Unknown ops silently skipped
    }

    // ────────────────────────────────────────────────────────────────────────
    // Inline test: pixel_valid = 0 — video_r/g/b hold last value
    // ────────────────────────────────────────────────────────────────────────
    {
        // Write a known color to address 0x0500
        cpu_write(0x0500, 0x00ABCDEF, 0xF);
        idle();

        // Lookup to latch the color (2 pixel ticks)
        uint8_t r = 0, g = 0, b = 0;
        pixel_lookup(0x0500, 0, r, g, b);
        bool initial_ok = (r == 0xAB) && (g == 0xCD) && (b == 0xEF);

        // Now drive pixel_valid=0 with a different index for 4 ticks
        // video output must not change
        for (int i = 0; i < 4; i++) {
            dut->src_pal     = 0x0000;   // different index (palette[0] has unknown value)
            dut->pixel_valid = 0;
            pixel_tick();
        }

        uint8_t hr = dut->video_r, hg = dut->video_g, hb = dut->video_b;
        bool hold_ok = (hr == 0xAB) && (hg == 0xCD) && (hb == 0xEF);

        if (initial_ok && hold_ok) {
            ++pass;
            printf("PASS [pixel_valid=0 hold] color held 0x%02X%02X%02X\n", hr, hg, hb);
        } else {
            ++fail;
            if (!initial_ok)
                printf("FAIL [pixel_valid hold setup] got 0x%02X%02X%02X exp 0xABCDEF\n",
                       r, g, b);
            if (!hold_ok)
                printf("FAIL [pixel_valid=0 hold] got 0x%02X%02X%02X exp 0xABCDEF\n",
                       hr, hg, hb);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // Inline test: CPU write during active pixel (write to different address)
    // Write to 0x0600 while 0x0601 is being looked up; 0x0601 output must be
    // unaffected.
    // ────────────────────────────────────────────────────────────────────────
    {
        // Pre-write known values to both addresses
        cpu_write(0x0600, 0x00112233, 0xF);
        cpu_write(0x0601, 0x00445566, 0xF);
        idle(); idle();

        // Stage 0: address BRAM for 0x0601, simultaneously write to 0x0600
        dut->src_pal     = 0x0601;
        dut->pixel_valid = 1;
        dut->mode_12bit  = 0;
        // Drive CPU write to 0x0600 in same cycle (different address)
        dut->cpu_cs   = 1;
        dut->cpu_we   = 1;
        dut->cpu_addr = 0x0600;
        dut->cpu_din  = 0x00FFFFFF;  // overwrite 0x0600 with white
        dut->cpu_be   = 0xF;
        dut->ce_pixel = 1;
        tick();
        dut->ce_pixel = 0;
        dut->cpu_cs   = 0;
        dut->cpu_we   = 0;

        // Stage 1: pal_rd_data registered
        dut->pixel_valid = 1;
        pixel_tick();

        // Stage 2: video output registered — sample
        dut->pixel_valid = 0;
        uint8_t r = dut->video_r, g = dut->video_g, b = dut->video_b;

        // 0x0601 must have R=0x44 G=0x55 B=0x66 (the original write, not contaminated)
        bool ok = (r == 0x44) && (g == 0x55) && (b == 0x66);
        if (ok) {
            ++pass;
            printf("PASS [cpu_write_during_active_pixel] 0x0601=0x%02X%02X%02X correct\n",
                   r, g, b);
        } else {
            ++fail;
            printf("FAIL [cpu_write_during_active_pixel] got 0x%02X%02X%02X exp 0x445566\n",
                   r, g, b);
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
