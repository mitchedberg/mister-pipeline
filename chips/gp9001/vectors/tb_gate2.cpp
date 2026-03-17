// =============================================================================
// GP9001 Gate 2 — Verilator testbench
//
// Reads gate2_vectors.jsonl and drives the gp9001 DUT.
//
// Supported op codes (all Gate 1 ops plus Gate 2 additions):
//
// Gate 1 ops:
//   reset
//   write_reg       addr (0x00–0x0F), data
//   read_reg        addr, exp
//   write_sram      addr (flat word index 0..255), data
//   read_sram       addr, exp
//   vsync_pulse
//   check_scroll    layer, axis ("x"|"y"), exp
//   check_layer_ctrl, check_sprite_ctrl, check_num_layers, check_bg0_priority
//   check_sprite_list_len_code, check_sprite_sort_mode
//   check_color_key, check_blend_ctrl, check_sprite_en
//
// Gate 2 ops:
//   vblank_pulse    scan_max
//       Assert vblank for 1 cycle, then wait scan_max+8 cycles.
//       Tracks whether display_list_ready and irq_sprite pulsed.
//   check_dl_count      exp
//   check_dl_ready_pulse — verify ready was asserted
//   check_irq_pulse      — verify irq_sprite was asserted
//   check_dl_entry  idx, x, y, tile_num, flip_x, flip_y, priority, palette, size, valid
//   check_dl_entry_valid idx, exp (0|1)
//
// Display list is a packed array: sprite_entry_t[256], each 38 bits:
//   [37:29] x (9b) | [28:20] y (9b) | [19:10] tile_num (10b) |
//   [9] flip_x | [8] flip_y | [7] priority | [6:3] palette (4b) |
//   [2:1] size (2b) | [0] valid
//
// Verilator flattens sprite_entry_t display_list[0:255] to a VlWide array.
// 256 entries × 38 bits = 9728 bits = 304 32-bit words.
// Entry i: bits [i*38+37 : i*38+0] in the flat bit vector.
//
// Addressing note:
//   The testbench write_sram uses addr = 0x100 | (word_idx & 0xFF).
//   This writes sram[0x100 + (word_idx & 0xFF)] = sram[256..511].
//   The scanner reads {2'b01, scan_slot[5:0], 2'bNN} = sram[256..511].
//   So flat word index s*4+w (for sprite slot s=0..63, word w=0..3)
//   correctly maps to scanner slot s.
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
// Display list entry
// ---------------------------------------------------------------------------

struct DlEntry {
    int x, y, tile_num;
    int flip_x, flip_y, priority;
    int palette, size, valid;
};

// Unpack one display_list entry.
//
// Verilator declares display_list as QData display_list[256] (uint64_t[256]).
// Each entry holds the 38-bit packed struct value in bits [37:0]:
//
//   sprite_entry_t packed (MSB first in struct packed):
//     bits [37:29] x        (9 bits)
//     bits [28:20] y        (9 bits)
//     bits [19:10] tile_num (10 bits)
//     bit  [9]     flip_x
//     bit  [8]     flip_y
//     bit  [7]     prio     (priority)
//     bits [6:3]   palette  (4 bits)
//     bits [2:1]   size     (2 bits)
//     bit  [0]     valid
static DlEntry get_dl_entry(const Vgp9001* top, int idx) {
    uint64_t val = top->display_list[idx] & ((uint64_t(1) << 38) - 1);

    DlEntry e;
    e.valid    = (int)((val >>  0) & 0x1);
    e.size     = (int)((val >>  1) & 0x3);
    e.palette  = (int)((val >>  3) & 0xF);
    e.priority = (int)((val >>  7) & 0x1);  // 'prio' field in RTL
    e.flip_y   = (int)((val >>  8) & 0x1);
    e.flip_x   = (int)((val >>  9) & 0x1);
    e.tile_num = (int)((val >> 10) & 0x3FF);
    e.y        = (int)((val >> 20) & 0x1FF);
    e.x        = (int)((val >> 29) & 0x1FF);
    return e;
}

// ---------------------------------------------------------------------------
// DUT wrapper
// ---------------------------------------------------------------------------

struct DUT {
    Vgp9001* top;
    uint64_t cycle;
    int      failures;
    int      checks;

    bool     dl_ready_pulsed;
    bool     irq_pulsed;

    DUT() : cycle(0), failures(0), checks(0),
            dl_ready_pulsed(false), irq_pulsed(false) {
        top = new Vgp9001();
        reset();
    }

    ~DUT() {
        top->final();
        delete top;
    }

    void clk_tick(int n = 1) {
        for (int i = 0; i < n; i++) {
            top->clk = 0; top->eval();
            top->clk = 1; top->eval();
            ++cycle;
            if (top->display_list_ready) dl_ready_pulsed = true;
            if (top->irq_sprite)         irq_pulsed       = true;
        }
    }

    void reset() {
        top->rst_n     = 0;
        top->cs_n      = 1;
        top->rd_n      = 1;
        top->wr_n      = 1;
        top->addr      = 0;
        top->din       = 0;
        top->vsync     = 0;
        top->vblank    = 0;
        top->scan_addr = 0;
        // Gate 3 inputs
        top->hpos      = 0;
        top->vpos      = 0;
        top->hblank    = 0;
        top->vblank_in = 0;
        top->bg_rom_data  = 0;
        // Gate 4 inputs
        top->scan_trigger     = 0;
        top->current_scanline = 0;
        top->spr_rom_data     = 0;
        top->spr_rd_addr      = 0;
        clk_tick(4);
        top->rst_n = 1;
        clk_tick(4);
        dl_ready_pulsed = false;
        irq_pulsed       = false;
    }

    // ── Control register write ─────────────────────────────────────────────
    void write_reg(int addr_offset, int data) {
        top->addr = (uint32_t)(addr_offset & 0xF);
        top->din  = (uint16_t)(data & 0xFFFF);
        top->cs_n = 0;
        top->wr_n = 0;
        top->rd_n = 1;
        clk_tick(1);
        top->cs_n = 1;
        top->wr_n = 1;
        clk_tick(1);
    }

    // ── Control register read (combinational) ─────────────────────────────
    uint16_t read_reg(int addr_offset) {
        top->addr = (uint32_t)(addr_offset & 0xF);
        top->cs_n = 0;
        top->rd_n = 0;
        top->wr_n = 1;
        top->clk  = 0; top->eval();
        uint16_t d = top->dout;
        top->clk  = 1; top->eval();
        ++cycle;
        if (top->display_list_ready) dl_ready_pulsed = true;
        if (top->irq_sprite)         irq_pulsed       = true;
        top->cs_n = 1;
        top->rd_n = 1;
        clk_tick(1);
        return d;
    }

    // ── Sprite RAM write ───────────────────────────────────────────────────
    // word_idx: flat word index (0..255 for sprite slots 0..63).
    // Maps to sram[0x100 + (word_idx & 0xFF)], matching the scanner's
    // {2'b01, scan_slot[5:0], 2'bNN} read addresses.
    void write_sram(int word_idx, int data) {
        uint32_t a = (uint32_t)(0x100 | (word_idx & 0xFF));
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

    // ── Sprite RAM read (registered, 1-cycle latency) ─────────────────────
    uint16_t read_sram(int word_idx) {
        uint32_t a = (uint32_t)(0x100 | (word_idx & 0xFF));
        top->addr = a;
        top->cs_n = 0;
        top->rd_n = 0;
        top->wr_n = 1;
        clk_tick(2);
        uint16_t d = top->dout;
        top->cs_n = 1;
        top->rd_n = 1;
        clk_tick(1);
        return d;
    }

    // ── vsync pulse (Gate 1 shadow→active staging) ────────────────────────
    void vsync_pulse() {
        top->vsync = 1;
        clk_tick(2);
        top->vsync = 0;
        clk_tick(2);
    }

    // ── vblank pulse (Gate 2 scanner trigger) ─────────────────────────────
    // Assert vblank for 1 cycle; wait scan_max+8 cycles for completion.
    void vblank_pulse(int scan_max) {
        dl_ready_pulsed = false;
        irq_pulsed       = false;
        top->vblank = 1;
        clk_tick(1);
        top->vblank = 0;
        clk_tick(scan_max + 8);
    }

    // ── Check helper ───────────────────────────────────────────────────────
    void check(const char* label, int got, int exp) {
        ++checks;
        if (got != exp) {
            fprintf(stderr, "FAIL  %s: got 0x%04X exp 0x%04X\n", label, got, exp);
            ++failures;
        } else {
            fprintf(stderr, "pass  %s: 0x%04X\n", label, got);
        }
    }

    // ── Active scroll register ─────────────────────────────────────────────
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

        std::string op  = jstr(line, "op");
        int addr_val    = jint(line, "addr", 0);
        int data_val    = jint(line, "data", 0);
        int exp_val     = jint(line, "exp",  0);

        // ── Gate 1 ops ────────────────────────────────────────────────────

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

        // ── Gate 2 ops ────────────────────────────────────────────────────

        } else if (op == "vblank_pulse") {
            int sm = jint(line, "scan_max", 16);
            dut.vblank_pulse(sm);

        } else if (op == "check_dl_count") {
            dut.check("display_list_count",
                      (int)(uint8_t)dut.top->display_list_count, exp_val);

        } else if (op == "check_dl_ready_pulse") {
            dut.check("display_list_ready_pulsed",
                      dut.dl_ready_pulsed ? 1 : 0, 1);
            dut.dl_ready_pulsed = false;

        } else if (op == "check_irq_pulse") {
            dut.check("irq_sprite_pulsed",
                      dut.irq_pulsed ? 1 : 0, 1);
            dut.irq_pulsed = false;

        } else if (op == "check_dl_entry") {
            int idx  = jint(line, "idx", 0);
            int v_exp = jint(line, "valid", 0);
            DlEntry e = get_dl_entry(dut.top, idx);
            char lbl[80];

            snprintf(lbl, sizeof(lbl), "dl[%d].valid", idx);
            dut.check(lbl, e.valid, v_exp);

            if (v_exp) {
                snprintf(lbl, sizeof(lbl), "dl[%d].x",        idx); dut.check(lbl, e.x,        jint(line,"x",0));
                snprintf(lbl, sizeof(lbl), "dl[%d].y",        idx); dut.check(lbl, e.y,        jint(line,"y",0));
                snprintf(lbl, sizeof(lbl), "dl[%d].tile_num", idx); dut.check(lbl, e.tile_num, jint(line,"tile_num",0));
                snprintf(lbl, sizeof(lbl), "dl[%d].flip_x",   idx); dut.check(lbl, e.flip_x,   jint(line,"flip_x",0));
                snprintf(lbl, sizeof(lbl), "dl[%d].flip_y",   idx); dut.check(lbl, e.flip_y,   jint(line,"flip_y",0));
                snprintf(lbl, sizeof(lbl), "dl[%d].priority", idx); dut.check(lbl, e.priority, jint(line,"priority",0));
                snprintf(lbl, sizeof(lbl), "dl[%d].palette",  idx); dut.check(lbl, e.palette,  jint(line,"palette",0));
                snprintf(lbl, sizeof(lbl), "dl[%d].size",     idx); dut.check(lbl, e.size,     jint(line,"size",0));
            }

        } else if (op == "check_dl_entry_valid") {
            int idx = jint(line, "idx", 0);
            DlEntry e = get_dl_entry(dut.top, idx);
            char lbl[80];
            snprintf(lbl, sizeof(lbl), "dl[%d].valid", idx);
            dut.check(lbl, e.valid, exp_val);

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
        fprintf(stderr, "Usage: %s <gate2_vectors.jsonl> [...]\n", argv[0]);
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
