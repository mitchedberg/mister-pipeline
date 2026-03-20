// =============================================================================
// tb_system.cpp — Kaneko 16 (berlwall) Verilator testbench
//
// Drives tb_top.sv which contains kaneko16 + fx68k CPU executing the real
// Berlin Wall ROM.
//
// Clock model: single clk_sys.
//   enPhi1/enPhi2 toggle every cycle (giving half-speed CPU).
//
// ROM access model (bypass pattern, same as NMK sim):
//   bypass_en=1 when CPU is accessing ROM space (A[23:21] == 0)
//   C++ presents ROM data combinationally based on cpu_addr before posedge eval
//   bypass_dtack_n=0 immediately (1-cycle ROM latency)
//
// Video timing: Kaneko 16 standard
//   H_ACTIVE=320, V_ACTIVE=240, Htotal=342, Vtotal=262 → ~60 Hz
//
// Sprite/BG ROMs: combinational zero-latency reads (C++ serves directly)
//
// Environment variables:
//   N_FRAMES  — frames to simulate (default 10)
//   ROM_PROG  — path to interleaved program ROM binary (prog.bin, 256 KB)
//   ROM_SPR   — path to sprite ROM binary (spr.bin)
//   ROM_BG    — path to BG tile ROM binary (bg.bin)
//   DUMP_VCD  — set to "1" to enable VCD trace (slow)
//
// Output: frame_NNNN.ppm — one PPM per vertical frame
//
// NOTE: watchdog_reset is NOT wired to system reset.
//       RTL compiled with VERILATOR=1 (Verilator auto-defines) which disables
//       the watchdog via `ifdef VERILATOR guard in kaneko16.sv.
// =============================================================================

#include "Vtb_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include "sdram_model.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cinttypes>
#include <string>
#include <vector>

// ── Video timing constants (Kaneko 16 standard 320×240) ─────────────────────
static constexpr int VID_H_ACTIVE    = 320;
static constexpr int VID_V_ACTIVE    = 240;
static constexpr int VID_H_TOTAL     = 342;
static constexpr int VID_V_TOTAL     = 262;
static constexpr int VID_HSYNC_START = VID_H_ACTIVE + 16;
static constexpr int VID_HSYNC_END   = VID_HSYNC_START + 5;
static constexpr int VID_VSYNC_START = VID_V_ACTIVE + 4;
static constexpr int VID_VSYNC_END   = VID_VSYNC_START + 4;

// =============================================================================
// Frame buffer
// =============================================================================
struct FrameBuffer {
    static constexpr int W = VID_H_ACTIVE;
    static constexpr int H = VID_V_ACTIVE;
    std::vector<uint32_t> pixels;

    FrameBuffer() : pixels(W * H, 0) {}

    void set(int x, int y, uint8_t r, uint8_t g, uint8_t b) {
        if (x >= 0 && x < W && y >= 0 && y < H)
            pixels[y * W + x] = ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
    }

    bool write_ppm(const char* path) const {
        FILE* f = fopen(path, "wb");
        if (!f) { fprintf(stderr, "Cannot write %s\n", path); return false; }
        fprintf(f, "P6\n%d %d\n255\n", W, H);
        for (int y = 0; y < H; y++) {
            for (int x = 0; x < W; x++) {
                uint32_t p = pixels[y * W + x];
                uint8_t rgb[3] = { (uint8_t)(p >> 16), (uint8_t)(p >> 8), (uint8_t)p };
                fwrite(rgb, 1, 3, f);
            }
        }
        fclose(f);
        return true;
    }
};

// =============================================================================
// main
// =============================================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::fatalOnError(false);  // suppress fx68k unique-case assertions during reset

    // ── Configuration ────────────────────────────────────────────────────────
    const char* env_frames = getenv("N_FRAMES");
    const char* env_prog   = getenv("ROM_PROG");
    const char* env_spr    = getenv("ROM_SPR");
    const char* env_bg     = getenv("ROM_BG");
    const char* env_vcd    = getenv("DUMP_VCD");

    int n_frames = env_frames ? atoi(env_frames) : 10;
    if (n_frames < 1) n_frames = 1;

    fprintf(stderr, "Kaneko16 (berlwall) simulation: %d frames\n", n_frames);

    // ── Load ROM data ─────────────────────────────────────────────────────────
    SdramModel sdram;
    // Program ROM: loaded at SDRAM byte 0 (CPU byte 0x000000)
    if (env_prog) sdram.load(env_prog, 0x000000);
    else fprintf(stderr, "WARNING: ROM_PROG not set\n");

    // Sprite ROM: loaded at SDRAM byte 0x100000
    if (env_spr) sdram.load(env_spr, 0x100000);
    else fprintf(stderr, "WARNING: ROM_SPR not set\n");

    // BG tile ROM: loaded at SDRAM byte 0x500000
    if (env_bg) sdram.load(env_bg, 0x500000);
    else fprintf(stderr, "WARNING: ROM_BG not set\n");

    // ── DUT init ──────────────────────────────────────────────────────────────
    Vtb_top* top = new Vtb_top();

    // ── Optional VCD trace ────────────────────────────────────────────────────
    VerilatedVcdC* vcd = nullptr;
    if (env_vcd && env_vcd[0] == '1') {
        Verilated::traceEverOn(true);
        vcd = new VerilatedVcdC();
        top->trace(vcd, 99);
        vcd->open("sim_kaneko16.vcd");
        fprintf(stderr, "VCD trace enabled: sim_kaneko16.vcd\n");
    }

    // ── Initial port state ────────────────────────────────────────────────────
    top->clk_sys          = 0;
    top->reset_n          = 0;
    top->enPhi1           = 0;
    top->enPhi2           = 0;
    top->spr_rom_data     = 0;
    top->bg_tile_rom_data = 0;
    top->vsync_n_in       = 1;
    top->hsync_n_in       = 1;
    top->hpos             = 0;
    top->vpos             = 0;
    top->joystick_p1      = 0xFFFF;   // all buttons released
    top->joystick_p2      = 0xFFFF;
    top->coin_in          = 0x0000;
    top->dip_switches     = 0xFFFF;
    top->bypass_en        = 0;
    top->bypass_data      = 0xFFFF;
    top->bypass_dtack_n   = 1;

    // ── Simulation state ──────────────────────────────────────────────────────
    uint64_t cycle     = 0;
    int      frame_num = 0;
    bool     done      = false;

    int hcnt = 0;
    int vcnt = 0;

    FrameBuffer fb;
    uint8_t vsync_n_prev = 1;

    int bus_cycle_count = 0;
    int palette_writes  = 0;
    int ram_writes      = 0;

    // ── Main simulation loop ──────────────────────────────────────────────────
    auto tick = [&]() {

        // ── Video timing ─────────────────────────────────────────────────────
        {
            bool h_active = (hcnt < VID_H_ACTIVE);
            bool v_active = (vcnt < VID_V_ACTIVE);
            bool hsync    = (hcnt >= VID_HSYNC_START && hcnt < VID_HSYNC_END);
            bool vsync    = (vcnt >= VID_VSYNC_START && vcnt < VID_VSYNC_END);

            top->hsync_n_in = hsync ? 0 : 1;
            top->vsync_n_in = vsync ? 0 : 1;
            top->hpos = (uint16_t)(h_active ? hcnt : 0);
            top->vpos = (uint8_t) (v_active ? vcnt : 0);

            ++hcnt;
            if (hcnt >= VID_H_TOTAL) {
                hcnt = 0;
                ++vcnt;
                if (vcnt >= VID_V_TOTAL) vcnt = 0;
            }
        }

        // ── Sprite ROM: combinational zero-latency ────────────────────────────
        {
            // Sprite byte addr offset: loaded at SDRAM 0x100000
            uint32_t spr_byte_addr = 0x100000u + (uint32_t)top->spr_rom_addr;
            uint16_t lo = sdram.read_word(spr_byte_addr);
            uint16_t hi = sdram.read_word(spr_byte_addr + 2);
            top->spr_rom_data = ((uint32_t)hi << 16) | lo;
        }

        // ── BG tile ROM: combinational zero-latency ───────────────────────────
        {
            uint32_t bg_byte_addr = 0x500000u + (uint32_t)top->bg_tile_rom_addr;
            top->bg_tile_rom_data = sdram.read_byte(bg_byte_addr);
        }

        // ── Bus bypass: set data BEFORE posedge eval ──────────────────────────
        // The CPU samples iEdb ON posedge eval. We use the previous cycle's
        // address/ASn (already settled) to decide what to present.
        // ROM space: A[23:21] = 0b000 → byte addresses 0x000000–0x1FFFFF
        {
            uint32_t cur_addr = (uint32_t)top->dbg_cpu_addr;  // [23:1]
            bool     cur_as_n = (bool)top->dbg_cpu_as_n;
            bool     cur_rw   = (bool)top->dbg_cpu_rw;

            // ROM chip select: upper 3 bits of byte address = 0
            bool rom_cs = (!cur_as_n) && ((cur_addr >> 20) == 0);

            if (rom_cs && cur_rw) {
                // Read from program ROM
                uint32_t byte_addr = (uint32_t)(cur_addr << 1) & 0x1FFFFFu;
                top->bypass_data    = sdram.read_word(byte_addr);
                top->bypass_dtack_n = 0;
                top->bypass_en      = 1;
            } else {
                top->bypass_en      = 0;
                top->bypass_data    = 0xFFFF;
                top->bypass_dtack_n = 1;
            }
        }

        // ── Phi enables: toggle every cycle after reset ───────────────────────
        {
            static bool phi_toggle = false;
            if (cycle >= 16) {
                top->enPhi1 = phi_toggle ? 0 : 1;
                top->enPhi2 = phi_toggle ? 1 : 0;
                phi_toggle  = !phi_toggle;
            } else {
                top->enPhi1 = 0;
                top->enPhi2 = 0;
            }
        }

        // ── Posedge eval ──────────────────────────────────────────────────────
        top->clk_sys = 1;
        top->eval();
        if (vcd) vcd->dump((vluint64_t)(cycle * 2 + 1));

        // ── Capture pixel ─────────────────────────────────────────────────────
        {
            bool active = (!top->vblank) && (!top->hblank);
            if (active) {
                int cx = (int)top->hpos;
                int cy = (int)top->vpos;
                fb.set(cx, cy, top->rgb_r, top->rgb_g, top->rgb_b);
            }
        }

        // ── CPU bus diagnostics: first 200 cycles ────────────────────────────
        if (cycle <= 200) {
            fprintf(stderr, "  [%4" PRIu64 "] as_n=%d halted_n=%d rw=%d addr=0x%06X"
                            " dtack_n=%d bypass=%d dout=0x%04X\n",
                    cycle,
                    (int)top->dbg_cpu_as_n,
                    (int)top->dbg_cpu_halted_n,
                    (int)top->dbg_cpu_rw,
                    (unsigned)(((uint32_t)top->dbg_cpu_addr) << 1),
                    (int)top->dbg_cpu_dtack_n,
                    (int)top->bypass_en,
                    (unsigned)(top->dbg_cpu_dout & 0xFFFF));
        }

        // ── Bus cycle tracking ────────────────────────────────────────────────
        {
            static bool prev_as_n = true;
            bool cur_as_n = (bool)top->dbg_cpu_as_n;
            if (!cur_as_n && prev_as_n) {
                ++bus_cycle_count;
                uint32_t byte_addr = ((uint32_t)top->dbg_cpu_addr) << 1;

                // Log first 200 bus cycles
                if (bus_cycle_count <= 200) {
                    fprintf(stderr, "  BUS#%3d [%7" PRIu64 "] %s 0x%06X dtack=%d data=0x%04X\n",
                            bus_cycle_count, cycle,
                            top->dbg_cpu_rw ? "RD" : "WR",
                            byte_addr, (int)top->dbg_cpu_dtack_n,
                            (unsigned)(top->dbg_cpu_dout & 0xFFFF));
                }

                // Palette write trace (0x140000–0x14FFFF)
                if (!top->dbg_cpu_rw && byte_addr >= 0x140000 && byte_addr <= 0x14FFFF) {
                    ++palette_writes;
                    if (palette_writes <= 10)
                        fprintf(stderr, "  PAL WR #%d addr=0x%06X data=0x%04X\n",
                                palette_writes, byte_addr, (unsigned)top->dbg_cpu_din);
                }

                // Count all RAM/register writes
                if (!top->dbg_cpu_rw && byte_addr >= 0x100000)
                    ++ram_writes;
            }
            prev_as_n = cur_as_n;
        }

        // Detect CPU halt
        {
            static bool halted_reported = false;
            if (!top->dbg_cpu_halted_n && !halted_reported) {
                halted_reported = true;
                fprintf(stderr, "\n*** CPU HALTED at cycle %" PRIu64
                                " (double bus fault) — bus_cycles=%d ***\n\n",
                        cycle, bus_cycle_count);
            }
        }

        // Periodic status
        if (cycle > 0 && (cycle % 100000) == 0) {
            fprintf(stderr, "  @%" PRIu64 "K: frame=%d bus=%d pal_wr=%d ram_wr=%d"
                            " as_n=%d halted_n=%d addr=0x%06X\n",
                    cycle / 1000, frame_num, bus_cycle_count, palette_writes, ram_writes,
                    (int)top->dbg_cpu_as_n,
                    (int)top->dbg_cpu_halted_n,
                    (unsigned)(((uint32_t)top->dbg_cpu_addr) << 1));
        }

        // ── vsync falling edge → save frame ──────────────────────────────────
        uint8_t vsync_n_now = top->vsync_n;
        if (vsync_n_prev == 1 && vsync_n_now == 0) {
            char fname[64];
            snprintf(fname, sizeof(fname), "frame_%04d.ppm", frame_num);
            if (fb.write_ppm(fname))
                fprintf(stderr, "Frame %4d written: %s\n", frame_num, fname);
            ++frame_num;
            if (frame_num >= n_frames) done = true;
            fb = FrameBuffer();
        }
        vsync_n_prev = vsync_n_now;

        // ── Negedge ───────────────────────────────────────────────────────────
        top->clk_sys = 0;
        top->enPhi1  = 0;
        top->enPhi2  = 0;
        top->eval();
        if (vcd) vcd->dump((vluint64_t)(cycle * 2));

        ++cycle;
    };

    // ── Reset sequence ────────────────────────────────────────────────────────
    fprintf(stderr, "Asserting reset for 16 cycles...\n");
    top->reset_n = 0;
    for (int i = 0; i < 16; i++) tick();
    top->reset_n = 1;
    fprintf(stderr, "Reset released at cycle %" PRIu64 "\n", cycle);

    // ── Run simulation ────────────────────────────────────────────────────────
    while (!done && !Verilated::gotFinish()) {
        tick();
    }

    fprintf(stderr, "Simulation complete: %d frames, %" PRIu64 " cycles, "
                    "%d bus_cycles, %d pal_writes, %d ram_writes\n",
            frame_num, cycle, bus_cycle_count, palette_writes, ram_writes);

    if (vcd) { vcd->close(); delete vcd; }
    top->final();
    delete top;
    return 0;
}
