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
    top->dipsw1      = 0xDF;  // Gigandes default: difficulty=Easy, debug=Off (MAME default)
    top->dipsw2      = 0x98;  // Gigandes default: 3 lives, demo sounds ON, flip screen OFF

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

    // Budget: ~1.5M iters/frame (empirical: Gigandes takes ~1.1M iters/frame at 16 iters/bus_cycle)
    // Hard cap at 2M iters/frame to prevent infinite loops on genuine stalls
    for (iter = 0; iter < (uint64_t)n_frames * 1500000ULL; iter++) {

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
                static uint8_t prev_sdr_req = 0;
                static int sdr_tick_count = 0;
                bool req_changed = (top->sdr_req != prev_sdr_req);
                prev_sdr_req = top->sdr_req;
                auto r = sdr_ch.tick(top->sdr_req, (uint32_t)top->sdr_addr);
                top->sdr_data = r.data;
                top->sdr_ack  = r.ack;
                if (req_changed && sdr_tick_count < 20) {
                    fprintf(stderr, "  SDR tick#%d @iter=%lu: req=%d addr=0x%06X -> data=0x%04X ack=%d\n",
                            sdr_tick_count, (unsigned long)iter,
                            (int)top->sdr_req, (unsigned)top->sdr_addr,
                            (unsigned)r.data, (int)r.ack);
                    sdr_tick_count++;
                }
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

            // ── Bus diagnostics ───────────────────────────────────────────────
            {
                uint8_t  asn_c  = top->dbg_cpu_as_n;
                uint8_t  rwn_c  = top->dbg_cpu_rw;
                uint32_t addr_c = ((uint32_t)top->dbg_cpu_addr << 1) & 0xFFFFFF;

                if (!prev_asn_c && asn_c) {
                    bus_cycles_c++;
                }

                // Log first 200 bus cycles only
                bool log_this = (!asn_c && prev_asn_c && iter > RESET_ITERS) &&
                    (bus_cycles_c < 200);
                if (log_this) {
                    fprintf(stderr, "  [%6lu|bc%d] ASn=0 RW=%d addr=%06X dtack_n=%d dout=%04X\n",
                            (unsigned long)iter, bus_cycles_c, (int)rwn_c, addr_c,
                            (int)top->dbg_cpu_dtack_n, (unsigned)(top->dbg_cpu_dout));
                }

                // Log VBlank handler entry (addr 0x0005D4 = first word of VBlank handler)
                static int vblank_entry_count = 0;
                if (!asn_c && prev_asn_c && rwn_c &&
                    (addr_c == 0x0005D4 || addr_c == 0x0005D6) &&
                    vblank_entry_count < 5) {
                    ++vblank_entry_count;
                    fprintf(stderr, "  *** VBlank handler addr=%06X entry#%d bc=%d iter=%lu\n",
                            addr_c, vblank_entry_count, bus_cycles_c, (unsigned long)iter);
                }
                // Track palette-load callsite (0x01CD0E/0x01CD30 call 0x04E2)
                static int pal_load_count = 0;
                if (!asn_c && prev_asn_c && rwn_c &&
                    (addr_c >= 0x01CD00 && addr_c <= 0x01CD40) &&
                    pal_load_count < 10) {
                    ++pal_load_count;
                    fprintf(stderr, "  *** PAL-LOAD callsite addr=%06X #%d bc=%d frame=%d\n",
                            addr_c, pal_load_count, bus_cycles_c, frame_num);
                }
                // Track game main loop area (0x001330-0x001400)
                static int mainloop_count = 0;
                if (!asn_c && prev_asn_c && rwn_c &&
                    (addr_c >= 0x001330 && addr_c <= 0x001400) &&
                    mainloop_count < 5) {
                    ++mainloop_count;
                    fprintf(stderr, "  *** MAINLOOP addr=%06X #%d bc=%d frame=%d\n",
                            addr_c, mainloop_count, bus_cycles_c, frame_num);
                }
                // Track writes to key WRAM flags: 0x002E (palette flag), 0x0036 (sprite flag)
                static int flag_wr_count = 0;
                if (!asn_c && !rwn_c && prev_asn_c) {
                    // Flag at F0002E: when set to 1, triggers palette DMA in VBlank
                    if (addr_c == 0xF0002E || addr_c == 0xF00030) {
                        ++flag_wr_count;
                        fprintf(stderr, "  FLAG WR addr=%06X val=%04X @bc=%d frame=%d\n",
                                addr_c, (unsigned)top->dbg_cpu_din, bus_cycles_c, frame_num);
                    }
                    // Flag at F00036: when set to 1, triggers sprite DMA
                    if (addr_c == 0xF00036 || addr_c == 0xF00038) {
                        ++flag_wr_count;
                        fprintf(stderr, "  FLAG WR addr=%06X val=%04X @bc=%d frame=%d\n",
                                addr_c, (unsigned)top->dbg_cpu_din, bus_cycles_c, frame_num);
                    }
                }

                // Track palette writes (0xB00000–0xB00FFF)
                static int pal_wr_count_c = 0;
                static int pal_nonzero_count_c = 0;
                static int wram_wr_count_c = 0;
                if (!asn_c && !rwn_c && prev_asn_c) {
                    if (addr_c >= 0xB00000 && addr_c <= 0xB00FFF) {
                        ++pal_wr_count_c;
                        uint16_t pal_data = (uint16_t)top->dbg_cpu_din;
                        // Log first 5 writes (for init detection)
                        if (pal_wr_count_c <= 5)
                            fprintf(stderr, "  PAL WR #%d addr=%06X data=%04X @iter=%lu\n",
                                    pal_wr_count_c, addr_c, (unsigned)pal_data,
                                    (unsigned long)iter);
                        // Log non-zero palette writes (these are real color data)
                        if (pal_data != 0) {
                            ++pal_nonzero_count_c;
                            if (pal_nonzero_count_c <= 200)
                                fprintf(stderr, "  PAL WR NONZERO #%d addr=%06X data=%04X @bc=%d frame=%d\n",
                                        pal_nonzero_count_c, addr_c, (unsigned)pal_data,
                                        bus_cycles_c, frame_num);
                        }
                        // Log palette writes to the sprite color=5 range (indices 80-95 = addr 0xB000A0-0xB000BE)
                        {
                            static int pal_col5_count = 0;
                            if (addr_c >= 0xB000A0 && addr_c <= 0xB000BE && pal_col5_count < 20) {
                                ++pal_col5_count;
                                fprintf(stderr, "  PAL COL5 WR: addr=%06X data=%04X @bc=%d frame=%d\n",
                                        addr_c, (unsigned)pal_data, bus_cycles_c, frame_num);
                            }
                        }
                    }
                    // WRAM at 0xF00000-0xF03FFF (Gigandes)
                    if (addr_c >= 0xF00000 && addr_c <= 0xF03FFF) {
                        ++wram_wr_count_c;
                        if (wram_wr_count_c <= 20 || (wram_wr_count_c % 5000) == 0)
                            fprintf(stderr, "  WRAM WR #%d addr=%06X din=%04X @bc=%d iter=%lu\n",
                                    wram_wr_count_c, addr_c, (unsigned)top->dbg_cpu_din,
                                    bus_cycles_c, (unsigned long)iter);
                        // Track writes to palette DMA source area (0xF004EC - 0xF008AC)
                        static int pal_src_wr = 0;
                        if (addr_c >= 0xF004EC && addr_c <= 0xF008AC && pal_src_wr < 5) {
                            ++pal_src_wr;
                            fprintf(stderr, "  PAL SRC WR: addr=%06X din=%04X @bc=%d frame=%d\n",
                                    addr_c, (unsigned)top->dbg_cpu_din,
                                    bus_cycles_c, frame_num);
                        }
                    }
                    // Sprite Y RAM at 0xD00000-0xD005FF
                    static int yram_wr = 0;
                    if (addr_c >= 0xD00000 && addr_c <= 0xD005FF) {
                        ++yram_wr;
                        uint16_t yram_data = (unsigned)top->dbg_cpu_din;
                        // Always log non-0xFA writes; log first 500 of any write
                        if (yram_data != 0x00FA || yram_wr <= 5) {
                            fprintf(stderr, "  YRAM WR #%d addr=%06X din=%04X @bc=%d frame=%d\n",
                                yram_wr, addr_c, (unsigned)yram_data,
                                bus_cycles_c, frame_num);
                        }
                    }
                    // Sprite code RAM at 0xE00000-0xE03FFF — track all writes
                    static int cram_nz_wr = 0;
                    static int cram_total_wr = 0;
                    if (addr_c >= 0xE00000 && addr_c <= 0xE03FFF) {
                        uint16_t cram_val = (uint16_t)top->dbg_cpu_din;
                        ++cram_total_wr;
                        // Log first 10 writes (any value) + periodic
                        if (cram_total_wr <= 10 || (cram_total_wr % 1000) == 0)
                            fprintf(stderr, "  CRAM WR #%d addr=%06X din=%04X @bc=%d frame=%d\n",
                                    cram_total_wr, addr_c, cram_val,
                                    bus_cycles_c, frame_num);
                        if (cram_val != 0 && cram_nz_wr < 50) {
                            ++cram_nz_wr;
                            fprintf(stderr, "  CRAM NZ WR #%d addr=%06X din=%04X @bc=%d frame=%d\n",
                                    cram_nz_wr, addr_c, cram_val,
                                    bus_cycles_c, frame_num);
                        }
                    }
                    // Sprite ctrl at 0xD00600-0xD00607 — log D00602 (frame_bank ctrl) always
                    static int ctrl_wr = 0;
                    if (addr_c >= 0xD00600 && addr_c <= 0xD00607) {
                        ++ctrl_wr;
                        // Always log D00602 (frame bank register); log first 20 of others
                        if (addr_c == 0xD00602 || ctrl_wr <= 20) {
                            fprintf(stderr, "  CTRL WR #%d addr=%06X din=%04X @bc=%d frame=%d\n",
                                    ctrl_wr, addr_c, (unsigned)top->dbg_cpu_din,
                                    bus_cycles_c, frame_num);
                        }
                    }
                }

                // Periodic write summary + PC sample
                if (bus_cycles_c > 0 && (bus_cycles_c % 50000) == 0 && prev_asn_c && asn_c) {
                    fprintf(stderr, "  [%dK bus] pal_wr=%d(nz=%d) wram_wr=%d frame=%d\n",
                            bus_cycles_c/1000, pal_wr_count_c, pal_nonzero_count_c,
                            wram_wr_count_c, frame_num);
                }
                // Periodic PC sampling: log current fetch addr every 10K bus cycles (bc=200..200K)
                if (!asn_c && prev_asn_c && rwn_c &&
                    bus_cycles_c >= 200 && (bus_cycles_c % 10000) == 0) {
                    fprintf(stderr, "  [PC-sample bc=%d] fetch addr=%06X frame=%d\n",
                            bus_cycles_c, addr_c, frame_num);
                }

                // Dense PC sampling around stall region (bc=550000-575000, every 500 cycles)
                static int stall_sample_count = 0;
                if (!asn_c && prev_asn_c && rwn_c &&
                    bus_cycles_c >= 550000 && bus_cycles_c <= 575000 &&
                    (bus_cycles_c % 500) == 0 && stall_sample_count < 100) {
                    ++stall_sample_count;
                    fprintf(stderr, "  [STALL-REGION bc=%d] fetch addr=%06X dtack_n=%d halted_n=%d frame=%d\n",
                            bus_cycles_c, addr_c, (int)top->dbg_cpu_dtack_n,
                            (int)top->dbg_cpu_halted_n, frame_num);
                }

                // Log ALL bus cycles after bc=566800 (near stall point), including FC codes.
                // FC2:FC0 encoding:
                //   000 = (unused)
                //   001 = user data space
                //   010 = user program space
                //   011 = (unused)
                //   100 = (unused)
                //   101 = supervisor data space  (exception stacking reads/writes WRAM)
                //   110 = supervisor program space (exception vector fetch from ROM)
                //   111 = interrupt acknowledge  (IACK cycle: cpu reads interrupt vector)
                static bool near_stall = false;
                static int near_stall_count = 0;
                if (bus_cycles_c >= 566500 && !near_stall) near_stall = true;
                if (near_stall && !asn_c && prev_asn_c && near_stall_count < 800) {
                    ++near_stall_count;
                    uint8_t fc = top->dbg_cpu_fc & 0x7;
                    const char* fc_str = (fc == 7) ? "IACK" :
                                         (fc == 6) ? "SP-PROG" :
                                         (fc == 5) ? "SP-DATA" :
                                         (fc == 2) ? "UP-PROG" :
                                         (fc == 1) ? "UP-DATA" : "???";
                    fprintf(stderr, "  [NEAR-STALL #%d bc=%d] FC=%d(%s) RW=%d addr=%06X dtack_n=%d din=%04X dout=%04X halted=%d\n",
                            near_stall_count, bus_cycles_c, fc, fc_str, rwn_c, addr_c,
                            (int)top->dbg_cpu_dtack_n, (unsigned)top->dbg_cpu_din,
                            (unsigned)top->dbg_cpu_dout, (int)!top->dbg_cpu_halted_n);
                    // Alert on exception-related FC codes
                    if (fc == 7) {
                        fprintf(stderr, "  *** IACK CYCLE: CPU acknowledging interrupt at bc=%d addr=%06X\n",
                                bus_cycles_c, addr_c);
                    }
                    if (fc == 6 && addr_c < 0x400) {
                        fprintf(stderr, "  *** EXCEPTION VECTOR FETCH: PC=0x%05X (vec offset=%d) at bc=%d\n",
                                addr_c, addr_c / 4, bus_cycles_c);
                    }
                }
                // Also log when CPU enters the crash handler zone (0x000F90-0x001010)
                static bool crash_reported = false;
                if (!asn_c && prev_asn_c && rwn_c &&
                    addr_c >= 0x000F90 && addr_c <= 0x001010 && !crash_reported) {
                    crash_reported = true;
                    uint8_t fc = top->dbg_cpu_fc & 0x7;
                    fprintf(stderr, "  *** CRASH HANDLER ENTRY: fetch at %06X FC=%d bc=%d frame=%d\n",
                            addr_c, fc, bus_cycles_c, frame_num);
                }
                // Detect DTACK timeout: ASn asserted but no DTACK after 1000 iters
                static uint64_t asn_low_since = 0;
                static bool dtack_timeout_reported = false;
                if (!asn_c && prev_asn_c) asn_low_since = iter;
                if (!asn_c && !dtack_timeout_reported &&
                    (iter - asn_low_since) > 2000 && top->dbg_cpu_dtack_n == 1) {
                    dtack_timeout_reported = true;
                    fprintf(stderr, "  *** DTACK TIMEOUT: ASn asserted %lu iters ago, no DTACK! addr=%06X RW=%d bc=%d\n",
                            (unsigned long)(iter - asn_low_since), addr_c, rwn_c, bus_cycles_c);
                }

                // Detect CPU halt
                if (top->dbg_cpu_halted_n == 0 && iter > RESET_ITERS + 100 && !halted_reported_c) {
                    halted_reported_c = true;
                    fprintf(stderr, "\n*** CPU HALTED at iter %lu (bus_cycles=%d) ***\n",
                            (unsigned long)iter, bus_cycles_c);
                }

                // Stall detection: no ASn activity for 500K iters
                static uint64_t last_bus_iter = 0;
                static bool stall_reported = false;
                if (!asn_c) last_bus_iter = iter;
                if (iter > RESET_ITERS + 500000 && bus_cycles_c > 0 &&
                    (iter - last_bus_iter) > 500000 && !stall_reported) {
                    stall_reported = true;
                    fprintf(stderr, "\n*** CPU STALL at iter %lu bc=%d last_bus=%lu ***\n",
                            (unsigned long)iter, bus_cycles_c, (unsigned long)last_bus_iter);
                    fprintf(stderr, "    ASn=%d RW=%d addr=%06X dtack_n=%d halted_n=%d\n",
                            asn_c, rwn_c, addr_c, (int)top->dbg_cpu_dtack_n,
                            (int)top->dbg_cpu_halted_n);
                }

                // After bc18, trace DTACK state for 100 iters (debug watchdog write)
                static bool dtack_trace = false;
                static int dtack_trace_count = 0;
                if (bus_cycles_c >= 19 && !dtack_trace) dtack_trace = true;
                if (dtack_trace && dtack_trace_count < 40 && !asn_c) {
                    fprintf(stderr, "  DTACK-trace @%lu: ASn=%d dtack_n=%d addr=%06X RW=%d halted=%d\n",
                            (unsigned long)iter, asn_c, (int)top->dbg_cpu_dtack_n,
                            addr_c, rwn_c, (int)top->dbg_cpu_halted_n);
                    dtack_trace_count++;
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
                // Track non-black pixels
                static int rgb_nonzero_count = 0;
                if ((top->rgb_r | top->rgb_g | top->rgb_b) != 0 && rgb_nonzero_count < 5) {
                    ++rgb_nonzero_count;
                    fprintf(stderr, "  *** RGB NONZERO #%d r=%d g=%d b=%d @fb=(%d,%d) frame=%d\n",
                            rgb_nonzero_count, (int)top->rgb_r, (int)top->rgb_g,
                            (int)top->rgb_b, fb_x, fb_y, frame_num);
                }
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
