// =============================================================================
// Gate 4: Verilator testbench for tc0360pri.sv
//
// Reads tier1_vectors.jsonl. Each line:
//   {"regs": [16 bytes], "in0": N, "in1": N, "in2": N,
//    "exp_out": N, "note": "..."}
//
// Per-vector sequence:
//   ticks 0..15: write each register byte via CPU bus
//   tick 16:     deassert cpu_cs, present color_in0/1/2
//   tick 17:     sample color_out (combinational, registered one tick later)
// =============================================================================

#include "Vtc0360pri.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdint.h>
#include <vector>
#include <string>

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
// Parse JSON array of integers: "regs": [a, b, ...]
static std::vector<int> jarray(const std::string& s, const std::string& key) {
    std::vector<int> v;
    auto p = jfind(s, key);
    if (p == std::string::npos || s[p] != '[') return v;
    ++p;
    while (p < s.size() && s[p] != ']') {
        while (p < s.size() && (s[p]==' '||s[p]==',')) ++p;
        if (s[p] == ']') break;
        v.push_back((int)strtol(s.c_str()+p, nullptr, 0));
        while (p < s.size() && s[p]!=',' && s[p]!=']') ++p;
    }
    return v;
}

// ---------------------------------------------------------------------------
struct Vec {
    int regs[16];
    int in0, in1, in2;
    int exp_out;
    std::string note;
};

static Vtc0360pri* dut = nullptr;
static void tick() { dut->clk=0; dut->eval(); dut->clk=1; dut->eval(); }

static void reset() {
    dut->async_rst_n = 0;
    dut->cpu_cs = 0; dut->cpu_we = 0;
    dut->cpu_addr = 0; dut->cpu_din = 0;
    dut->color_in0 = dut->color_in1 = dut->color_in2 = 0;
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
        auto arr = jarray(s, "regs");
        for (int i=0; i<16 && i<(int)arr.size(); i++) v.regs[i] = arr[i];
        v.in0 = jint(s,"in0"); v.in1 = jint(s,"in1"); v.in2 = jint(s,"in2");
        v.exp_out = jint(s,"exp_out");
        v.note = jstr(s,"note");
        vecs.push_back(v);
    }
    fclose(fp);
    printf("Loaded %zu vectors\n", vecs.size());

    Verilated::commandArgs(argc, argv);
    dut = new Vtc0360pri;
    int pass=0, fail=0;

    reset();

    // ── Reset state: all outputs should be 0
    {
        bool ok = (dut->color_out == 0) && (dut->cpu_dout == 0);
        if (ok) ++pass;
        else { ++fail; printf("FAIL [reset] color_out=%u cpu_dout=%u\n", dut->color_out, dut->cpu_dout); }
    }

    for (size_t vi=0; vi<vecs.size(); vi++) {
        const Vec& v = vecs[vi];

        // Write all 16 register bytes
        for (int i=0; i<16; i++) {
            dut->cpu_cs=1; dut->cpu_we=1;
            dut->cpu_addr = (uint8_t)i;
            dut->cpu_din  = (uint8_t)v.regs[i];
            tick();
        }
        // Deassert CPU bus, present color inputs
        dut->cpu_cs=0; dut->cpu_we=0;
        dut->color_in0 = (uint16_t)(v.in0 & 0x7FFF);
        dut->color_in1 = (uint16_t)(v.in1 & 0x7FFF);
        dut->color_in2 = (uint16_t)(v.in2 & 0x7FFF);
        tick();   // combinational output settles

        int got = (int)dut->color_out;
        if (got == v.exp_out) {
            ++pass;
        } else {
            ++fail;
            printf("FAIL [%zu] %s\n  in0=0x%04X in1=0x%04X in2=0x%04X\n"
                   "  got=0x%04X exp=0x%04X\n"
                   "  regs: %02X %02X %02X %02X | %02X %02X %02X %02X | %02X %02X\n",
                   vi, v.note.c_str(), v.in0, v.in1, v.in2, got, v.exp_out,
                   v.regs[0],v.regs[1],v.regs[2],v.regs[3],
                   v.regs[4],v.regs[5],v.regs[6],v.regs[7],
                   v.regs[8],v.regs[9]);
        }
    }

    printf("\n%s: %d/%d tests passed\n", (fail==0)?"PASS":"FAIL", pass, pass+fail);
    delete dut;
    return (fail==0) ? 0 : 1;
}
