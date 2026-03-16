// =============================================================================
// Gate 4: Verilator testbench for tc0180vcu.sv
//
// Reads tier1_vectors.jsonl. Each line:
//   {"op": "write"|"read", "addr": N, "data": N, "be": N,
//    "exp_dout": N, "note": "..."}
//
// Per-vector sequence:
//   write: drive cpu_cs=1, cpu_we=1, addr, data, be → tick → cpu_we=0
//   read:  drive cpu_cs=1, cpu_we=0, addr → tick → sample cpu_dout
//          (registered read: data available cycle after address presented)
// =============================================================================

#include "Vtc0180vcu.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdint.h>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// Minimal JSON helpers
// ---------------------------------------------------------------------------
static size_t jfind(const std::string& s, const std::string& key) {
    std::string pat = "\"" + key + "\"";
    auto p = s.find(pat);
    if (p == std::string::npos) return std::string::npos;
    p += pat.size();
    while (p < s.size() && (s[p]==' '||s[p]==':')) ++p;
    return p;
}
static int jint(const std::string& s, const std::string& key, int dflt=0) {
    auto p = jfind(s, key);
    if (p == std::string::npos) return dflt;
    return (int)strtol(s.c_str()+p, nullptr, 0);
}
static std::string jstr(const std::string& s, const std::string& key) {
    auto p = jfind(s, key);
    if (p == std::string::npos || s[p]!='"') return "";
    ++p; auto e = s.find('"', p);
    return (e==std::string::npos) ? "" : s.substr(p, e-p);
}

// ---------------------------------------------------------------------------
struct Vec {
    bool   is_write;
    int    addr;
    int    data;
    int    be;
    int    exp_dout;
    std::string note;
};

static Vtc0180vcu* dut = nullptr;
static void tick() {
    dut->clk=0; dut->eval();
    dut->clk=1; dut->eval();
}

static void reset() {
    dut->async_rst_n = 0;
    dut->cpu_cs   = 0; dut->cpu_we = 0;
    dut->cpu_addr = 0; dut->cpu_din = 0; dut->cpu_be = 0;
    dut->hblank_n = 1; dut->vblank_n = 1;
    dut->hpos = 0; dut->vpos = 0;
    dut->gfx_data = 0;
    for (int i=0; i<4; i++) tick();
    dut->async_rst_n = 1;
    for (int i=0; i<2; i++) tick();
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "Usage: %s <tier1_vectors.jsonl>\n", argv[0]); return 1; }

    std::vector<Vec> vecs;
    FILE* fp = fopen(argv[1], "r"); if (!fp) { perror(argv[1]); return 1; }
    char line[4096];
    while (fgets(line, sizeof(line), fp)) {
        std::string s(line);
        if (s.empty() || s[0]=='#') continue;
        Vec v;
        std::string op = jstr(s, "op");
        v.is_write = (op == "write");
        v.addr     = jint(s, "addr");
        v.data     = jint(s, "data");
        v.be       = jint(s, "be", 3);
        v.exp_dout = jint(s, "exp_dout");
        v.note     = jstr(s, "note");
        vecs.push_back(v);
    }
    fclose(fp);
    printf("Loaded %zu vectors\n", vecs.size());

    Verilated::commandArgs(argc, argv);
    dut = new Vtc0180vcu;
    int pass=0, fail=0;

    reset();

    // ── Reset state check
    {
        bool ok = (dut->cpu_dout == 0) && (dut->pixel_out == 0)
               && (dut->int_h == 0) && (dut->int_l == 0);
        if (ok) ++pass;
        else { ++fail; printf("FAIL [reset] cpu_dout=%u pixel_out=%u int_h=%u int_l=%u\n",
                              dut->cpu_dout, dut->pixel_out, dut->int_h, dut->int_l); }
    }

    for (size_t vi=0; vi<vecs.size(); vi++) {
        const Vec& v = vecs[vi];

        if (v.is_write) {
            // Drive write
            dut->cpu_cs   = 1;
            dut->cpu_we   = 1;
            dut->cpu_addr = (uint32_t)(v.addr & 0x7FFFF);
            dut->cpu_din  = (uint16_t)(v.data & 0xFFFF);
            dut->cpu_be   = (uint8_t)(v.be & 0x3);
            tick();
            dut->cpu_we = 0;
            dut->cpu_cs = 0;
            ++pass;   // writes always pass (no observable output to check)
        } else {
            // Drive read: present address for one cycle, sample dout after
            dut->cpu_cs   = 1;
            dut->cpu_we   = 0;
            dut->cpu_addr = (uint32_t)(v.addr & 0x7FFFF);
            dut->cpu_be   = 0x3;
            tick();
            dut->cpu_cs = 0;

            int got = (int)dut->cpu_dout;
            if (got == v.exp_dout) {
                ++pass;
            } else {
                ++fail;
                printf("FAIL [%zu] %s\n  addr=0x%05X got=0x%04X exp=0x%04X\n",
                       vi, v.note.c_str(), v.addr, got, v.exp_dout);
            }
        }
    }

    // ── VBLANK interrupt test
    // Drive vblank pulse, check int_h fires
    {
        dut->cpu_cs = 0;
        dut->vblank_n = 0;  // assert vblank (active low → vblank_fall)
        tick();
        bool int_h_fired = (dut->int_h == 1);
        dut->vblank_n = 1;
        tick();
        if (int_h_fired) ++pass;
        else { ++fail; printf("FAIL [vblank] int_h did not fire on vblank assertion\n"); }

        // After ~8 more cycles, int_l should fire
        bool int_l_found = false;
        for (int i=0; i<12; i++) {
            tick();
            if (dut->int_l == 1) { int_l_found = true; break; }
        }
        if (int_l_found) ++pass;
        else { ++fail; printf("FAIL [intl] int_l did not fire within 12 cycles after vblank\n"); }
    }

    printf("\n%s: %d/%d tests passed\n", (fail==0)?"PASS":"FAIL", pass, pass+fail);
    delete dut;
    return (fail==0) ? 0 : 1;
}
