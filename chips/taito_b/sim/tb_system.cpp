// =============================================================================
// tb_system.cpp — Taito B (Nastar Warrior) full-system Verilator testbench
//
// Wraps tb_top.sv (which includes taito_b + fx68k CPU) and drives:
//   - Clock (32 MHz) and reset
//   - Video timing generator (320×240 @ ~60 Hz, H_TOTAL=416, V_TOTAL=264)
//   - Four SDRAM channels (ToggleSdramChannel behavioral model, all 16-bit)
//   - Sound clock enable: 4 MHz (1 pulse every 8 sys clocks)
//   - clk_pix2x: driven high every cycle (TC0260DAR ce_double stub)
//   - Player inputs (all held at 0xFF = no input, active-low)
//
// The CPU (fx68k) and Z80 (T80s) are inside tb_top.sv/taito_b.sv and execute
// the real Nastar Warrior ROMs.
//
// SDRAM layout (from nastar.mra / emu.sv):
//   0x000000 — CPU program ROM (512KB, interleaved even/odd)
//   0x080000 — Z80 audio program ROM (64KB)
//   0x100000 — TC0180VCU GFX ROM (1MB)
//   0x200000 — ADPCM-A samples (512KB, ymsnd:adpcma)
//   0x280000 — ADPCM-B samples (512KB, ymsnd:adpcmb)
//
// Environment variables:
//   N_FRAMES   — number of vertical frames to simulate (default 30)
//   ROM_PROG   — path to CPU program ROM binary  (SDRAM 0x000000, interleaved 16-bit)
//   ROM_Z80    — path to Z80 audio ROM binary    (SDRAM 0x080000)
//   ROM_GFX    — path to GFX ROM binary          (SDRAM 0x100000)
//   ROM_ADPCM  — path to ADPCM ROM binary        (SDRAM 0x200000, A+B concatenated)
//   DUMP_VCD   — set to "1" to enable VCD trace (slow)
//
// Output:
//   frame_NNNN.ppm — one PPM file per vertical frame
//
// Video resolution: 320×240 (Taito B native)
//   Horizontal: 320 active + 96 blanking = 416 total (H_BLANK=24+32+40)
//   Vertical:   240 active + 24 blanking = 264 total (V_BLANK=12+4+8)
//   At 32 MHz sys clock, pixel clock divider = 5 → 6.4 MHz pixel clock
//   clk_sound: one pulse every 8 sys clocks → 4 MHz
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

// ── Video timing constants (Taito B 320×240) ────────────────────────────────
static constexpr int VID_H_ACTIVE  = 320;
static constexpr int VID_V_ACTIVE  = 240;
static constexpr int VID_H_TOTAL   = 416;   // 320 + 24 + 32 + 40
static constexpr int VID_V_TOTAL   = 264;   // 240 + 12 + 4 + 8
static constexpr int VID_HSYNC_START = VID_H_ACTIVE + 24;   // after 24 front-porch
static constexpr int VID_HSYNC_END   = VID_HSYNC_START + 32;
static constexpr int VID_VSYNC_START = VID_V_ACTIVE + 12;   // after 12 front-porch
static constexpr int VID_VSYNC_END   = VID_VSYNC_START + 4;

// Pixel clock: one pixel every 5 system clocks (~6.4 MHz from 32 MHz)
static constexpr int PIX_DIV = 5;
// Sound clock: one pulse every 8 system clocks (4 MHz from 32 MHz)
static constexpr int SND_DIV = 8;

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
// main
// =============================================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    // ── Configuration from environment ──────────────────────────────────────
    const char* env_frames = getenv("N_FRAMES");
    const char* env_prog   = getenv("ROM_PROG");
    const char* env_z80    = getenv("ROM_Z80");
    const char* env_gfx    = getenv("ROM_GFX");
    const char* env_adpcm  = getenv("ROM_ADPCM");
    const char* env_vcd    = getenv("DUMP_VCD");

    int n_frames = env_frames ? atoi(env_frames) : 30;
    if (n_frames < 1) n_frames = 1;

    fprintf(stderr, "Taito B (Nastar) simulation: %d frames\n", n_frames);

    // ── Load ROM data ────────────────────────────────────────────────────────
    SdramModel sdram;
    if (env_prog)  sdram.load(env_prog,  0x000000);   // CPU program ROM (512KB interleaved)
    if (env_z80)   sdram.load(env_z80,   0x080000);   // Z80 audio ROM (64KB)
    if (env_gfx)   sdram.load(env_gfx,   0x100000);   // GFX ROM (1MB)
    if (env_adpcm) sdram.load(env_adpcm, 0x200000);   // ADPCM-A+B samples (up to 1MB)

    // ── SDRAM channels ───────────────────────────────────────────────────────
    // All four channels use 16-bit toggle handshake.
    // taito_b internally selects the correct byte for Z80 ROM reads.
    ToggleSdramChannel prog_ch(sdram);   // CPU program ROM
    ToggleSdramChannel gfx_ch(sdram);    // TC0180VCU GFX ROM
    ToggleSdramChannel sdr_ch(sdram);    // TC0140SYT ADPCM (sdr_addr/data/req/ack)
    ToggleSdramChannel z80_ch(sdram);    // Z80 audio ROM (16-bit, byte selected in RTL)

    // ── Verilator init ──────────────────────────────────────────────────────
    Verilated::fatalOnError(false);  // suppress fx68k assertion halts during CPU reset

    // ── Instantiate DUT ──────────────────────────────────────────────────────
    Vtb_top* top = new Vtb_top();

    // ── Optional VCD trace ───────────────────────────────────────────────────
    VerilatedVcdC* vcd = nullptr;
    if (env_vcd && env_vcd[0] == '1') {
        Verilated::traceEverOn(true);
        vcd = new VerilatedVcdC();
        top->trace(vcd, 99);
        vcd->open("sim_taito_b.vcd");
        fprintf(stderr, "VCD trace enabled: sim_taito_b.vcd\n");
    }

    // ── Initial port state ───────────────────────────────────────────────────
    top->clk_sys       = 0;
    top->reset_n       = 0;

    // Bus bypass: disabled — CPU reads through taito_b RTL data mux + DTACK
    top->bypass_en      = 0;
    top->bypass_data    = 0xFFFF;
    top->bypass_dtack_n = 1;

    // Clock enables: driven from C++
    top->enPhi1    = 0;
    top->enPhi2    = 0;
    top->clk_sound = 0;
    top->clk_pix   = 0;
    top->clk_pix2x = 1;   // TC0260DAR ce_double stub: always asserted

    // SDRAM inputs
    top->prog_rom_data = 0;
    top->prog_rom_ack  = 0;
    top->gfx_rom_data  = 0;
    top->gfx_rom_ack   = 0;
    top->sdr_data      = 0;
    top->sdr_ack       = 0;
    top->z80_rom_data  = 0;
    top->z80_rom_ack   = 0;

    // Video timing inputs
    top->hblank_n_in   = 1;
    top->vblank_n_in   = 1;
    top->hpos          = 0;
    top->vpos          = 0;
    top->hsync_n_in    = 1;
    top->vsync_n_in    = 1;

    // Player inputs — all active-low: release all buttons/coins
    top->joystick_p1   = 0xFF;
    top->joystick_p2   = 0xFF;
    top->coin          = 0x3;   // both coins inactive (active low)
    top->service       = 1;
    top->dipsw1        = 0xFF;
    top->dipsw2        = 0xFF;

    // ── Simulation state ─────────────────────────────────────────────────────
    int      frame_num  = 0;
    bool     done       = false;

    // Video timing counters
    int  hcnt           = 0;
    int  vcnt           = 0;
    int  pix_div_cnt    = 0;
    int  snd_div_cnt    = 0;

    // Frame buffer and vsync edge detection
    FrameBuffer fb;
    uint8_t vsync_n_prev = 1;

    // Bus diagnostics state
    bool     phi_toggle      = false;
    bool     prev_asn        = true;
    int      bus_cycles      = 0;
    uint64_t iter            = 0;
    bool     halted_reported = false;
    static constexpr int RESET_ITERS = 20;

    uint64_t vcd_ts = 0;

    top->reset_n = 0;

    fprintf(stderr, "Running RTL BUS eval loop (bypass_en=0)...\n");

    // ========================================================================
    // RTL BUS EVAL LOOP
    // ========================================================================
    // Iteration budget: H_TOTAL=416, V_TOTAL=264, PIX_DIV=5, 2 half-cycles/iter
    // → ~416*264*5*2 = 1,098,240 iters/frame. Use 1.2M for margin.
    for (iter = 0; iter < (uint64_t)n_frames * 1200000ULL; iter++) {
        // Toggle clock
        top->clk_sys = top->clk_sys ^ 1;

        // Release reset after RESET_ITERS half-cycles
        if (iter >= RESET_ITERS) top->reset_n = 1;

        if (top->clk_sys == 1) {
            // ── Rising edge ──────────────────────────────────────────────────

            // Phi enables (matching working minimal-test pattern)
            top->enPhi1 = phi_toggle ? 0 : 1;
            top->enPhi2 = phi_toggle ? 1 : 0;
            phi_toggle  = !phi_toggle;

            // ── Pixel clock enable (/5 from 32 MHz = 6.4 MHz) ─────────────
            ++pix_div_cnt;
            if (pix_div_cnt >= PIX_DIV) {
                pix_div_cnt = 0;
                top->clk_pix = 1;
            } else {
                top->clk_pix = 0;
            }

            // ── Sound clock enable (/8 from 32 MHz = 4 MHz) ───────────────
            ++snd_div_cnt;
            if (snd_div_cnt >= SND_DIV) {
                snd_div_cnt = 0;
                top->clk_sound = 1;
            } else {
                top->clk_sound = 0;
            }

            // ── Video timing ─────────────────────────────────────────────
            // Update on pixel clock pulse
            if (top->clk_pix) {
                bool h_active = (hcnt < VID_H_ACTIVE);
                bool v_active = (vcnt < VID_V_ACTIVE);
                bool hsync    = (hcnt >= VID_HSYNC_START && hcnt < VID_HSYNC_END);
                bool vsync    = (vcnt >= VID_VSYNC_START && vcnt < VID_VSYNC_END);
                bool hblank   = !h_active;
                bool vblank   = !v_active;

                top->hblank_n_in = hblank ? 0 : 1;
                top->vblank_n_in = vblank ? 0 : 1;
                top->hsync_n_in  = hsync  ? 0 : 1;
                top->vsync_n_in  = vsync  ? 0 : 1;
                top->hpos = (uint16_t)(h_active ? hcnt : 0);
                top->vpos = (uint8_t) (v_active ? vcnt : 0);

                ++hcnt;
                if (hcnt >= VID_H_TOTAL) {
                    hcnt = 0;
                    ++vcnt;
                    if (vcnt >= VID_V_TOTAL)
                        vcnt = 0;
                }
            }

            // ── SDRAM channels (tick every rising edge) ───────────────────
            {
                auto r = prog_ch.tick(top->prog_rom_req, top->prog_rom_addr);
                top->prog_rom_data = r.data;
                top->prog_rom_ack  = r.ack;
            }
            {
                auto r = gfx_ch.tick(top->gfx_rom_req, top->gfx_rom_addr);
                top->gfx_rom_data = r.data;
                top->gfx_rom_ack  = r.ack;
            }
            {
                auto r = sdr_ch.tick(top->sdr_req, top->sdr_addr);
                top->sdr_data = r.data;
                top->sdr_ack  = r.ack;
            }
            {
                // Z80 ROM: 16-bit word, taito_b selects correct byte internally
                auto r = z80_ch.tick(top->z80_rom_req, top->z80_rom_addr);
                top->z80_rom_data = r.data;
                top->z80_rom_ack  = r.ack;
            }

            // ── Bus diagnostics ───────────────────────────────────────────
            {
                uint8_t  asn  = top->dbg_cpu_as_n;
                uint8_t  rwn  = top->dbg_cpu_rw;
                uint32_t addr = ((uint32_t)top->dbg_cpu_addr << 1) & 0xFFFFFF;

                if (!prev_asn && asn) {
                    bus_cycles++;
                }

                // Log first 60 bus cycles
                bool log_this = (!asn && prev_asn && iter > RESET_ITERS) &&
                    (bus_cycles < 60);
                if (log_this) {
                    fprintf(stderr, "  [%6lu|bc%d] ASn=0 RW=%d addr=%06X dtack_n=%d dout=%04X\n",
                            (unsigned long)iter, bus_cycles, (int)rwn, addr,
                            (int)top->dbg_cpu_dtack_n,
                            (unsigned)(top->dbg_cpu_dout & 0xFFFF));
                }

                // Track writes to key address ranges
                static int pal_wr_count = 0;
                static int wram_wr_count = 0;
                if (!asn && !rwn && prev_asn) {
                    // Palette RAM: 0x200000-0x201FFF (nastar)
                    if (addr >= 0x200000 && addr <= 0x201FFF) {
                        ++pal_wr_count;
                        if (pal_wr_count <= 5)
                            fprintf(stderr, "  PAL WR #%d addr=%06X data=%04X @iter=%lu\n",
                                    pal_wr_count, addr, (unsigned)top->dbg_cpu_din,
                                    (unsigned long)iter);
                    }
                    // Work RAM: 0x600000-0x607FFF (nastar)
                    if (addr >= 0x600000 && addr <= 0x607FFF) {
                        ++wram_wr_count;
                        if (wram_wr_count <= 3)
                            fprintf(stderr, "  WRAM WR #%d addr=%06X @iter=%lu\n",
                                    wram_wr_count, addr, (unsigned long)iter);
                    }
                }

                // Periodic write summary
                if (bus_cycles > 0 && (bus_cycles % 50000) == 0 && prev_asn && asn) {
                    fprintf(stderr, "  [%dK bus] pal_wr=%d wram_wr=%d frame=%d\n",
                            bus_cycles/1000, pal_wr_count, wram_wr_count, frame_num);
                }

                // Detect CPU halt (double bus fault)
                if (top->dbg_cpu_halted_n == 0 && iter > (uint64_t)RESET_ITERS + 100 &&
                    !halted_reported) {
                    halted_reported = true;
                    fprintf(stderr, "\n*** CPU HALTED at iter %lu (bus_cycles=%d) ***\n",
                            (unsigned long)iter, bus_cycles);
                }

                prev_asn = asn;
            }

        } else {
            // ── Falling edge ─────────────────────────────────────────────────
            top->enPhi1    = 0;
            top->enPhi2    = 0;
            top->clk_pix   = 0;
            top->clk_sound = 0;
        }

        top->eval();
        if (vcd) vcd->dump((vluint64_t)vcd_ts);
        ++vcd_ts;

        // ── Pixel capture (on pixel clock edge only, using C++-driven timing) ──
        // Use C++-driven hcnt/vcnt for position (not RTL's delayed hblank/vblank
        // outputs from TC0260DAR's 3-stage pipeline). Only capture on clk_pix
        // edges since that's when the TC0260DAR latches valid pixel data.
        if (top->clk_sys == 1 && top->clk_pix) {
            bool h_active = (hcnt > 0 ? hcnt - 1 : VID_H_TOTAL - 1) < VID_H_ACTIVE;
            bool v_active = (vcnt < VID_V_ACTIVE);
            if (h_active && v_active) {
                int cx = (hcnt > 0 ? hcnt - 1 : VID_H_TOTAL - 1);
                int cy = vcnt;
                if (cx >= 0 && cx < VID_H_ACTIVE && cy >= 0 && cy < VID_V_ACTIVE)
                    fb.set(cx, cy, top->rgb_r, top->rgb_g, top->rgb_b);
            }
        }

        // ── Vsync edge detection → frame save ────────────────────────────
        {
            uint8_t vsync_n_now = top->vsync_n;
            if (vsync_n_prev == 1 && vsync_n_now == 0) {
                char fname[64];
                snprintf(fname, sizeof(fname), "frame_%04d.ppm", frame_num);
                if (fb.write_ppm(fname))
                    fprintf(stderr, "Frame %4d written: %s  (bus_cycles=%d)\n",
                            frame_num, fname, bus_cycles);
                ++frame_num;
                if (frame_num >= n_frames) done = true;
                fb = FrameBuffer();
            }
            vsync_n_prev = vsync_n_now;
        }

        if (done) break;

        if ((iter % 2000000) == 0 && iter > 0) {
            fprintf(stderr, "  iter %lu  bus_cycles=%d  frame=%d\n",
                    (unsigned long)iter, bus_cycles, frame_num);
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
            frame_num, (unsigned long)iter, bus_cycles);
    return 0;
}
