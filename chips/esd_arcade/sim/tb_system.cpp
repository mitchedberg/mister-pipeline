// =============================================================================
// tb_system.cpp — ESD 16-bit Arcade Verilator testbench
//
// Wraps tb_top.sv (which includes esd_arcade + fx68k CPU) and drives:
//   - Clock (48 MHz system clock) and reset
//   - Pixel clock enable (48 MHz / 6 = 8 MHz, one-cycle pulse)
//   - Three SDRAM channels: prog ROM, sprite ROM, BG tile ROM
//   - Player inputs held at active-high idle (active-low buttons not pressed)
//
// The CPU (fx68k) is inside tb_top.sv and executes the real Multi Champ ROM.
// enPhi1/enPhi2 are driven from C++ BEFORE eval() per COMMUNITY_PATTERNS.md.
//
// Environment variables:
//   N_FRAMES   — number of vertical frames to simulate (default 30)
//   ROM_PROG   — path to program ROM binary  (even/odd interleaved, 512KB)
//   ROM_SPR    — path to sprite ROM binary   (pre-interleaved, up to 1.25MB)
//   ROM_BG     — path to BG tile ROM binary  (up to 512KB, 8bpp)
//   DUMP_VCD   — set to "1" to enable VCD trace (slow, ~400MB)
//
// Output:
//   frame_NNNN.ppm — one PPM file per vertical frame (320x224)
//
// Video resolution: 320x224 @ 60 Hz
//   Horizontal: 320 active + 64 blanking = 384 total clocks/line
//   Vertical:   224 active + 40 blanking = 264 total lines/frame
//   At 48 MHz sys clock, pixel clock divider = 6 → 8 MHz pixel clock
//   Htotal = 384, Vtotal = 264 → ~60.0 Hz
// =============================================================================

#include "Vtb_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include "sdram_model.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>

// ── Video timing constants (ESD 16-bit 320×224) ──────────────────────────────
static constexpr int VID_H_ACTIVE  = 320;
static constexpr int VID_V_ACTIVE  = 224;
static constexpr int VID_H_TOTAL   = 384;   // pixels per line
static constexpr int VID_V_TOTAL   = 264;   // lines per frame

// Pixel clock divider: sys_clk / 6 = 8 MHz effective pixel clock
static constexpr int PIX_DIV = 6;

// =============================================================================
// Frame buffer
// =============================================================================
struct FrameBuffer {
    static constexpr int W = VID_H_ACTIVE;
    static constexpr int H = VID_V_ACTIVE;
    uint32_t pixels[W * H];

    FrameBuffer() { memset(pixels, 0, sizeof(pixels)); }

    void set(int x, int y, uint8_t r, uint8_t g, uint8_t b) {
        if (x >= 0 && x < W && y >= 0 && y < H)
            pixels[y * W + x] = ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
    }

    bool write_ppm(const char* path) const {
        FILE* f = fopen(path, "wb");
        if (!f) { fprintf(stderr, "Cannot write %s\n", path); return false; }
        fprintf(f, "P6\n%d %d\n255\n", W, H);
        for (int i = 0; i < W * H; i++) {
            uint8_t rgb[3] = {
                (uint8_t)(pixels[i] >> 16),
                (uint8_t)(pixels[i] >> 8),
                (uint8_t)(pixels[i])
            };
            fwrite(rgb, 1, 3, f);
        }
        fclose(f);
        return true;
    }

    int count_nonblack() const {
        int n = 0;
        for (int i = 0; i < W * H; i++)
            if (pixels[i] != 0) n++;
        return n;
    }
};

// =============================================================================
// main
// =============================================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    // ── Configuration from environment ──────────────────────────────────────
    const char* env_frames = getenv("N_FRAMES");
    const char* env_prog   = getenv("ROM_PROG");
    const char* env_spr    = getenv("ROM_SPR");
    const char* env_bg     = getenv("ROM_BG");
    const char* env_vcd    = getenv("DUMP_VCD");

    int n_frames = env_frames ? atoi(env_frames) : 30;
    if (n_frames < 1) n_frames = 1;

    fprintf(stderr, "ESD Arcade simulation: %d frames\n", n_frames);

    // ── Load ROM data ────────────────────────────────────────────────────────
    SdramModel sdram;
    if (env_prog) sdram.load(env_prog, 0x000000);
    if (env_spr)  sdram.load(env_spr,  0x080000);
    if (env_bg)   sdram.load(env_bg,   0x280000);

    // ── SDRAM channels ───────────────────────────────────────────────────────
    ToggleSdramChannel prog_ch(sdram);
    // Sprite and BG channels use combinational zero-latency (always ack immediately)

    // ── Verilator init ──────────────────────────────────────────────────────
    Verilated::fatalOnError(false);  // suppress fx68k unique-case assertion halts

    // ── Instantiate DUT ──────────────────────────────────────────────────────
    Vtb_top* top = new Vtb_top();

    // ── Optional VCD trace ───────────────────────────────────────────────────
    VerilatedVcdC* vcd = nullptr;
    if (env_vcd && env_vcd[0] == '1') {
        Verilated::traceEverOn(true);
        vcd = new VerilatedVcdC();
        top->trace(vcd, 99);
        vcd->open("sim_esd_arcade.vcd");
        fprintf(stderr, "VCD trace enabled: sim_esd_arcade.vcd\n");
    }

    // ── Initial port state ───────────────────────────────────────────────────
    top->clk_sys  = 0;
    top->clk_pix  = 0;
    top->reset_n  = 0;
    top->enPhi1   = 0;
    top->enPhi2   = 0;

    // SDRAM inputs
    top->prog_rom_data = 0xFFFF;
    top->prog_rom_ack  = 0;
    top->spr_rom_data  = 0xFFFF;
    top->spr_rom_ack   = 0;
    top->bg_rom_data   = 0xFFFF;
    top->bg_rom_ack    = 0;

    // Player inputs — all buttons released (active-low, so 1 = idle)
    top->joystick_0 = 0x1FF;  // all bits idle
    top->joystick_1 = 0x1FF;
    top->dip_sw     = 0xFFFF; // default DIP settings

    // ── Simulation state ─────────────────────────────────────────────────────
    uint64_t cycle      = 0;
    int      frame_num  = 0;
    bool     done       = false;

    // Video pixel counter state
    int pix_div_cnt = 0;  // pixel clock divider

    // Frame buffer
    FrameBuffer fb;
    int px = 0, py = 0;

    // vsync edge detection for frame counting
    uint8_t vblank_prev = 0;

    // Bus cycle statistics
    uint64_t bus_cycles = 0;
    uint8_t  prev_as_n  = 1;

    // Ring buffer for last 32 bus cycles (for stall diagnosis)
    struct BusCycleLog { uint32_t addr; uint8_t rw; uint16_t data; };
    static constexpr int BUSLOG_N = 32;
    BusCycleLog buslog[BUSLOG_N] = {};
    int buslog_idx = 0;

    // Stall detection
    uint64_t last_bc_change_cycle = 0;

    // Phi toggle (drives enPhi1/enPhi2)
    bool phi_toggle = false;

    // ── Reset pulse: hold reset for 16 cycles ────────────────────────────────
    for (int i = 0; i < 32; i++) {
        top->clk_sys = 0; top->eval(); if (vcd) vcd->dump(cycle*2);
        top->clk_sys = 1; top->eval(); if (vcd) vcd->dump(cycle*2+1);
        ++cycle;
    }
    top->reset_n = 1;
    fprintf(stderr, "Reset deasserted at cycle %llu\n", (unsigned long long)cycle);

    // ── Simulation loop ──────────────────────────────────────────────────────
    while (!done && frame_num < n_frames) {
        // ── Negedge ──────────────────────────────────────────────────────────
        top->clk_sys = 0;
        top->clk_pix = 0;
        top->enPhi1  = 0;
        top->enPhi2  = 0;
        top->eval();
        if (vcd) vcd->dump(cycle * 2);

        // ── Pixel clock divide ────────────────────────────────────────────────
        ++pix_div_cnt;
        if (pix_div_cnt >= PIX_DIV) {
            pix_div_cnt = 0;
            top->clk_pix = 1;  // one-cycle-wide pulse in next posedge
        }

        // ── SDRAM channels: update BEFORE posedge eval ───────────────────────
        // Program ROM — toggle handshake
        {
            auto r = prog_ch.tick(top->prog_rom_req, (uint32_t)top->prog_rom_addr);
            top->prog_rom_data = r.data;
            top->prog_rom_ack  = r.ack;
        }
        // Sprite ROM — combinational zero-latency
        {
            uint32_t addr = (uint32_t)top->spr_rom_addr;
            top->spr_rom_data = sdram.read_word(addr & ~1u);
            top->spr_rom_ack  = top->spr_rom_req;
        }
        // BG Tile ROM — combinational zero-latency
        {
            uint32_t addr = (uint32_t)top->bg_rom_addr;
            top->bg_rom_data = sdram.read_word(addr & ~1u);
            top->bg_rom_ack  = top->bg_rom_req;
        }

        // ── Phi enables: set BEFORE posedge eval ─────────────────────────────
        // (COMMUNITY_PATTERNS.md 1.1: drive from C++ before eval, not from RTL)
        if (cycle >= 8) {
            top->enPhi1 = phi_toggle ? 0 : 1;
            top->enPhi2 = phi_toggle ? 1 : 0;
            phi_toggle  = !phi_toggle;
        }

        // ── Posedge eval ─────────────────────────────────────────────────────
        top->clk_sys = 1;
        top->eval();
        if (vcd) vcd->dump(cycle * 2 + 1);

        // ── Bus cycle counter (for diagnostic reporting) ──────────────────────
        if (!top->dbg_cpu_as_n && prev_as_n) {
            ++bus_cycles;
            last_bc_change_cycle = cycle;
            uint32_t baddr = (unsigned)(top->dbg_cpu_addr) << 1;
            // First few bus cycles: print address for reset vector check
            if (bus_cycles <= 5) {
                fprintf(stderr, "  bc=%llu: addr=0x%06X rw=%d\n",
                        (unsigned long long)bus_cycles, baddr,
                        (int)top->dbg_cpu_rw);
            }
            // Log in ring buffer
            buslog[buslog_idx % BUSLOG_N] = { baddr, top->dbg_cpu_rw, top->dbg_cpu_dout };
            buslog_idx++;
        }
        prev_as_n = top->dbg_cpu_as_n;

        // ── Stall detection: if no new bus cycle for 50000 cycles, dump log ───
        if (cycle > 100 && (cycle - last_bc_change_cycle) == 50000) {
            fprintf(stderr, "STALL DETECTED at cycle=%llu bc=%llu. Last %d bus cycles:\n",
                    (unsigned long long)cycle, (unsigned long long)bus_cycles,
                    (buslog_idx < BUSLOG_N) ? buslog_idx : BUSLOG_N);
            int start = (buslog_idx >= BUSLOG_N) ? buslog_idx - BUSLOG_N : 0;
            for (int i = start; i < buslog_idx; i++) {
                const auto& e = buslog[i % BUSLOG_N];
                fprintf(stderr, "  [%d] addr=0x%06X rw=%d data=0x%04X\n",
                        i, e.addr, (int)e.rw, (unsigned)e.data);
            }
        }

        // ── CPU halt detection ────────────────────────────────────────────────
        if (!top->dbg_cpu_halted_n) {
            static bool halt_reported = false;
            if (!halt_reported) {
                fprintf(stderr, "WARNING: CPU HALTED (double bus fault) at bc=%llu\n",
                        (unsigned long long)bus_cycles);
                halt_reported = true;
            }
        }

        // ── Pixel capture ────────────────────────────────────────────────────
        if (top->clk_pix) {
            bool h_active = !top->hblank;
            bool v_active = !top->vblank;

            if (h_active && v_active) {
                fb.set(px, py, top->rgb_r, top->rgb_g, top->rgb_b);
            }

            ++px;
            if (px >= VID_H_TOTAL) {
                px = 0;
                if (!top->vblank) ++py;
                if (py >= VID_V_ACTIVE) py = VID_V_ACTIVE - 1;
            }
        }

        // ── VBlank edge — frame boundary ─────────────────────────────────────
        if (top->vblank && !vblank_prev) {
            // Rising edge of vblank = end of active frame
            char fname[64];
            snprintf(fname, sizeof(fname), "frame_%04d.ppm", frame_num);
            fb.write_ppm(fname);

            int nonblack = fb.count_nonblack();
            fprintf(stderr, "frame %4d: bus_cycles=%llu  colored_px=%d/%d (%.1f%%)\n",
                    frame_num,
                    (unsigned long long)bus_cycles,
                    nonblack,
                    VID_H_ACTIVE * VID_V_ACTIVE,
                    100.0f * nonblack / (VID_H_ACTIVE * VID_V_ACTIVE));

            memset(fb.pixels, 0, sizeof(fb.pixels));
            px = 0; py = 0;
            ++frame_num;
        }
        vblank_prev = top->vblank;

        ++cycle;
    }

    fprintf(stderr, "Simulation done: %d frames, %llu total cycles, %llu bus cycles\n",
            frame_num,
            (unsigned long long)cycle,
            (unsigned long long)bus_cycles);

    if (vcd) { vcd->close(); delete vcd; }
    top->final();
    delete top;
    return 0;
}
