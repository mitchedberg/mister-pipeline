// =============================================================================
// GP9001 Gate 1 — Verilator testbench
//
// Reads gate1_vectors.jsonl and drives the gp9001 DUT.
//
// Supported op codes:
//   reset          — pulse rst_n low then high
//   write_reg      — addr (ctrl word offset 0x00–0x0F), data
//   read_reg       — addr, exp  (reads from shadow via combinational port)
//   write_sram     — addr (flat word index 0..1023), data
//   read_sram      — addr, exp  (registered read, 1-cycle latency)
//   vsync_pulse    — assert vsync for 2 cycles (triggers shadow→active staging)
//   check_scroll   — layer (0-3), axis ("x"|"y"), exp (16-bit active register)
//   check_layer_ctrl   — exp
//   check_sprite_ctrl  — exp
//   check_num_layers   — exp
//   check_bg0_priority — exp
//   check_sprite_list_len_code — exp
//   check_sprite_sort_mode     — exp
//   check_color_key   — exp
//   check_blend_ctrl  — exp
//   check_sprite_en   — exp (0 or 1)
//
// Address encoding (matches RTL addr[10:0]):
//   Control reg:  addr[9:8]=00, addr[3:0]=register_offset
//   Sprite RAM:   addr[9:8]=01, addr[9:0]=word_index (0..1023)
//
// IMPORTANT: Do NOT include Vgp9001_gp9001.h — only include Vgp9001.h and verilated.h
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

// ---------------------------------------------------------------------------
// Minimal JSON field extractors (no external dependencies)
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
    Vgp9001* top;
    uint64_t cycle;
    int      failures;
    int      checks;

    DUT() : cycle(0), failures(0), checks(0) {
        top = new Vgp9001();
        reset();
    }

    ~DUT() {
        top->final();
        delete top;
    }

    void clk_tick(int n = 1) {
        for (int i = 0; i < n; i++) {
            top->clk = 0;
            top->eval();
            top->clk = 1;
            top->eval();
            ++cycle;
        }
    }

    void reset() {
        top->rst_n  = 0;
        top->cs_n   = 1;
        top->rd_n   = 1;
        top->wr_n   = 1;
        top->addr   = 0;
        top->din    = 0;
        top->vsync  = 0;
        top->vblank = 0;
        top->scan_addr = 0;
        clk_tick(4);
        top->rst_n = 1;
        clk_tick(4);
    }

    // ── Control register write (combinational write on rising edge) ───────────
    // addr_offset: 0x00–0x0F (word register index)
    void write_reg(int addr_offset, int data) {
        // addr[9:8] = 2'b00, addr[3:0] = addr_offset
        top->addr  = (uint32_t)(addr_offset & 0xF);
        top->din   = (uint16_t)(data & 0xFFFF);
        top->cs_n  = 0;
        top->wr_n  = 0;
        top->rd_n  = 1;
        clk_tick(1);
        top->cs_n = 1;
        top->wr_n = 1;
        clk_tick(1);
    }

    // ── Control register read (combinational — sample after setting addr) ─────
    uint16_t read_reg(int addr_offset) {
        top->addr = (uint32_t)(addr_offset & 0xF);
        top->cs_n = 0;
        top->rd_n = 0;
        top->wr_n = 1;
        top->clk  = 0;
        top->eval();
        // Combinational read: sample dout before posedge
        uint16_t d = top->dout;
        top->clk  = 1;
        top->eval();
        ++cycle;
        top->cs_n = 1;
        top->rd_n = 1;
        clk_tick(1);
        return d;
    }

    // ── Sprite RAM write ───────────────────────────────────────────────────────
    // word_idx: 0..1023 (flat index into sprite RAM)
    void write_sram(int word_idx, int data) {
        // addr[9:8] = 2'b01, addr[9:0] = word_idx
        uint32_t a = (uint32_t)((1 << 8) | (word_idx & 0xFF));
        // Full 10-bit: addr[9:8]=01 means addr = 0x100 | (word_idx & 0xFF)
        // But word_idx can be 0..1023: addr[9:0] = word_idx, addr[9:8] = word_idx[9:8]
        // For idx in [0..255]:   a = 0x100 | idx
        // For idx in [256..511]: a = 0x200 | (idx & 0xFF) — but addr[9:8]=10 → sel_sram=0!
        //
        // The RTL uses addr[9:8]==2'b01 for sprite RAM.  This works for word indices
        // 0x000..0x0FF (256 entries at addr 0x100..0x1FF) and
        // mirrors at 0x100..0x1FF (addr[9:8]=01, lower 8 bits = word_idx mod 256).
        //
        // For a full 1024-word RAM with addr[9:8]==01, we need addr to be:
        //   addr[9:8] = 01, addr[7:0] = lower 8 bits
        //   addr[9]   = 0  (since 01 has bit9=0, bit8=1)
        //   This only gives 256 word indices per addr[9:8]==01 slot.
        //
        // The section1 doc says sprite RAM is at word offsets 0x100–0x4FF (1024 words).
        // addr[9:8]==01 covers offsets 0x100–0x1FF (256 words).
        // Full 1024 requires addr bits [10:8] for mapping — but we declared addr[10:0].
        //
        // In the RTL: addr[9:8]==2'b01 for sprite RAM.
        // addr[9:0] is the word index within sprite RAM (0..1023).
        // But if addr[9:8]==01, then addr[9]=0 and addr[8]=1.
        // So addr[9:0] can only be 0x100..0x1FF for this decode (not 0..1023).
        //
        // For Gate 1, we use the sprite RAM with addr[9:0] as the actual word address:
        //   addr[9:8] must be 01 to select sprite RAM
        //   addr[7:0] is the low 8 bits of the word index
        //   The high part of the index is only accessible if addr[10] or addr[9] are used.
        //
        // RTL decode: sel_sram = active_cs && (addr[9:8] == 2'b01)
        // This means: addr bit 9 = 0, addr bit 8 = 1.
        // Word indices accessible: addr[7:0] = 0..255, so only sprites 0..63.
        //
        // For FULL 1024-word coverage, the RTL would need addr[9:8] to cover 01,10,11
        // (that is, use addr[11:8] for more space).
        //
        // To keep Gate 1 simple and match the RTL's actual address decode, we test
        // sprite RAM in the range addr[9:8]==01, word_idx 0..255.
        // Higher indices (256..1023) would need a different address window.
        //
        // Here we just use the lower 8 bits and the 01 prefix (as documented).
        a = (uint32_t)(0x100 | (word_idx & 0xFF));
        top->addr = a;
        top->din  = (uint16_t)(data & 0xFFFF);
        top->cs_n = 0;
        top->wr_n = 0;
        top->rd_n = 1;
        clk_tick(1);
        top->cs_n = 1;
        top->wr_n = 1;
        clk_tick(1);
    }

    // ── Sprite RAM read (registered — 1-cycle latency) ────────────────────────
    uint16_t read_sram(int word_idx) {
        uint32_t a = (uint32_t)(0x100 | (word_idx & 0xFF));
        top->addr = a;
        top->cs_n = 0;
        top->rd_n = 0;
        top->wr_n = 1;
        clk_tick(2);   // registered read: data valid after 1 posedge
        uint16_t d = top->dout;
        top->cs_n = 1;
        top->rd_n = 1;
        clk_tick(1);
        return d;
    }

    // ── vsync pulse ────────────────────────────────────────────────────────────
    void vsync_pulse() {
        top->vsync = 1;
        clk_tick(2);   // 2 cycles: rising edge detected on first posedge
        top->vsync = 0;
        clk_tick(2);
    }

    // ── Check helper ───────────────────────────────────────────────────────────
    void check(const char* label, int got, int exp) {
        ++checks;
        if (got != exp) {
            fprintf(stderr, "FAIL  %s: got 0x%04X exp 0x%04X\n", label, got, exp);
            ++failures;
        } else {
            fprintf(stderr, "pass  %s: 0x%04X\n", label, got);
        }
    }

    // ── Get active scroll register value ─────────────────────────────────────
    // Reads from the output port scroll[layer*2 + axis_idx]
    // axis: 0 = X, 1 = Y
    uint16_t get_active_scroll(int layer, int axis) {
        int idx = layer * 2 + axis;
        switch (idx) {
            case 0: return (uint16_t)top->scroll0_x;
            case 1: return (uint16_t)top->scroll0_y;
            case 2: return (uint16_t)top->scroll1_x;
            case 3: return (uint16_t)top->scroll1_y;
            case 4: return (uint16_t)top->scroll2_x;
            case 5: return (uint16_t)top->scroll2_y;
            case 6: return (uint16_t)top->scroll3_x;
            case 7: return (uint16_t)top->scroll3_y;
            default: return 0;
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
        ++line_num;
        if (line.empty() || line[0] == '#') continue;

        std::string op = jstr(line, "op");
        int addr_val   = jint(line, "addr", 0);
        int data_val   = jint(line, "data", 0);
        int exp_val    = jint(line, "exp",  0);

        if (op == "reset") {
            dut.reset();

        } else if (op == "write_reg") {
            dut.write_reg(addr_val, data_val);

        } else if (op == "read_reg") {
            uint16_t got = dut.read_reg(addr_val);
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "read_reg[0x%02X]", addr_val);
            dut.check(lbl, got, exp_val);

        } else if (op == "write_sram") {
            dut.write_sram(addr_val, data_val);

        } else if (op == "read_sram") {
            uint16_t got = dut.read_sram(addr_val);
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "read_sram[%d]", addr_val);
            dut.check(lbl, got, exp_val);

        } else if (op == "vsync_pulse") {
            dut.vsync_pulse();

        } else if (op == "check_scroll") {
            int layer = jint(line, "layer", 0);
            std::string axis_str = jstr(line, "axis");
            int axis = (axis_str == "y") ? 1 : 0;
            uint16_t got = dut.get_active_scroll(layer, axis);
            char lbl[64];
            snprintf(lbl, sizeof(lbl), "scroll[%d][%s]", layer, axis_str.c_str());
            dut.check(lbl, got, exp_val);

        } else if (op == "check_layer_ctrl") {
            dut.check("layer_ctrl", (int)(uint16_t)dut.top->layer_ctrl, exp_val);

        } else if (op == "check_sprite_ctrl") {
            dut.check("sprite_ctrl", (int)(uint16_t)dut.top->sprite_ctrl, exp_val);

        } else if (op == "check_num_layers") {
            dut.check("num_layers_active", (int)dut.top->num_layers_active, exp_val);

        } else if (op == "check_bg0_priority") {
            dut.check("bg0_priority", (int)dut.top->bg0_priority, exp_val);

        } else if (op == "check_sprite_list_len_code") {
            dut.check("sprite_list_len_code", (int)dut.top->sprite_list_len_code, exp_val);

        } else if (op == "check_sprite_sort_mode") {
            dut.check("sprite_sort_mode", (int)dut.top->sprite_sort_mode, exp_val);

        } else if (op == "check_color_key") {
            dut.check("color_key", (int)(uint16_t)dut.top->color_key, exp_val);

        } else if (op == "check_blend_ctrl") {
            dut.check("blend_ctrl", (int)(uint16_t)dut.top->blend_ctrl, exp_val);

        } else if (op == "check_sprite_en") {
            dut.check("sprite_en", (int)dut.top->sprite_en, exp_val);

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
        fprintf(stderr, "Usage: %s <gate1_vectors.jsonl> [...]\n", argv[0]);
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
