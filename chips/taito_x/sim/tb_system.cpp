// =============================================================================
// tb_system.cpp — Taito X (Gigandes) full-system Verilator testbench
//
// Wraps tb_top.sv (which includes taito_x + fx68k + T80s) and drives:
//   - Clock (32 MHz) and reset
//   - Three SDRAM channels (behavioral toggle-handshake model):
//       sdr/prog  — 68000 program ROM  (toggle 16-bit, SDRAM 0x000000)
//       z80_rom   — Z80 audio ROM      (toggle 16-bit word, tb_top selects byte)
//       gfx       — GFX / sprite ROM   (zero-latency combinational, 16-bit)
//   - Player inputs (all held at 0xFF = no input, active-low)
//
// taito_x generates video timing INTERNALLY (384×240 @ ~60 Hz).
// The C++ testbench does NOT drive hblank/vblank/hpos/vpos.
//
// Environment variables:
//   N_FRAMES   — number of vertical frames to simulate (default: 30)
//   ROM_PROG   — path to 68000 program ROM binary (SDRAM 0x000000, 512KB)
//   ROM_Z80    — path to Z80 audio ROM binary     (SDRAM 0x080000, 128KB)
//   ROM_GFX    — path to sprite/GFX ROM binary    (SDRAM 0x100000, up to 4MB)
//   DUMP_VCD   — set to "1" to enable VCD trace (slow)
//
// Output:
//   frame_NNNN.ppm — one PPM file per vertical frame
//
// Video resolution: 384×240 (Taito X native)
//   Horizontal: 384 active + 128 blanking = 512 total pixels/line
//   Vertical:   240 active +  22 blanking = 262 total lines/frame
//   At 32 MHz sys_clk, pixel clock = 8 MHz (clk_pix pulse every 4 sys clocks)
//   Frame rate = 8 MHz / (512 × 262) = ~59.9 Hz
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
#include <vector>

// ── Video constants (Taito X 384×240) ────────────────────────────────────────
static constexpr int VID_H_ACTIVE = 384;
static constexpr int VID_V_ACTIVE = 240;

// clk_pix: 1-cycle pulse every 4 sys clocks → 8 MHz from 32 MHz
static constexpr int PIX_DIV = 4;

// z80_cen: 1-cycle pulse every 8 sys clocks → 4 MHz from 32 MHz
static constexpr int Z80_DIV = 8;

// =============================================================================
// Frame buffer
// =============================================================================
struct FrameBuffer {
    static constexpr int W = VID_H_ACTIVE;
    static constexpr int H = VID_V_ACTIVE;
    std::vector<uint32_t> pixels;  // RGB packed: (r<<16)|(g<<8)|b

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
// Pixel capture state
// =============================================================================
struct PixelCapture {
    int px = 0;   // current X within active region
    int py = 0;   // current Y within active region
    bool prev_hblank = false;
    bool prev_vblank = false;
};

// =============================================================================
// main
// =============================================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    // ── Configuration from environment ──────────────────────────────────────
    const char* env_frames = getenv("N_FRAMES");
    const char* env_prog   = getenv("ROM_PROG");
    const char* env_z80    = getenv("ROM_Z80");
    const char* env_gfx    = getenv("ROM_GFX");
    const char* env_vcd    = getenv("DUMP_VCD");

    int n_frames = env_frames ? atoi(env_frames) : 30;
    if (n_frames < 1) n_frames = 1;

    fprintf(stderr, "Taito X simulation: %d frames\n", n_frames);

    // ── Load ROM data ────────────────────────────────────────────────────────
    SdramModel sdram;
    if (env_prog) sdram.load(env_prog, 0x000000);
    if (env_z80)  sdram.load(env_z80,  0x080000);
    if (env_gfx)  sdram.load(env_gfx,  0x100000);

    // ── SDRAM channels ───────────────────────────────────────────────────────
    // sdr: 68000 program ROM (toggle handshake, 16-bit)
    ToggleSdramChannel sdr_ch(sdram);
    // z80_rom: Z80 audio ROM (toggle handshake, 16-bit word; tb_top selects byte)
    ToggleSdramChannel z80_rom_ch(sdram);
    // gfx: GFX ROM (zero-latency combinational; X1-001A pixel-rate access)

    // ── Verilator init ──────────────────────────────────────────────────────
    Verilated::fatalOnError(false);  // suppress fx68k assertion halts during reset

    // ── Instantiate DUT ──────────────────────────────────────────────────────
    Vtb_top* top = new Vtb_top();

    // ── Optional VCD trace ───────────────────────────────────────────────────
    VerilatedVcdC* vcd = nullptr;
    if (env_vcd && env_vcd[0] == '1') {
        Verilated::traceEverOn(true);
        vcd = new VerilatedVcdC();
        top->trace(vcd, 99);
        vcd->open("sim_taito_x.vcd");
        fprintf(stderr, "VCD trace enabled: sim_taito_x.vcd\n");
    }

    // ── Initial port state ───────────────────────────────────────────────────
    top->clk_sys        = 0;
    top->clk_pix        = 0;
    top->reset_n        = 0;

    // Bus bypass: disabled — CPU reads through taito_x RTL data mux + DTACK
    top->bypass_en      = 0;
    top->bypass_data    = 0xFFFF;
    top->bypass_dtack_n = 1;

    // Clock enables: driven from C++
    top->enPhi1  = 0;
    top->enPhi2  = 0;
    top->z80_cen = 0;

    // SDRAM inputs
    top->sdr_data     = 0;
    top->sdr_ack      = 0;
    top->z80_rom_data = 0;
    top->z80_rom_ack  = 0;
    top->gfx_data     = 0;
    top->gfx_ack      = 0;

    // Player inputs — all active-low: release all buttons/coins
    top->joystick_p1 = 0xFF;
    top->joystick_p2 = 0xFF;
    top->coin        = 0x3;
    top->service     = 1;
    top->dipsw1      = 0xFF;
    top->dipsw2      = 0xFF;

    // ── Simulation state ─────────────────────────────────────────────────────
    int      frame_num       = 0;
    bool     done            = false;
    uint64_t iter            = 0;
    uint64_t vcd_ts          = 0;

    // Clock divider counters
    int      pix_div_cnt     = 0;
    int      z80_div_cnt     = 0;

    // phi toggle (alternating enPhi1/enPhi2 each rising edge)
    bool     phi_toggle      = false;

    // Frame buffer and pixel tracking
    FrameBuffer fb;
    int  fb_x = 0;
    int  fb_y = 0;
    bool prev_hblank = false;
    bool prev_vblank = false;

    // vsync edge detection
    uint8_t vsync_n_prev = 1;

    // Bus diagnostics
    bool    prev_asn_c         = true;
    int     bus_cycles_c       = 0;
    bool    halted_reported_c  = false;
    uint64_t last_bus_iter_c   = 0;
    bool    stall_reported_c   = false;

    // VBlank diagnostics
    bool     prev_vblank_diag  = false;
    int      vblank_count      = 0;
    uint64_t last_vblank_iter  = 0;

    static constexpr int RESET_ITERS = 20;

    top->reset_n = 0;

    // ========================================================================
    // RTL BUS EVAL LOOP — bypass_en=0, CPU reads through taito_x RTL.
    //
    // Follows the working minimal-test clock pattern: enPhi1/enPhi2 set on
    // rising edge, cleared on falling edge.  SDRAM channels tick every rising
    // edge.  Video pixel tracking driven by DUT hblank/vblank outputs.
    // ========================================================================
    fprintf(stderr, "Running RTL BUS eval loop (bypass_en=0)...\n");

    // Budget: ~2M iters/frame (32MHz sys, ~16K bus cycles/frame at ~8MHz CPU).
    // First VBlank can take ~1M iters; each subsequent frame ~1M iters.
    // Use 300M as hard safety limit (matches the original advanced testbench).
    for (iter = 0; iter < 300000000ULL; iter++) {

        // Toggle clock
        top->clk_sys = top->clk_sys ^ 1;

        // Release reset after RESET_ITERS half-cycles
        if (iter >= RESET_ITERS) top->reset_n = 1;

        if (top->clk_sys == 1) {
            // ── Rising edge ──────────────────────────────────────────────────

            // Phi enables (MC68000 at 8 MHz = every rising edge alternates)
            top->enPhi1  = phi_toggle ? 0 : 1;
            top->enPhi2  = phi_toggle ? 1 : 0;
            phi_toggle   = !phi_toggle;

            // Pixel clock enable (8 MHz = every 4 sys clocks)
            ++pix_div_cnt;
            if (pix_div_cnt >= PIX_DIV) {
                pix_div_cnt   = 0;
                top->clk_pix  = 1;
            } else {
                top->clk_pix  = 0;
            }

            // Z80 clock enable (4 MHz = every 8 sys clocks)
            ++z80_div_cnt;
            if (z80_div_cnt >= Z80_DIV) {
                z80_div_cnt   = 0;
                top->z80_cen  = 1;
            } else {
                top->z80_cen  = 0;
            }

            // ── SDRAM channels (tick every rising edge) ───────────────────────
            {
                auto r = sdr_ch.tick(top->sdr_req, (uint32_t)top->sdr_addr);
                top->sdr_data = r.data;
                top->sdr_ack  = r.ack;
            }
            {
                auto r = z80_rom_ch.tick(top->z80_rom_req, (uint32_t)top->z80_rom_addr);
                top->z80_rom_data = r.data;
                top->z80_rom_ack  = r.ack;
            }
            {
                // GFX ROM: zero-latency combinational read.
                // X1-001A pixel-rate access; ack same cycle as req is seen.
                // GFX ROM is at SDRAM base 0x100000; gfx_addr is an 18-bit word address.
                uint32_t gfx_byte_addr = 0x100000u + ((uint32_t)top->gfx_addr << 1);
                top->gfx_data = sdram.read_word(gfx_byte_addr & ~1u);
                top->gfx_ack  = top->gfx_req;  // always ack immediately
            }

            // ── VBlank diagnostics ──────────────────────────────────────────────
            {
                bool cur_vblank_diag = (bool)top->vblank;
                if (cur_vblank_diag && !prev_vblank_diag) {
                    // Rising edge of vblank
                    vblank_count++;
                    last_vblank_iter = iter;
                    if (vblank_count <= 5) {
                        fprintf(stderr, "  VBlank #%d at iter=%lu (bc=%d)\n",
                                vblank_count, (unsigned long)iter, bus_cycles_c);
                    }
                }
                prev_vblank_diag = cur_vblank_diag;

                // First 100 clk_pix pulses: log them to verify timing
                static int clkpix_logged = 0;
                if (top->clk_pix && clkpix_logged < 5) {
                    clkpix_logged++;
                    fprintf(stderr, "  clk_pix pulse #%d at iter=%lu\n", clkpix_logged, (unsigned long)iter);
                }
            }

            // ── Bus diagnostics ───────────────────────────────────────────────
            {
                uint8_t  asn_c  = top->dbg_cpu_as_n;
                uint8_t  rwn_c  = top->dbg_cpu_rw;
                uint32_t addr_c = ((uint32_t)top->dbg_cpu_addr << 1) & 0xFFFFFF;

                if (!prev_asn_c && asn_c) {
                    bus_cycles_c++;
                }

                // Log first 200 bus cycles
                bool log_this = (!asn_c && prev_asn_c && iter > RESET_ITERS) &&
                    (bus_cycles_c < 200);
                if (log_this) {
                    fprintf(stderr, "  [%6lu|bc%d] ASn=0 RW=%d addr=%06X dtack_n=%d dout=%04X\n",
                            (unsigned long)iter, bus_cycles_c, (int)rwn_c, addr_c,
                            (int)top->dbg_cpu_dtack_n, (unsigned)(top->dbg_cpu_dout));
                }

                // Track palette writes (0xB00000–0xB00FFF)
                // Track WRAM writes (0xF00000–0xF03FFF for Gigandes)
                static int pal_wr_count_c = 0;
                static int wram_wr_count_c = 0;
                if (!asn_c && !rwn_c && prev_asn_c) {
                    if (addr_c >= 0xB00000 && addr_c <= 0xB00FFF) {
                        ++pal_wr_count_c;
                        if (pal_wr_count_c <= 5)
                            fprintf(stderr, "  PAL WR #%d addr=%06X data=%04X @iter=%lu\n",
                                    pal_wr_count_c, addr_c, (unsigned)top->dbg_cpu_din,
                                    (unsigned long)iter);
                    }
                    if ((addr_c >= 0xF00000 && addr_c <= 0xF03FFF) ||
                        (addr_c >= 0x100000 && addr_c <= 0x10FFFF)) {
                        ++wram_wr_count_c;
                        if (wram_wr_count_c <= 3)
                            fprintf(stderr, "  WRAM WR #%d addr=%06X @iter=%lu bc=%d\n",
                                    wram_wr_count_c, addr_c, (unsigned long)iter, bus_cycles_c);
                    }
                }

                // Sample CPU PC every 100K bus cycles to see where it's looping
                static int last_sampled_bc = 0;
                if (bus_cycles_c > 0 && (bus_cycles_c - last_sampled_bc) >= 100000 && prev_asn_c && asn_c) {
                    last_sampled_bc = bus_cycles_c;
                    fprintf(stderr, "  [%dK bus] last_addr=%06X pal_wr=%d wram_wr=%d frame=%d vblank=%d vblank_count=%d\n",
                            bus_cycles_c/1000, addr_c, pal_wr_count_c, wram_wr_count_c,
                            frame_num, (int)top->vblank, vblank_count);
                }

                // Periodic write summary (less verbose now)
                if (bus_cycles_c > 0 && (bus_cycles_c % 1000000) == 0 && prev_asn_c && asn_c) {
                    fprintf(stderr, "  [%dM bus] pal_wr=%d wram_wr=%d frame=%d\n",
                            bus_cycles_c/1000000, pal_wr_count_c, wram_wr_count_c, frame_num);
                }

                // Detect CPU halt (double bus fault)
                if (top->dbg_cpu_halted_n == 0 && iter > RESET_ITERS + 100 && !halted_reported_c) {
                    halted_reported_c = true;
                    fprintf(stderr, "\n*** CPU HALTED at iter %lu (bus_cycles=%d) ***\n",
                            (unsigned long)iter, bus_cycles_c);
                }

                // Track last bus cycle iter
                if (!asn_c) last_bus_iter_c = iter;

                // Detect stall: no AS_n assertion for 1M iters after reset
                if (iter > RESET_ITERS + 1000000 && bus_cycles_c > 0 &&
                    (iter - last_bus_iter_c) > 1000000 && !stall_reported_c) {
                    stall_reported_c = true;
                    fprintf(stderr, "\n*** CPU STALL: no AS_n for 1M iters after bc=%d (iter=%lu) ***\n",
                            bus_cycles_c, (unsigned long)iter);
                    fprintf(stderr, "    halted_n=%d  last_bus_iter=%lu\n",
                            (int)top->dbg_cpu_halted_n, (unsigned long)last_bus_iter_c);
                    // Dump current CPU signals
                    fprintf(stderr, "    Current: AS_n=%d RW=%d addr=%06X dtack_n=%d\n",
                            (int)top->dbg_cpu_as_n, (int)top->dbg_cpu_rw,
                            ((uint32_t)top->dbg_cpu_addr << 1) & 0xFFFFFF,
                            (int)top->dbg_cpu_dtack_n);
                }

                prev_asn_c = asn_c;
            }

        } else {
            // ── Falling edge ─────────────────────────────────────────────────
            top->enPhi1  = 0;
            top->enPhi2  = 0;
            top->clk_pix = 0;
            top->z80_cen = 0;
        }

        top->eval();
        if (vcd) vcd->dump((vluint64_t)vcd_ts);
        ++vcd_ts;

        // ── Pixel capture (on rising edge, after eval) ────────────────────────
        if (top->clk_sys == 1) {
            // Capture active-display pixels directly using DUT's hblank/vblank.
            // Track X/Y position by counting pixels inside the active window.
            bool cur_hblank = (bool)top->hblank;
            bool cur_vblank = (bool)top->vblank;

            // Detect transitions for position tracking
            if (!prev_vblank && cur_vblank) {
                // Start of VBlank: reset Y
                fb_y = 0;
            }
            if (!prev_hblank && cur_hblank && !cur_vblank) {
                // End of active line: advance Y
                fb_y++;
                fb_x = 0;
            }

            // Capture pixel when in active region
            bool active = (!cur_hblank) && (!cur_vblank);
            if (active && top->clk_pix) {
                fb.set(fb_x, fb_y, top->rgb_r, top->rgb_g, top->rgb_b);
                fb_x++;
            }

            prev_hblank = cur_hblank;
            prev_vblank = cur_vblank;
        }

        // ── Vsync edge detection → frame save ────────────────────────────────
        {
            uint8_t vsync_n_now = top->vsync_n;
            if (vsync_n_prev == 1 && vsync_n_now == 0) {
                char fname[64];
                snprintf(fname, sizeof(fname), "frame_%04d.ppm", frame_num);
                if (fb.write_ppm(fname))
                    fprintf(stderr, "Frame %4d written: %s  (bus_cycles=%d)\n",
                            frame_num, fname, bus_cycles_c);

                ++frame_num;
                if (frame_num >= n_frames) done = true;
                fb = FrameBuffer();
                fb_x = 0;
                fb_y = 0;
            }
            vsync_n_prev = vsync_n_now;
        }

        if (done) break;

        if ((iter % 2000000) == 0 && iter > 0) {
            fprintf(stderr, "  iter %lu  bus_cycles=%d  frame=%d\n",
                    (unsigned long)iter, bus_cycles_c, frame_num);
        }
    }

    // ── Final cleanup ────────────────────────────────────────────────────────
    if (vcd) {
        vcd->close();
        delete vcd;
    }
    top->final();
    delete top;

    fprintf(stderr, "Simulation complete. %d frames captured, %lu iters (%d bus cycles).\n",
            frame_num, (unsigned long)iter, bus_cycles_c);
    return 0;
}
