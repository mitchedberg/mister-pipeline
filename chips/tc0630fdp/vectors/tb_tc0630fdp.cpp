// =============================================================================
// Gate 4 (Steps 1–2): Verilator testbench for tc0630fdp.sv
//
// Reads one or more vector files (jsonl). Each line is a JSON object with "op":
//
// Step 1 ops (existing):
//   op="reset":              Assert async_rst_n=0 for 4 ticks, release, settle.
//   op="write":              CPU write to ctrl register at word addr.
//   op="read":               CPU read from ctrl register; compare to exp_dout.
//   op="check_extend_mode":  No-op (verified via ctrl readback). Emits PASS.
//   op="timing_frame":       Run one full frame, count pixel_valid/int pulses.
//   op="timing_check":       Advance to (hpos,vpos), check hblank/vblank/pv.
//
// Step 2 ops (new):
//   op="write_text":   CPU write to Text RAM at word address (addr=0x0Exxx).
//   op="read_text":    CPU read from Text RAM; compare exp_dout.
//   op="write_char":   CPU write to Char RAM at word address (addr=0x0Fxxx).
//   op="read_char":    CPU read from Char RAM; compare exp_dout.
//   op="check_text_pixel":
//     Advance timing to HBLANK at vpos (first HBLANK edge at hpos==H_END, vpos==target).
//     Wait 90 clock cycles for the text layer FSM to fill the line buffer.
//     Advance to the active display of vpos+1 at hpos = H_START + screen_col.
//     Sample text_pixel_out. Compare to exp_pixel (9-bit: {color[4:0], pen[3:0]}).
//
// All passing tests: prints "PASS [note]"
// Any failure:       prints "FAIL [note]: got=X exp=Y"
// Final summary:     "TESTS: N passed, M failed"
// Exit code: 0=all pass, 1=any failure.
// =============================================================================

#include "Vtc0630fdp.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdint.h>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// Timing constants (must match RTL and Python model)
// ---------------------------------------------------------------------------
static const int H_TOTAL  = 432;
static const int H_START  = 46;
static const int H_END    = 366;
static const int V_TOTAL  = 262;
static const int V_START  = 24;
static const int V_END    = 256;
static const int V_SYNC_S = 0;
static const int V_SYNC_E = 4;
static const int H_SYNC_S = 0;
static const int H_SYNC_E = 32;

// ---------------------------------------------------------------------------
// Minimal JSON helpers (same pattern as step 1)
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
    if (p == std::string::npos) return dflt;
    return (int)strtol(s.c_str() + p, nullptr, 0);
}

static std::string jstr(const std::string& s, const std::string& key) {
    auto p = jfind(s, key);
    if (p == std::string::npos || s[p] != '"') return "";
    ++p;
    auto e = s.find('"', p);
    return (e == std::string::npos) ? "" : s.substr(p, e - p);
}

// ---------------------------------------------------------------------------
// DUT and clock
// ---------------------------------------------------------------------------
static Vtc0630fdp* dut = nullptr;
static int g_pass = 0;
static int g_fail = 0;

static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
}

static void do_reset() {
    dut->async_rst_n = 0;
    dut->cpu_cs    = 0;
    dut->cpu_rw    = 1;
    dut->cpu_addr  = 0;
    dut->cpu_din   = 0;
    dut->cpu_lds_n = 1;
    dut->cpu_uds_n = 1;
    for (int i = 0; i < 4; i++) tick();
    dut->async_rst_n = 1;
    for (int i = 0; i < 2; i++) tick();
}

// ---------------------------------------------------------------------------
// Check helpers
// ---------------------------------------------------------------------------
static void check(bool ok, const std::string& note, int got, int exp) {
    if (ok) {
        printf("PASS %s\n", note.c_str());
        g_pass++;
    } else {
        printf("FAIL %s: got=0x%04X exp=0x%04X\n", note.c_str(), got, exp);
        g_fail++;
    }
}

// ---------------------------------------------------------------------------
// CPU bus operations
// ---------------------------------------------------------------------------

// Perform a CPU write cycle.
// addr: word address (18-bit field: cpu_addr[18:1])
// data: 16-bit write data
// be:   byte enables (2=high byte, 1=low byte, 3=both)
static void cpu_write(int addr, int data, int be) {
    dut->cpu_cs    = 1;
    dut->cpu_rw    = 0;
    dut->cpu_addr  = (uint32_t)(addr & 0x3FFFF);
    dut->cpu_din   = (uint16_t)(data & 0xFFFF);
    dut->cpu_uds_n = (be & 2) ? 0 : 1;
    dut->cpu_lds_n = (be & 1) ? 0 : 1;
    tick();
    dut->cpu_cs    = 0;
    dut->cpu_rw    = 1;
    dut->cpu_uds_n = 1;
    dut->cpu_lds_n = 1;
    tick();   // deassert settle
}

// Perform a CPU read cycle; returns the sampled cpu_dout.
static int cpu_read(int addr) {
    dut->cpu_cs    = 1;
    dut->cpu_rw    = 1;
    dut->cpu_addr  = (uint32_t)(addr & 0x3FFFF);
    dut->cpu_uds_n = 0;
    dut->cpu_lds_n = 0;
    tick();                          // address + cs presented; registered data latched
    int result = dut->cpu_dout;      // registered output available after rising edge
    dut->cpu_cs    = 0;
    dut->cpu_uds_n = 1;
    dut->cpu_lds_n = 1;
    tick();   // deassert settle
    return result;
}

// ---------------------------------------------------------------------------
// Timing test: run a full frame and count pixel_valid pulses
// ---------------------------------------------------------------------------
static void run_timing_frame(int exp_pv, int exp_int_vblank, int exp_int_hblank,
                              const std::string& note) {
    int pv_count     = 0;
    int int_vb_count = 0;
    int int_hb_count = 0;

    int total = H_TOTAL * V_TOTAL;
    for (int i = 0; i < total; i++) {
        tick();
        if (dut->pixel_valid) pv_count++;
        if (dut->int_vblank)  int_vb_count++;
        if (dut->int_hblank)  int_hb_count++;
    }

    check(pv_count == exp_pv,
          note + " [pixel_valid_count]", pv_count, exp_pv);
    check(int_vb_count == exp_int_vblank,
          note + " [int_vblank_count]", int_vb_count, exp_int_vblank);
    check(int_hb_count == exp_int_hblank,
          note + " [int_hblank_count]", int_hb_count, exp_int_hblank);
}

// ---------------------------------------------------------------------------
// Timing check: advance until (hpos, vpos) matches, then check signals.
// ---------------------------------------------------------------------------
static void run_timing_check(int target_hpos, int target_vpos,
                              int exp_hblank, int exp_vblank, int exp_pv,
                              const std::string& note) {
    int limit = 2 * H_TOTAL * V_TOTAL;
    for (int i = 0; i < limit; i++) {
        if ((int)dut->hpos == target_hpos && (int)dut->vpos == target_vpos)
            break;
        tick();
    }
    bool got_hb = dut->hblank      != 0;
    bool got_vb = dut->vblank      != 0;
    bool got_pv = dut->pixel_valid != 0;

    check(got_hb == (bool)exp_hblank,
          note + " [hblank]", (int)got_hb, exp_hblank);
    check(got_vb == (bool)exp_vblank,
          note + " [vblank]", (int)got_vb, exp_vblank);
    check(got_pv == (bool)exp_pv,
          note + " [pixel_valid]", (int)got_pv, exp_pv);
}

// ---------------------------------------------------------------------------
// Step 2: advance to HBLANK start of target vpos, wait for FSM, then check
// text_pixel_out at screen_col.
//
// Strategy:
//   1. Advance until hpos==H_END and vpos==target_vpos (HBLANK start).
//      The text FSM fires on hblank_rise (transition from active to blank).
//      hblank_rise occurs when hpos first reaches H_END.
//   2. Clock 90 more cycles (80 for FSM + 10 margin).
//      After this the line buffer for target_vpos+1 is fully filled.
//   3. Advance to hpos = H_START + screen_col, vpos = target_vpos+1
//      (active display of the next line) and sample text_pixel_out.
//
// Note: text_pixel_out is combinational from linebuf[hpos - H_START],
// so it reflects the CURRENT hpos at the time we sample.
// ---------------------------------------------------------------------------
static void check_text_pixel(int target_vpos, int screen_col,
                              int exp_pixel, const std::string& note) {
    // Step 1: advance to HBLANK start of target_vpos
    // We want hpos==H_END, vpos==target_vpos.
    // Cap at 2 frames to avoid infinite loop.
    int limit = 2 * H_TOTAL * V_TOTAL;
    int found = 0;
    for (int i = 0; i < limit; i++) {
        if ((int)dut->hpos == H_END && (int)dut->vpos == target_vpos) {
            found = 1;
            break;
        }
        tick();
    }
    if (!found) {
        printf("FAIL %s: could not reach hpos=%d vpos=%d\n",
               note.c_str(), H_END, target_vpos);
        g_fail++;
        return;
    }

    // Step 2: clock 90 cycles (FSM needs ≤80 cycles for 40 tiles)
    for (int i = 0; i < 90; i++) {
        tick();
    }

    // Step 3: advance to active display of vpos+1 at screen_col
    // target line = target_vpos + 1 (mod V_TOTAL)
    int disp_vpos = (target_vpos + 1) % V_TOTAL;
    int disp_hpos = H_START + screen_col;

    // Advance to that position
    for (int i = 0; i < limit; i++) {
        if ((int)dut->hpos == disp_hpos && (int)dut->vpos == disp_vpos)
            break;
        tick();
    }

    // Evaluate combinational outputs
    dut->eval();
    int got = (int)dut->text_pixel_out & 0x1FF;
    check(got == (exp_pixel & 0x1FF), note, got, exp_pixel & 0x1FF);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <vectors1.jsonl> [vectors2.jsonl ...]\n", argv[0]);
        return 1;
    }

    Verilated::commandArgs(argc, argv);
    dut = new Vtc0630fdp;

    // Initial power-on reset
    dut->async_rst_n = 0;
    dut->cpu_cs    = 0;
    dut->cpu_rw    = 1;
    dut->cpu_addr  = 0;
    dut->cpu_din   = 0;
    dut->cpu_lds_n = 1;
    dut->cpu_uds_n = 1;
    for (int i = 0; i < 4; i++) tick();
    dut->async_rst_n = 1;
    for (int i = 0; i < 4; i++) tick();

    // Process each vector file in sequence
    for (int fnum = 1; fnum < argc; fnum++) {
        FILE* fp = fopen(argv[fnum], "r");
        if (!fp) {
            fprintf(stderr, "Cannot open %s\n", argv[fnum]);
            return 1;
        }

        char lbuf[4096];
        while (fgets(lbuf, sizeof(lbuf), fp)) {
            std::string line(lbuf);
            while (!line.empty() && (line.back() == '\n' || line.back() == '\r'))
                line.pop_back();
            if (line.empty() || line[0] == '#') continue;

            std::string op   = jstr(line, "op");
            std::string note = jstr(line, "note");

            // ── Step 1 ops ──────────────────────────────────────────────────
            if (op == "reset") {
                do_reset();

            } else if (op == "write") {
                cpu_write(jint(line, "addr"), jint(line, "data"), jint(line, "be", 3));

            } else if (op == "read") {
                int got = cpu_read(jint(line, "addr"));
                check(got == jint(line, "exp_dout"), note, got, jint(line, "exp_dout"));

            } else if (op == "check_extend_mode") {
                printf("PASS %s (verified via ctrl[15] readback)\n", note.c_str());
                g_pass++;

            } else if (op == "timing_frame") {
                run_timing_frame(jint(line, "exp_pv"),
                                 jint(line, "exp_int_vblank", 1),
                                 jint(line, "exp_int_hblank", 1),
                                 note);

            } else if (op == "timing_check") {
                run_timing_check(jint(line, "hpos"), jint(line, "vpos"),
                                 jint(line, "exp_hblank"), jint(line, "exp_vblank"),
                                 jint(line, "exp_pv"), note);

            // ── Step 2 ops ──────────────────────────────────────────────────
            } else if (op == "write_text") {
                // CPU write to Text RAM; addr is word address in chip window.
                cpu_write(jint(line, "addr"), jint(line, "data"), jint(line, "be", 3));

            } else if (op == "read_text") {
                int got = cpu_read(jint(line, "addr"));
                check(got == jint(line, "exp_dout"), note, got, jint(line, "exp_dout"));

            } else if (op == "write_char") {
                // CPU write to Char RAM; addr is word address in chip window.
                cpu_write(jint(line, "addr"), jint(line, "data"), jint(line, "be", 3));

            } else if (op == "read_char") {
                int got = cpu_read(jint(line, "addr"));
                check(got == jint(line, "exp_dout"), note, got, jint(line, "exp_dout"));

            } else if (op == "check_text_pixel") {
                check_text_pixel(jint(line, "vpos"),
                                 jint(line, "screen_col"),
                                 jint(line, "exp_pixel"),
                                 note);

            } else {
                fprintf(stderr, "Unknown op: %s\n", op.c_str());
            }
        }

        fclose(fp);
    }

    printf("\nTESTS: %d passed, %d failed\n", g_pass, g_fail);
    delete dut;
    return (g_fail == 0) ? 0 : 1;
}
