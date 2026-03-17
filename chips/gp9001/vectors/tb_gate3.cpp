// =============================================================================
// GP9001 Gate 3 — Verilator testbench
//
// Reads gate3_vectors.jsonl and drives the gp9001 DUT.
//
// Supported op codes (all Gate 1 + Gate 2 ops, plus Gate 3 additions):
//
// Gate 1 ops (subset used in gate3 tests):
//   reset
//   vsync_pulse
//
// Gate 3 ops:
//   vram_sel        layer                  — write VRAM_SEL register (reg 0x0F)
//   write_vram      addr, data             — write VRAM word (addr[9:0] within layer)
//   read_vram       addr, exp              — read VRAM, check 1-cycle-later result
//   write_scroll    layer, axis, data      — write scroll reg + vsync_pulse to stage
//   write_rom_byte  addr, data             — write tile ROM byte in testbench memory
//   set_pixel       hpos, vpos, hblank, vblank  — drive pixel coords
//   clock_n         n                      — advance n clock cycles
//   check_bg_valid  layer, exp             — check bg_pix_valid[layer]
//   check_bg_color  layer, exp             — check bg_pix_color[layer]
//   check_bg_prio   layer, exp             — check bg_pix_priority[layer]
//
// Tile ROM model:
//   The testbench holds a 1MB ROM array.
//   bg_rom_data is driven combinationally (zero latency): after each clk eval,
//   we look up tile_rom[bg_rom_addr] and set bg_rom_data before the next eval.
//   Because both Stage-1 and Stage-2 are clocked, and bg_rom_data is consumed
//   combinationally in Stage-2 (which feeds into the output FF), the correct
//   driving method is:
//     - After each posedge: latch bg_rom_addr from DUT, look up ROM, set bg_rom_data
//     - The posedge eval already used the OLD bg_rom_data (from previous cycle)
//     - But we call eval() again with the new bg_rom_data to settle combinational
//       paths for the NEXT stage.
//   In practice: set bg_rom_data = tile_rom[bg_rom_addr] between clk=0 and clk=1.
//   This models "combinational ROM" where data is available in the same cycle as addr.
//
// IMPORTANT: Do NOT include Vgp9001_gp9001.h — only Vgp9001.h + verilated.h
//
// Exit: 0 = all pass, 1 = any failure.
// =============================================================================

#include "Vgp9001.h"
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
    Vgp9001*             top;
    uint64_t             cycle;
    int                  failures;
    int                  checks;

    // Tile ROM: 1MB, 4bpp packed (2 pixels/byte)
    static const int TILE_ROM_SIZE = 1 << 20;
    std::vector<uint8_t> tile_rom;

    // Saved vram read result (latched one cycle after request)
    uint16_t vram_read_result;
    bool     vram_read_pending;
    int      vram_read_exp;

    DUT() : cycle(0), failures(0), checks(0),
            vram_read_result(0), vram_read_pending(false), vram_read_exp(0) {
        top = new Vgp9001();
        tile_rom.assign(TILE_ROM_SIZE, 0);
        reset_inputs();
        reset();
    }

    ~DUT() {
        top->final();
        delete top;
    }

    void reset_inputs() {
        top->rst_n     = 0;
        top->cs_n      = 1;
        top->rd_n      = 1;
        top->wr_n      = 1;
        top->addr      = 0;
        top->din       = 0;
        top->vsync     = 0;
        top->vblank    = 0;
        top->scan_addr = 0;
        top->hpos      = 0;
        top->vpos      = 0;
        top->hblank    = 0;
        top->vblank_in = 0;
        top->bg_rom_data = 0;
    }

    // Tick one clock, driving bg_rom_data combinationally from ROM lookup.
    // The model:
    //   clk=0 (negedge): eval, settle combinational inputs
    //   update bg_rom_data from current bg_rom_addr
    //   clk=1 (posedge): eval, FFs sample updated bg_rom_data
    void clk_tick(int n = 1) {
        for (int i = 0; i < n; i++) {
            top->clk = 0;
            top->eval();
            // Drive ROM data combinationally based on current address
            uint32_t rom_addr = top->bg_rom_addr & 0xFFFFF;
            top->bg_rom_data  = tile_rom[rom_addr];
            top->clk = 1;
            top->eval();
            ++cycle;
        }
    }

    void reset() {
        reset_inputs();
        clk_tick(4);
        top->rst_n = 1;
        clk_tick(4);
    }

    // ── Control register write ────────────────────────────────────────────
    void write_reg(int addr_offset, int data) {
        top->addr = (uint32_t)(addr_offset & 0x3FF);  // addr[9:0], addr[10]=0
        top->din  = (uint16_t)(data & 0xFFFF);
        top->cs_n = 0;
        top->wr_n = 0;
        top->rd_n = 1;
        clk_tick(1);
        top->cs_n = 1;
        top->wr_n = 1;
        clk_tick(1);
    }

    // ── VRAM write (addr[10]=1) ───────────────────────────────────────────
    void write_vram(int vram_word_addr, int data) {
        // addr[10]=1, addr[9:0]=vram_word_addr[9:0]
        top->addr = (uint32_t)(0x400 | (vram_word_addr & 0x3FF));
        top->din  = (uint16_t)(data & 0xFFFF);
        top->cs_n = 0;
        top->wr_n = 0;
        top->rd_n = 1;
        clk_tick(1);
        top->cs_n = 1;
        top->wr_n = 1;
        clk_tick(1);
    }

    // ── VRAM read (registered, 1-cycle latency) ───────────────────────────
    // Returns the value captured in vram_dout after the read cycle.
    uint16_t read_vram(int vram_word_addr) {
        top->addr = (uint32_t)(0x400 | (vram_word_addr & 0x3FF));
        top->cs_n = 0;
        top->rd_n = 0;
        top->wr_n = 1;
        clk_tick(2);  // request + latch
        uint16_t d = (uint16_t)top->vram_dout;
        top->cs_n = 1;
        top->rd_n = 1;
        clk_tick(1);
        return d;
    }

    // ── vsync pulse (shadow→active staging) ──────────────────────────────
    void vsync_pulse() {
        top->vsync = 1;
        clk_tick(2);
        top->vsync = 0;
        clk_tick(2);
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

    // ── BG pixel output accessors ─────────────────────────────────────────
    int get_bg_pix_valid(int layer) {
        return (int)((top->bg_pix_valid >> layer) & 1);
    }

    int get_bg_pix_color(int layer) {
        return (int)(uint8_t)top->bg_pix_color[layer];
    }

    int get_bg_pix_priority(int layer) {
        return (int)top->bg_pix_priority[layer];
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
        int addr_val    = jint(line, "addr",   0);
        int data_val    = jint(line, "data",   0);
        int exp_val     = jint(line, "exp",    0);
        int layer_val   = jint(line, "layer",  0);

        if (op == "reset") {
            dut.reset();

        } else if (op == "vsync_pulse") {
            dut.vsync_pulse();

        } else if (op == "vram_sel") {
            // Write VRAM_SEL register (reg 0x0F, addr[9:8]=00, addr[3:0]=F)
            dut.write_reg(0x0F, layer_val & 0x3);

        } else if (op == "write_vram") {
            dut.write_vram(addr_val, data_val);

        } else if (op == "read_vram") {
            uint16_t got = dut.read_vram(addr_val);
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "vram_read[%d]", addr_val);
            dut.check(lbl, got, exp_val);

        } else if (op == "write_scroll") {
            // Write scroll register and pulse vsync to stage it.
            // Scroll regs: SCROLL_X for layer L = reg 0x00 + L*2
            //              SCROLL_Y for layer L = reg 0x01 + L*2
            std::string axis = jstr(line, "axis");
            int reg_offset = layer_val * 2 + (axis == "y" ? 1 : 0);
            dut.write_reg(reg_offset, data_val);
            dut.vsync_pulse();

        } else if (op == "write_rom_byte") {
            // Write into testbench tile ROM
            uint32_t rom_addr = (uint32_t)(addr_val) & 0xFFFFF;
            dut.tile_rom[rom_addr] = (uint8_t)(data_val & 0xFF);

        } else if (op == "set_pixel") {
            int hpos_v  = jint(line, "hpos",   0);
            int vpos_v  = jint(line, "vpos",   0);
            int hblank_v = jint(line, "hblank", 0);
            int vblank_v = jint(line, "vblank", 0);
            dut.top->hpos      = (uint16_t)(hpos_v & 0x1FF);
            dut.top->vpos      = (uint16_t)(vpos_v & 0x1FF);
            dut.top->hblank    = (uint8_t)(hblank_v & 1);
            dut.top->vblank_in = (uint8_t)(vblank_v & 1);

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

        } else if (op == "check_bg_prio") {
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "bg_pix_priority[%d]", layer_val);
            dut.check(lbl, dut.get_bg_pix_priority(layer_val), exp_val);

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

    if (dut.failures > 0 || err) {
        fprintf(stderr, "FAIL\n");
        return 1;
    }
    fprintf(stderr, "PASS\n");
    return 0;
}
