// =============================================================================
// tb_system.cpp — Kaneko16 Arcade (Berlin Wall) Verilator testbench
//
// Drives chips/kaneko_arcade/rtl/tb_top.sv which wraps kaneko_arcade + fx68k
// executing the real Berlin Wall ROM.
//
// Key difference from Taito B: kaneko_arcade generates its own video timing,
// so there are NO hpos/vpos/hblank_n_in/vblank_n_in inputs. Instead, we
// capture pixels using the hblank/vblank/hsync_n/vsync_n OUTPUTS.
//
// Clock model:
//   32 MHz sys clock
//   enPhi1/enPhi2: alternating every sys edge (16 MHz CPU)
//   clk_pix: 1-cycle pulse every 5 sys clocks (6.4 MHz pixel clock)
//   clk_sound_cen: 1-cycle pulse every 32 sys clocks (1 MHz sound clock)
//
// SDRAM layout (byte addresses):
//   0x000000 — CPU program ROM (256KB, interleaved 16-bit big-endian)
//   0x200000 — GFX ROM (sprites + BG tiles, combined)
//   0x600000 — Z80 sound ROM (32KB)
//   0x700000 — ADPCM ROM (OKI M6295 samples)
//
// Note: gfx_rom_addr from kaneko_arcade includes GFX_ROM_BASE (0x100000)
//       which is a WORD address. Byte addr = gfx_rom_addr << 1.
//       So GFX data loaded at byte 0x200000 = GFX_ROM_BASE * 2.
//
// Environment variables:
//   N_FRAMES   — frames to simulate (default 30)
//   ROM_PROG   — path to CPU program ROM binary (256KB, interleaved)
//   ROM_GFX    — path to combined GFX ROM (sprites + BG concatenated)
//   ROM_Z80    — path to Z80 sound ROM binary (32KB)
//   ROM_ADPCM  — path to ADPCM sample ROM binary
//   DUMP_VCD   — set to "1" for VCD trace (slow)
//
// Output: frame_NNNN.ppm — one PPM per vertical frame (320x240)
// =============================================================================

#include "Vtb_top.h"
#include "Vtb_top___024root.h"
#include "Vtb_top_tb_top.h"
#include "Vtb_top_fx68k.h"
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

// ── Video constants (Kaneko16 standard 320x240) ─────────────────────────────
static constexpr int VID_H_ACTIVE = 320;
static constexpr int VID_V_ACTIVE = 240;

// Pixel clock: one pixel every 5 system clocks (32 MHz / 5 = 6.4 MHz)
static constexpr int PIX_DIV = 5;
// Sound clock: one pulse every 32 system clocks (32 MHz / 32 = 1 MHz)
static constexpr int SND_DIV = 32;

// =============================================================================
// ToggleSdramChannel32 — 32-bit GFX ROM channel
// Same toggle-handshake protocol, returns 32-bit data (two consecutive words).
// =============================================================================
class ToggleSdramChannel32 {
public:
    static constexpr int LATENCY = 2;

    explicit ToggleSdramChannel32(const SdramModel& sdram)
        : sdram_(sdram), ack_(0), last_req_(0), countdown_(0),
          pending_addr_(0), data_(0) {}

    struct Result { uint32_t data; uint8_t ack; };

    Result tick(uint8_t req, uint32_t byte_addr) {
        if (req != last_req_) {
            last_req_     = req;
            pending_addr_ = byte_addr;
            countdown_    = LATENCY;
        }
        if (countdown_ > 0) {
            --countdown_;
            if (countdown_ == 0) {
                uint16_t lo = sdram_.read_word(pending_addr_ & ~1u);
                uint16_t hi = sdram_.read_word((pending_addr_ & ~1u) + 2);
                data_ = ((uint32_t)hi << 16) | lo;
                ack_  = last_req_;
            }
        }
        return {data_, ack_};
    }

private:
    const SdramModel& sdram_;
    uint8_t  ack_;
    uint8_t  last_req_;
    int      countdown_;
    uint32_t pending_addr_;
    uint32_t data_;
};

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
    const char* env_gfx    = getenv("ROM_GFX");
    const char* env_z80    = getenv("ROM_Z80");
    const char* env_adpcm  = getenv("ROM_ADPCM");
    const char* env_vcd    = getenv("DUMP_VCD");

    int n_frames = env_frames ? atoi(env_frames) : 30;
    if (n_frames < 1) n_frames = 1;

    fprintf(stderr, "Kaneko16 (berlwall) simulation: %d frames\n", n_frames);

    // ── Load ROM data ────────────────────────────────────────────────────────
    SdramModel sdram;
    if (env_prog)  sdram.load(env_prog,  0x000000);   // CPU program ROM (256KB)
    else fprintf(stderr, "WARNING: ROM_PROG not set — CPU will read zeros\n");

    if (env_gfx)   sdram.load(env_gfx,   0x200000);   // GFX ROM (sprites + BG)
    else fprintf(stderr, "WARNING: ROM_GFX not set — no graphics\n");

    if (env_z80)   sdram.load(env_z80,   0x600000);   // Z80 sound ROM
    // Z80 is optional — many sims work without sound

    if (env_adpcm) sdram.load(env_adpcm, 0x700000);   // ADPCM samples
    // ADPCM is optional

    // ── SDRAM channels ───────────────────────────────────────────────────────
    ToggleSdramChannel   prog_ch(sdram);     // CPU program ROM (16-bit)
    ToggleSdramChannel32 gfx_ch(sdram);      // GFX ROM (32-bit)
    ToggleSdramChannelByte z80_ch(sdram);    // Z80 sound ROM (byte)
    ToggleSdramChannelByte adpcm_ch(sdram);  // ADPCM ROM (byte)

    // ── DUT init ─────────────────────────────────────────────────────────────
    Vtb_top* top = new Vtb_top();

    // ── Optional VCD trace ───────────────────────────────────────────────────
    VerilatedVcdC* vcd = nullptr;
    if (env_vcd && env_vcd[0] == '1') {
        Verilated::traceEverOn(true);
        vcd = new VerilatedVcdC();
        top->trace(vcd, 99);
        vcd->open("sim_kaneko16.vcd");
        fprintf(stderr, "VCD trace enabled: sim_kaneko16.vcd\n");
    }

    // ── Initial port state ───────────────────────────────────────────────────
    top->clk_sys   = 0;
    top->reset_n   = 0;

    // Bus bypass: disabled — CPU reads through kaneko_arcade SDRAM bridge
    top->bypass_en      = 0;
    top->bypass_data    = 0xFFFF;
    top->bypass_dtack_n = 1;

    // Clock enables: driven from C++
    top->enPhi1        = 0;
    top->enPhi2        = 0;
    top->clk_pix       = 0;
    top->clk_sound_cen = 0;

    // SDRAM channel inputs
    top->prog_rom_data = 0;
    top->prog_rom_ack  = 0;
    top->gfx_rom_data  = 0;
    top->gfx_rom_ack   = 0;
    top->z80_rom_data  = 0;
    top->z80_rom_ack   = 0;
    top->adpcm_rom_data = 0;
    top->adpcm_rom_ack  = 0;

    // Player inputs — all active-low: release all buttons/coins
    top->joystick_p1 = 0xFF;     // all buttons released
    top->joystick_p2 = 0xFF;
    top->coin        = 0x3;      // both coins inactive (active low)
    top->service     = 1;        // service not pressed (active low)
    top->dipsw1      = 0xFF;     // all DIPs default
    top->dipsw2      = 0xFF;

    // ── Simulation state ─────────────────────────────────────────────────────
    int      frame_num  = 0;
    bool     done       = false;

    // Clock dividers
    int  pix_div_cnt  = 0;
    int  snd_div_cnt  = 0;

    // Pixel position tracking (from hblank/vblank edges)
    int  px = 0, py = 0;
    uint8_t prev_hblank = 0;
    uint8_t prev_vblank = 0;

    // Frame buffer and vsync edge detection
    FrameBuffer fb;
    uint8_t vsync_n_prev = 1;

    // Bus diagnostics
    bool     phi_toggle      = false;
    bool     prev_asn        = true;
    int      bus_cycles      = 0;
    uint64_t iter            = 0;
    bool     halted_reported = false;
    static constexpr int RESET_ITERS = 20;

    uint64_t vcd_ts = 0;

    top->reset_n = 0;

    fprintf(stderr, "Running Kaneko16 berlwall simulation (kaneko_arcade RTL)...\n");

    // =====================================================================
    // Main simulation loop
    // =====================================================================
    // Iteration budget: H_TOTAL=416, V_TOTAL=264, PIX_DIV=5, 2 half-cycles/iter
    // → ~416*264*5*2 = 1,098,240 iters/frame. Use 1.2M for margin.
    for (iter = 0; iter < (uint64_t)n_frames * 1200000ULL; iter++) {
        // Toggle clock
        top->clk_sys = top->clk_sys ^ 1;

        // Release reset after RESET_ITERS half-cycles
        if (iter >= RESET_ITERS) top->reset_n = 1;

        if (top->clk_sys == 1) {
            // ── Rising edge ──────────────────────────────────────────────

            // Phi enables (alternating, 16 MHz CPU from 32 MHz sys)
            top->enPhi1 = phi_toggle ? 0 : 1;
            top->enPhi2 = phi_toggle ? 1 : 0;
            phi_toggle  = !phi_toggle;

            // ── Pixel clock enable (/5 from 32 MHz = 6.4 MHz) ──────────
            ++pix_div_cnt;
            if (pix_div_cnt >= PIX_DIV) {
                pix_div_cnt = 0;
                top->clk_pix = 1;
            } else {
                top->clk_pix = 0;
            }

            // ── Sound clock enable (/32 from 32 MHz = 1 MHz) ───────────
            ++snd_div_cnt;
            if (snd_div_cnt >= SND_DIV) {
                snd_div_cnt = 0;
                top->clk_sound_cen = 1;
            } else {
                top->clk_sound_cen = 0;
            }

            // ── SDRAM channels (tick every rising edge) ─────────────────
            {
                // Program ROM: [19:1] word-addressed, byte_addr = addr << 1
                auto r = prog_ch.tick(top->prog_rom_req,
                                      (uint32_t)top->prog_rom_addr << 1);
                top->prog_rom_data = r.data;
                top->prog_rom_ack  = r.ack;
            }
            {
                // GFX ROM: [21:0] word-addressed, byte_addr = addr << 1
                auto r = gfx_ch.tick(top->gfx_rom_req,
                                     (uint32_t)top->gfx_rom_addr << 1);
                top->gfx_rom_data = r.data;
                top->gfx_rom_ack  = r.ack;
            }
            {
                // Z80 ROM: [15:0] byte-addressed, add SDRAM base 0x600000
                auto r = z80_ch.tick(top->z80_rom_req,
                                     0x600000u + (uint32_t)top->z80_rom_addr);
                top->z80_rom_data = r.data;
                top->z80_rom_ack  = r.ack;
            }
            {
                // ADPCM ROM: [23:0] byte-addressed, add SDRAM base 0x700000
                auto r = adpcm_ch.tick(top->adpcm_rom_req,
                                       0x700000u + (uint32_t)top->adpcm_rom_addr);
                top->adpcm_rom_data = r.data;
                top->adpcm_rom_ack  = r.ack;
            }

            // ── Bus diagnostics ─────────────────────────────────────────
            {
                uint8_t  asn  = top->dbg_cpu_as_n;
                uint8_t  rwn  = top->dbg_cpu_rw;
                uint32_t addr = ((uint32_t)top->dbg_cpu_addr << 1) & 0xFFFFFF;

                if (!prev_asn && asn) {
                    bus_cycles++;
                }

                // Trap backtrace ring buffer
                {
                    static constexpr int RING_SIZE = 50;
                    struct BCE { uint32_t addr; bool rw; int bc; };
                    static BCE ring[RING_SIZE];
                    static int ring_idx = 0;
                    static bool trap_dumped = false;

                    if (!asn && prev_asn && iter > RESET_ITERS) {
                        ring[ring_idx % RING_SIZE] = {addr, (bool)rwn, bus_cycles};
                        ring_idx++;
                    }
                    if (!trap_dumped && !asn && prev_asn && addr >= 0x000B00 && addr <= 0x000B04) {
                        trap_dumped = true;
                        int n = (ring_idx < RING_SIZE) ? ring_idx : RING_SIZE;
                        fprintf(stderr, "\n*** TRAP at 0x%06X (bc=%d)! Last %d bus cycles:\n",
                                addr, bus_cycles, n);
                        int start = (ring_idx >= RING_SIZE) ? ring_idx - RING_SIZE : 0;
                        for (int i = start; i < ring_idx; i++) {
                            auto& e = ring[i % RING_SIZE];
                            fprintf(stderr, "    bc=%6d  %s  0x%06X\n",
                                    e.bc, e.rw ? "RD" : "WR", e.addr);
                        }
                        fprintf(stderr, "***\n\n");
                    }
                }

                // Log first 60 bus cycles
                bool log_this = (!asn && prev_asn && iter > RESET_ITERS) &&
                    (bus_cycles < 60);
                if (log_this) {
                    fprintf(stderr, "  [%6" PRIu64 "|bc%d] ASn=0 RW=%d addr=%06X dtack_n=%d dout=%04X\n",
                            iter, bus_cycles, (int)rwn, addr,
                            (int)top->dbg_cpu_dtack_n,
                            (unsigned)(top->dbg_cpu_dout & 0xFFFF));
                }

                // Track writes to key address ranges
                static int pal_wr_count = 0;
                static int wram_wr_count = 0;
                static int io_rd_count = 0;
                if (!asn && prev_asn) {
                    if (!rwn) {
                        // Palette RAM: 0x600000-0x6003FF
                        if (addr >= 0x600000 && addr <= 0x6003FF) {
                            ++pal_wr_count;
                            if (pal_wr_count <= 5)
                                fprintf(stderr, "  PAL WR #%d addr=%06X data=%04X @iter=%" PRIu64 "\n",
                                        pal_wr_count, addr, (unsigned)top->dbg_cpu_din,
                                        iter);
                        }
                        // Work RAM: 0x100000-0x10FFFF
                        if (addr >= 0x100000 && addr <= 0x10FFFF) {
                            ++wram_wr_count;
                            uint16_t wd2 = (unsigned)(top->dbg_cpu_din & 0xFFFF);
                            if (wram_wr_count <= 5 || (wd2 != 0 && wram_wr_count <= 20))
                                fprintf(stderr, "  WRAM WR #%d addr=%06X data=%04X @bc=%d\n",
                                        wram_wr_count, addr, wd2, bus_cycles);
                        }
                    } else {
                        // I/O reads: 0x700000-0x70000F
                        if (addr >= 0x700000 && addr <= 0x70000F) {
                            ++io_rd_count;
                            if (io_rd_count <= 10)
                                fprintf(stderr, "  I/O RD #%d addr=%06X data=%04X @iter=%" PRIu64 "\n",
                                        io_rd_count, addr,
                                        (unsigned)(top->dbg_cpu_dout & 0xFFFF),
                                        iter);
                        }
                        // AY8910 reads: 0x800000-0x800FFF
                        static int ay_rd_count = 0;
                        if (addr >= 0x800000 && addr <= 0x800FFF) {
                            ++ay_rd_count;
                            if (ay_rd_count <= 20)
                                fprintf(stderr, "  AY RD #%d addr=%06X data=%04X @iter=%" PRIu64 "\n",
                                        ay_rd_count, addr,
                                        (unsigned)(top->dbg_cpu_dout & 0xFFFF),
                                        iter);
                        }
                        // Brightness reads: 0x500000
                        static int brt_rd_count = 0;
                        if (addr >= 0x500000 && addr <= 0x500003) {
                            ++brt_rd_count;
                            if (brt_rd_count <= 5)
                                fprintf(stderr, "  BRT RD #%d addr=%06X data=%04X @iter=%" PRIu64 "\n",
                                        brt_rd_count, addr,
                                        (unsigned)(top->dbg_cpu_dout & 0xFFFF),
                                        iter);
                        }
                    }
                }

                // MCU RAM accesses (both reads and writes): 0x200000-0x20FFFF
                static int mcuram_wr_count = 0;
                static int mcuram_rd_count = 0;
                if (!asn && prev_asn && addr >= 0x200000 && addr <= 0x20FFFF) {
                    if (!rwn) {
                        ++mcuram_wr_count;
                        // Log MCU writes with non-zero data (fill test) or near the stall
                        uint16_t wd = (unsigned)(top->dbg_cpu_din & 0xFFFF);
                        if ((wd != 0 && mcuram_wr_count <= 30) || (bus_cycles >= 100000 && mcuram_wr_count <= 200))
                            fprintf(stderr, "  MCU WR #%d addr=%06X data=%04X @bc=%d\n",
                                    mcuram_wr_count, addr, wd, bus_cycles);
                    } else {
                        ++mcuram_rd_count;
                        uint16_t rd = (unsigned)(top->dbg_cpu_dout & 0xFFFF);
                        if ((rd != 0 && mcuram_rd_count <= 30) || (bus_cycles >= 100000 && mcuram_rd_count <= 200))
                            fprintf(stderr, "  MCU RD #%d addr=%06X data=%04X @bc=%d\n",
                                    mcuram_rd_count, addr, rd, bus_cycles);
                    }
                }

                // Trap detection: ring buffer filled in the bus cycle edge detection below

                // Count VBlank handler calls and IRQ state
                {
                    static int vbl_fetch_count = 0;
                    static int update_fetch_count = 0;
                    static int ipl_active_samples = 0;
                    if (!asn && prev_asn && rwn) {
                        if (addr >= 0x000E5A && addr <= 0x000E8A) vbl_fetch_count++;
                        if (addr >= 0x005990 && addr <= 0x005A00) update_fetch_count++;
                    }
                    // Sample IPL state periodically
                    if ((iter % 100000) == 0 && top->clk_sys) {
                        if ((top->dbg_cpu_addr & 0) == 0) {} // just to reference
                        // Check the ipl output — it's cpu_ipl_n from kaneko_arcade
                        // We can't easily read it, but we can check if vblank_rising fires
                    }
                    // Track IPL and IACK state
                    static int ipl_active_count = 0;
                    static int iack_count = 0;
                    if (top->clk_sys && (top->dbg_cpu_ipl_n & 7) != 7) {
                        ipl_active_count++;
                        if (ipl_active_count <= 3)
                            fprintf(stderr, "  IPL ACTIVE: ipl_n=%d @iter=%" PRIu64 " frame=%d\n",
                                    (int)(top->dbg_cpu_ipl_n & 7), iter, frame_num);
                    }
                    if (top->clk_sys && top->dbg_iack) {
                        iack_count++;
                        if (iack_count <= 3)
                            fprintf(stderr, "  IACK CYCLE @iter=%" PRIu64 " frame=%d\n", iter, frame_num);
                    }
                    // Probe fx68k internal state via Verilator public signals
                    // Access path from Agent 1's NMK pattern
                    static int intpend_count = 0;

                    // Report at frame 5
                    if (frame_num == 5) {
                        static bool reported2 = false;
                        if (!reported2) {
                            reported2 = true;
                            fprintf(stderr, "\n*** IRQ CHECK at frame 5: VBL=%d update=%d IPL=%d IACK=%d intPend=%d ***\n\n",
                                    vbl_fetch_count, update_fetch_count, ipl_active_count, iack_count, intpend_count);
                        }
                    }
                }

                // Log any fetch NOT in the fill range (0x0D20-0x0D30) after bc 120K
                {
                    static int nonfill_count = 0;
                    if (!asn && prev_asn && bus_cycles > 120000 && rwn) {
                        if (addr < 0x000D20 || addr > 0x000D30) {
                            ++nonfill_count;
                            if (nonfill_count <= 20)
                                fprintf(stderr, "  NON-FILL fetch #%d addr=%06X @bc=%d\n",
                                        nonfill_count, addr, bus_cycles);
                        }
                    }
                }

                // Sample CPU address + pswI every 50K bus cycles
                if (bus_cycles > 0 && (bus_cycles % 50000) == 0 && !prev_asn && asn) {
                    // Access fx68k internals via rootp (same pattern as NMK sim)
                    auto* cpu_r = top->rootp->tb_top->u_cpu;
                    fprintf(stderr, "  [%dK bus] addr=%06X frame=%d pswI=%d intPend=%d iIpl=%d\n",
                            bus_cycles/1000, addr, frame_num,
                            (int)cpu_r->pswI, (int)cpu_r->intPend, (int)cpu_r->iIpl);
                }

                // Detect CPU halt (double bus fault)
                if (top->dbg_cpu_halted_n == 0 && iter > (uint64_t)RESET_ITERS + 100 &&
                    !halted_reported) {
                    halted_reported = true;
                    fprintf(stderr, "\n*** CPU HALTED at iter %" PRIu64 " (bus_cycles=%d) ***\n",
                            iter, bus_cycles);
                }

                // Stall detection: if bus_cycles hasn't changed for 500K iters, log CPU state
                {
                    static int      prev_bus_cycles = 0;
                    static uint64_t last_advance_iter = 0;
                    static bool     stall_reported = false;

                    if (bus_cycles != prev_bus_cycles) {
                        prev_bus_cycles = bus_cycles;
                        last_advance_iter = iter;
                        stall_reported = false;
                    } else if (iter - last_advance_iter > 500000 && !stall_reported) {
                        stall_reported = true;
                        fprintf(stderr, "\n*** CPU STALL detected at iter %" PRIu64
                                        " (bus_cycles=%d, stale for %luK iters)\n"
                                        "    addr=0x%06X rw=%d asn=%d dtack_n=%d halted_n=%d\n\n",
                                iter, bus_cycles,
                                (unsigned long)((iter - last_advance_iter) / 1000),
                                addr, (int)rwn, (int)asn,
                                (int)top->dbg_cpu_dtack_n,
                                (int)top->dbg_cpu_halted_n);
                    }
                }

                prev_asn = asn;
            }

        } else {
            // ── Falling edge ─────────────────────────────────────────────
            top->enPhi1        = 0;
            top->enPhi2        = 0;
            top->clk_pix       = 0;
            top->clk_sound_cen = 0;
        }

        top->eval();
        if (vcd) vcd->dump((uint64_t)vcd_ts);
        ++vcd_ts;

        // ── Pixel capture (on rising edge, after eval) ──────────────────
        // kaneko_arcade generates its own hblank/vblank — no external timing.
        // Track pixel position by counting active pixels between blanking edges.

        // DEBUG: Check if video signals are ever active
        {
            static uint64_t rgb_nonzero_count = 0;
            static uint64_t active_count = 0;
            static uint64_t hblank_low_count = 0;
            static uint64_t vblank_low_count = 0;
            static bool dbg_reported = false;

            if (top->clk_sys == 1) {
                if (top->rgb_r || top->rgb_g || top->rgb_b) rgb_nonzero_count++;
                if (!top->hblank) hblank_low_count++;
                if (!top->vblank) vblank_low_count++;
                if (!top->hblank && !top->vblank) active_count++;
            }

            if (!dbg_reported && frame_num >= 3) {
                dbg_reported = true;
                fprintf(stderr, "\n*** VIDEO DEBUG after %d frames:\n"
                        "    rgb_nonzero=%llu  active_video=%llu\n"
                        "    hblank_low=%llu  vblank_low=%llu\n"
                        "    hblank=%d vblank=%d rgb=(%d,%d,%d)\n***\n\n",
                        frame_num,
                        (unsigned long long)rgb_nonzero_count,
                        (unsigned long long)active_count,
                        (unsigned long long)hblank_low_count,
                        (unsigned long long)vblank_low_count,
                        (int)top->hblank, (int)top->vblank,
                        (int)top->rgb_r, (int)top->rgb_g, (int)top->rgb_b);
            }
        }

        if (top->clk_sys == 1 && top->clk_pix) {
            uint8_t cur_hblank = top->hblank;
            uint8_t cur_vblank = top->vblank;

            // Active pixel: not in any blanking
            if (!cur_vblank && !cur_hblank) {
                fb.set(px, py, top->rgb_r, top->rgb_g, top->rgb_b);
                px++;
            }

            // Hblank rising edge -> end of active line
            if (cur_hblank && !prev_hblank) {
                px = 0;
                if (!cur_vblank) py++;
            }

            // Vblank rising edge -> end of active frame area
            if (cur_vblank && !prev_vblank) {
                px = 0;
                py = 0;
            }

            prev_hblank = cur_hblank;
            prev_vblank = cur_vblank;
        }

        // ── Vsync edge detection -> frame save ──────────────────────────
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
            fprintf(stderr, "  iter %" PRIu64 "  bus_cycles=%d  frame=%d\n",
                    iter, bus_cycles, frame_num);
        }
    }

    // ── Final cleanup ────────────────────────────────────────────────────────
    if (vcd) {
        vcd->close();
        delete vcd;
    }
    top->final();
    delete top;

    fprintf(stderr, "Simulation complete. %d frames, %" PRIu64 " iters (%d bus cycles).\n",
            frame_num, iter, bus_cycles);
    return 0;
}
