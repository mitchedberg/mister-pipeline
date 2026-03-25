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
#include "Vtb_top_tb_top.h"
#include "Vtb_top_fx68k.h"
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
// RAM Dump Helpers
// =============================================================================
// Write a 16-bit word as two bytes in 68000 big-endian order (MSB first).
static inline void write_word_be(FILE* f, uint16_t w) {
    uint8_t b[2] = { (uint8_t)(w >> 8), (uint8_t)(w & 0xFF) };
    fwrite(b, 1, 2, f);
}

// Write N zero bytes.
static inline void write_zeros(FILE* f, size_t n) {
    static const uint8_t zero_buf[4096] = {};
    while (n >= sizeof(zero_buf)) {
        fwrite(zero_buf, 1, sizeof(zero_buf), f);
        n -= sizeof(zero_buf);
    }
    if (n > 0)
        fwrite(zero_buf, 1, n, f);
}

// Dump one frame's RAM state to binary file.
// Format per frame: [4B LE frame#][32KB work RAM][8KB palette RAM]
// Note: TAITO_B_PRESENT must be defined at compile time (via CFLAGS -DTAITO_B_PRESENT)
// to enable the actual RAM dump. Without it, all regions write zeros.
#define TAITO_B_PRESENT
static void dump_frame_ram(FILE* f, uint32_t frame_num, Vtb_top* top) {
    // Access the Verilator-generated tb_top sub-module that holds all internal state.
    // (In Verilator 5.x, internal arrays migrated from rootp to tb_top.)
    auto* r = top->tb_top;

    // ── 4-byte LE frame number ───────────────────────────────────────────────
    uint8_t frame_le[4] = {
        (uint8_t)(frame_num & 0xFF),
        (uint8_t)((frame_num >> 8) & 0xFF),
        (uint8_t)((frame_num >> 16) & 0xFF),
        (uint8_t)((frame_num >> 24) & 0xFF)
    };
    fwrite(frame_le, 1, 4, f);

    // In isolation mode (no taito_b), write zeros for all regions to keep
    // the binary format consistent.
#ifdef TAITO_B_PRESENT
    // Work RAM: 32KB = 16384 words at 0x600000-0x607FFF
    for (int i = 0; i < 16384; i++)
        write_word_be(f, (uint16_t)r->__PVT__u_taito_b__DOT__work_ram[i]);
    // Palette RAM: 8KB = 4096 words at 0x200000-0x201FFF (TC0260DAR external palette)
    for (int i = 0; i < 4096; i++)
        write_word_be(f, (uint16_t)r->__PVT__u_taito_b__DOT__pal_ram[i]);
#else
    write_zeros(f, 32768);  // work RAM (16384 words × 2 bytes)
    write_zeros(f, 8192);   // palette RAM (4096 words × 2 bytes)
#endif
}

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
    const char* env_ram_dump = getenv("RAM_DUMP");

    int n_frames = env_frames ? atoi(env_frames) : 30;
    if (n_frames < 1) n_frames = 1;

    fprintf(stderr, "Taito B (Nastar) simulation: %d frames\n", n_frames);

    // ── Optional RAM dump file ───────────────────────────────────────────────
    FILE* ram_dump_f = nullptr;
    if (env_ram_dump) {
        ram_dump_f = fopen(env_ram_dump, "wb");
        if (!ram_dump_f) {
            fprintf(stderr, "ERROR: cannot open RAM_DUMP file: %s\n", env_ram_dump);
        } else {
            fprintf(stderr, "RAM dump enabled: %s\n", env_ram_dump);
            fprintf(stderr, "  Format: 4B frame# + 32KB wram + 8KB palette\n");
            fprintf(stderr, "  (matches mame_ram_dump.lua layout for byte-by-byte comparison)\n");
        }
    }

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

                // Track reads from non-ROM addresses (WRAM, VCU, IOC, palette)
                static int nonrom_rd_count = 0;
                if (!asn && rwn && prev_asn && addr >= 0x200000) {
                    ++nonrom_rd_count;
                    if (nonrom_rd_count <= 500)
                        fprintf(stderr, "  RD#%d addr=%06X dout=%04X bc=%d\n",
                                nonrom_rd_count, addr, (unsigned)(top->dbg_cpu_dout & 0xFFFF),
                                bus_cycles);
                }

                // Track writes to key address ranges
                static int pal_wr_count = 0;
                static int wram_wr_count = 0;
                static int all_wr_count  = 0;
                if (!asn && !rwn && prev_asn) {
                    ++all_wr_count;
                    // Log ALL non-WRAM writes (WRAM suppressed after first 14)
                    bool is_wram = (addr >= 0x600000 && addr <= 0x607FFF);
                    if (!is_wram)
                        fprintf(stderr, "  WR#%d addr=%06X data=%04X bc=%d\n",
                                all_wr_count, addr, (unsigned)top->dbg_cpu_din,
                                bus_cycles);
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
                    auto* r = top->tb_top;
                    int ipl_h = (int)r->__PVT__u_taito_b__DOT__ipl_h_active;
                    int ipl_sync = (int)r->__PVT__u_taito_b__DOT__ipl_sync & 7;
                    fprintf(stderr, "  [%dK bus] pal_wr=%d wram_wr=%d frame=%d ipl_h=%d ipl_sync=%d\n",
                            bus_cycles/1000, pal_wr_count, wram_wr_count, frame_num, ipl_h, ipl_sync);
                }

                // Log when interrupt state changes + key VCU events
                {
                    auto* r = top->tb_top;
                    static int prev_ipl_h = 0;
                    static int prev_ipl_sync = 7;
                    int ipl_h        = (int)r->__PVT__u_taito_b__DOT__ipl_h_active;
                    int ipl_syn      = (int)r->__PVT__u_taito_b__DOT__ipl_sync & 7;
                    int vcu_ih       = (int)r->__PVT__u_taito_b__DOT__vcu_int_h;
                    if (vcu_ih)
                        fprintf(stderr, "  *** VCU int_h PULSE bc=%d frame=%d\n", bus_cycles, frame_num);
                    if (ipl_h != prev_ipl_h) {
                        fprintf(stderr, "  *** ipl_h_active: %d->%d  bc=%d frame=%d\n",
                                prev_ipl_h, ipl_h, bus_cycles, frame_num);
                        prev_ipl_h = ipl_h;
                    }
                    if (ipl_syn != prev_ipl_sync) {
                        fprintf(stderr, "  *** ipl_sync: %d->%d  bc=%d frame=%d\n",
                                prev_ipl_sync, ipl_syn, bus_cycles, frame_num);
                        prev_ipl_sync = ipl_syn;
                    }
                }

                // Targeted stall-zone diagnostics: only when bc is near the stall zone
                if (bus_cycles >= 2059000 && bus_cycles <= 2065000) {
                    auto* rtb = top->tb_top;
                    auto* rcpu = rtb->u_cpu;
                    int dar_cs_r  = (int)rtb->__PVT__u_taito_b__DOT__u_dar__DOT__CS;
                    int dar_busy  = (int)rtb->__PVT__u_taito_b__DOT__u_dar__DOT__busy;
                    int dar_ca    = (int)rtb->__PVT__u_taito_b__DOT__u_dar__DOT__cpu_access;
                    int cpu_int_pend = (int)rcpu->intPend;
                    int cpu_pswI     = (int)rcpu->pswI & 7;
                    int cpu_iIpl     = (int)rcpu->iIpl & 7;
                    int cpu_rIpl     = (int)rcpu->rIpl & 7;
                    int cpu_rInt     = (int)rcpu->__PVT__sequencer__DOT__rInterrupt;
                    int cpu_asn      = (int)top->dbg_cpu_as_n;
                    int cpu_fc       = ((int)rtb->u_cpu->__PVT__FC2 << 2) |
                                       ((int)rtb->u_cpu->__PVT__FC1 << 1) |
                                        (int)rtb->u_cpu->__PVT__FC0;
                    static uint64_t stall_zone_last = 0;
                    uint32_t cpu_addr2 = ((uint32_t)top->dbg_cpu_addr << 1) & 0xFFFFFF;
                    if (iter - stall_zone_last >= 500) {
                        stall_zone_last = iter;
                        fprintf(stderr,
                            "  STALL bc=%d addr=%06X CS=%d busy=%d ca=%d intPend=%d pswI=%d iIpl=%d rIpl=%d rInt=%d ASn=%d FC=%d dtack_n=%d\n",
                            bus_cycles, cpu_addr2, dar_cs_r, dar_busy, dar_ca,
                            cpu_int_pend, cpu_pswI, cpu_iIpl, cpu_rIpl, cpu_rInt, cpu_asn, cpu_fc,
                            (int)top->dbg_cpu_dtack_n);
                    }
                }

                // Stuck-DTACK detector: if ASn=0 and DTACKn=1 for >10000 consecutive
                // rising edges, report the stalling address. Only fires once per address.
                {
                    static uint64_t dtack_stall_start = 0;
                    static uint32_t dtack_stall_addr  = 0xFFFFFFFF;
                    static bool     dtack_stall_reported = false;
                    if (!asn && top->dbg_cpu_dtack_n) {
                        if (dtack_stall_start == 0) {
                            dtack_stall_start = iter;
                            dtack_stall_addr  = addr;
                        } else if (!dtack_stall_reported &&
                                   (iter - dtack_stall_start) > 10000) {
                            dtack_stall_reported = true;
                            auto* r2 = top->tb_top;
                            int ipl_sync2 = (int)r2->__PVT__u_taito_b__DOT__ipl_sync & 7;
                            int ipl_h2    = (int)r2->__PVT__u_taito_b__DOT__ipl_h_active;
                            fprintf(stderr,
                                "*** STUCK DTACK: addr=%06X RW=%d iter=%lu bc=%d "
                                "(stalled for %lu iters) ipl_sync=%d ipl_h=%d\n",
                                dtack_stall_addr, (int)rwn,
                                (unsigned long)iter, bus_cycles,
                                (unsigned long)(iter - dtack_stall_start),
                                ipl_sync2, ipl_h2);
                        }
                    } else {
                        dtack_stall_start   = 0;
                        dtack_stall_reported = false;
                    }
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
        if (vcd) vcd->dump((uint64_t)vcd_ts);
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

                // ── Per-frame RAM dump (matches mame_ram_dump.lua format) ─────────
                if (ram_dump_f) {
                    dump_frame_ram(ram_dump_f, (uint32_t)frame_num, top);
                    if ((frame_num % 10) == 0)
                        fflush(ram_dump_f);
                }

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
    if (ram_dump_f) {
        fclose(ram_dump_f);
        fprintf(stderr, "RAM dump file closed: %lu bytes written (%d frames)\n",
                (unsigned long)(frame_num * (4 + 32768 + 8192)), frame_num);
    }
    top->final();
    delete top;

    fprintf(stderr, "Simulation complete. %d frames captured, %lu iters (%d bus cycles).\n",
            frame_num, (unsigned long)iter, bus_cycles);
    return 0;
}
