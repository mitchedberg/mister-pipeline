// =============================================================================
// tb_system.cpp — Toaplan V2 (Batsugun) Verilator testbench
//
// Wraps tb_top.sv (which includes toaplan_v2 + fx68k CPU) and drives:
//   - Clock (32 MHz system) and reset
//   - Video timing (generated internally by toaplan_v2; 320×240 @ ~60 Hz)
//   - SDRAM channels:
//       prog_rom:  toggle-handshake 16-bit (CPU program ROM)
//       gfx_rom:   toggle-handshake 32-bit (GP9001 tile + sprite data)
//       adpcm_rom: toggle-handshake 16-bit (OKI M6295 ADPCM)
//       z80_rom:   toggle-handshake 8-bit  (Z80 sound CPU ROM)
//   - Player inputs (all held at 0xFF = no input, active-low)
//
// The CPU (fx68k) is inside tb_top.sv and executes the real Batsugun ROM.
//
// Environment variables:
//   N_FRAMES   — number of vertical frames to simulate (default 30)
//   ROM_PROG   — path to CPU program ROM binary  (SDRAM 0x000000)
//   ROM_GFX    — path to GFX ROM binary (32-bit wide, SDRAM 0x100000)
//   ROM_ADPCM  — path to ADPCM ROM binary        (SDRAM 0x500000)
//   ROM_Z80    — path to Z80 sound ROM binary     (SDRAM 0x600000)
//   DUMP_VCD   — set to "1" to enable VCD trace (slow)
//
// Output:
//   frame_NNNN.ppm — one PPM file per vertical frame (320×240)
//
// Video timing: 320×240 (internal to toaplan_v2)
//   From MAME truxton2.cpp: set_raw(27_MHz_XTAL/4, 432, 0, 320, 262, 0, 240)
//   Pixel clock: 27 MHz / 4 = 6.75 MHz (independent 27 MHz crystal on real PCB)
//   Horizontal: 320 active + 112 blanking = 432 total pixels/line
//   Vertical:   240 active + 22 blanking = 262 total lines/frame
//   Frame rate: 6.75 MHz / (432 × 262) = 59.637 Hz
//   Frame period: 432 × 262 × (128/27) / 32 MHz = 536,576 / 32 MHz = 16.768 ms
//   Pixel clock generated via fractional accumulator (27/128 per 32 MHz sys_clk)
// =============================================================================

#include "Vtb_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include "Vtb_top___024root.h"
#include "Vtb_top_tb_top.h"
#include "sdram_model.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <cinttypes>

// ── Video timing constants (Toaplan V2 / GP9001 standard 320×240) ───────────
// From MAME toaplan2.cpp / truxton2.cpp:
//   m_screen->set_raw(27_MHz_XTAL/4, 432, 0, 320, 262, 0, 240)
//   Pixel clock: 27 MHz / 4 = 6.75 MHz
//   HTOTAL = 432, VTOTAL = 262
//
// The M68000 runs at 16 MHz from a 32 MHz crystal (sys_clk / 2).
// The pixel clock comes from an INDEPENDENT 27 MHz crystal (divided by 4).
// These two clocks have no common integer ratio: 32/6.75 = 128/27.
//
// We use a FRACTIONAL ACCUMULATOR to generate clk_pix from 32 MHz sys_clk:
//   accumulator += PIX_ACC_INC  (= 27)
//   if accumulator >= PIX_ACC_MOD (= 128): fire pixel clock, subtract modulus
//
// This generates 6.75 MHz pixel clock (exact long-term frequency) from 32 MHz.
// Frame period = 432 * 262 * (128/27) / 32 MHz = 536,576 / 32 MHz = 16.768 ms
// exactly matching MAME's 59.637 Hz.
//
static constexpr int VID_H_ACTIVE  = 320;
static constexpr int VID_V_ACTIVE  = 240;
static constexpr int VID_H_TOTAL   = 432;   // MAME: 27MHz/4, htotal=432
static constexpr int VID_V_TOTAL   = 262;   // MAME: vtotal=262

// Fractional pixel clock accumulator: fires at 6.75 MHz from 32 MHz sys_clk
// 6.75 MHz / 32 MHz = 27/128
static constexpr int PIX_ACC_INC = 27;
static constexpr int PIX_ACC_MOD = 128;

// Sound clock: Z80/YM2151 CE @ ~3.375 MHz from 27 MHz → 27 MHz / 8 = 3.375 MHz
// From 32 MHz sys_clk: 32/3.375 ≈ 9.48 → use fractional: 8/81 per sys_clk
// Simpler approximation: fire every 9-10 sys clocks (3.2-3.56 MHz, close enough)
// 32 MHz / 3.375 MHz ≈ 9.48, use 9 for simplicity (3.56 MHz, +5% error)
static constexpr int SND_DIV = 9;

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

    int count_nonblack() const {
        int cnt = 0;
        for (auto p : pixels) if (p) ++cnt;
        return cnt;
    }
};

// =============================================================================
// Per-frame RAM dump (matches dump_truxton2_v2.lua format for byte-by-byte comparison)
//
// Format: 4B LE frame# + 64KB MainRAM + 1KB Palette = 66564 bytes/frame
//
// Verilator field names (from obj_dir/Vtb_top_tb_top.h):
//   VlUnpacked<SData,32768> __PVT__u_toaplan__DOT__work_ram   (64KB MainRAM)
//   VlUnpacked<SData,512>   __PVT__u_toaplan__DOT__palette_ram (1KB Palette)
// =============================================================================

static inline void write_word_be(FILE* f, uint16_t w) {
    uint8_t b[2] = { (uint8_t)(w >> 8), (uint8_t)(w & 0xFF) };
    fwrite(b, 1, 2, f);
}

static void dump_frame_ram(FILE* f, uint32_t frame_num, Vtb_top* top) {
    auto* r = top->tb_top;

    // 4-byte LE frame number
    uint8_t hdr[4] = {
        (uint8_t)(frame_num & 0xFF),
        (uint8_t)((frame_num >> 8) & 0xFF),
        (uint8_t)((frame_num >> 16) & 0xFF),
        (uint8_t)((frame_num >> 24) & 0xFF)
    };
    fwrite(hdr, 1, 4, f);

    // Main RAM: 32768 words = 64KB (0x100000-0x10FFFF)
    for (int i = 0; i < 32768; i++)
        write_word_be(f, (uint16_t)r->__PVT__u_toaplan__DOT__work_ram[i]);

    // Palette RAM: 512 words = 1KB (0x300000-0x3003FF)
    for (int i = 0; i < 512; i++)
        write_word_be(f, (uint16_t)r->__PVT__u_toaplan__DOT__palette_ram[i]);
}

// =============================================================================
// main
// =============================================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    // ── Configuration from environment ──────────────────────────────────────
    const char* env_frames   = getenv("N_FRAMES");
    const char* env_prog     = getenv("ROM_PROG");
    const char* env_gfx      = getenv("ROM_GFX");
    const char* env_adpcm    = getenv("ROM_ADPCM");
    const char* env_z80      = getenv("ROM_Z80");
    const char* env_vcd      = getenv("DUMP_VCD");
    const char* env_ram_dump = getenv("RAM_DUMP");

    int n_frames = env_frames ? atoi(env_frames) : 30;
    if (n_frames < 1) n_frames = 1;

    fprintf(stderr, "Toaplan V2 (Truxton II) simulation: %d frames\n", n_frames);

    // ── Optional RAM dump file ───────────────────────────────────────────────
    FILE* ram_dump_f = nullptr;
    if (env_ram_dump) {
        ram_dump_f = fopen(env_ram_dump, "wb");
        if (!ram_dump_f) {
            fprintf(stderr, "ERROR: cannot open RAM_DUMP file: %s\n", env_ram_dump);
        } else {
            fprintf(stderr, "RAM dump enabled: %s\n", env_ram_dump);
            fprintf(stderr, "  Format: 4B frame# + 64KB MainRAM + 1KB Palette = 66564 bytes/frame\n");
        }
    }

    // ── Load ROM data ────────────────────────────────────────────────────────
    SdramModel sdram;

    // CPU program ROM: SDRAM byte 0x000000
    if (env_prog)  sdram.load(env_prog,  0x000000);

    // GFX ROM: SDRAM byte 0x100000 (4 MB, 32-bit wide tiles/sprites)
    if (env_gfx)   sdram.load(env_gfx,   0x100000);

    // ADPCM ROM: SDRAM byte 0x500000
    if (env_adpcm) sdram.load(env_adpcm, 0x500000);

    // Z80 ROM: SDRAM byte 0x600000 (byte-wide)
    if (env_z80)   sdram.load(env_z80,   0x600000);

    // ── SDRAM channels ───────────────────────────────────────────────────────
    ToggleSdramChannel     prog_ch(sdram);
    ToggleSdramChannel32   gfx_ch(sdram);
    ToggleSdramChannel     adpcm_ch(sdram);
    ToggleSdramChannelByte z80_ch(sdram);

    // ── Verilator init ───────────────────────────────────────────────────────
    Verilated::fatalOnError(false);  // suppress fx68k unique-case $stop during reset

    // ── Instantiate DUT ──────────────────────────────────────────────────────
    Vtb_top* top = new Vtb_top();

    // ── Optional VCD trace ───────────────────────────────────────────────────
    VerilatedVcdC* vcd = nullptr;
    if (env_vcd && env_vcd[0] == '1') {
        Verilated::traceEverOn(true);
        vcd = new VerilatedVcdC();
        top->trace(vcd, 99);
        vcd->open("sim_toaplan_v2.vcd");
        fprintf(stderr, "VCD trace enabled: sim_toaplan_v2.vcd\n");
    }

    // ── Initial port state ───────────────────────────────────────────────────
    top->clk_sys    = 0;
    top->clk_pix    = 0;
    top->clk_sound  = 0;
    top->reset_n    = 0;

    // Bus bypass: disabled — CPU reads through toaplan_v2 RTL data mux + DTACK
    top->bypass_en      = 0;
    top->bypass_data    = 0xFFFF;
    top->bypass_dtack_n = 1;

    // Clock enables: driven from C++
    top->enPhi1 = 0;
    top->enPhi2 = 0;

    // SDRAM inputs
    top->prog_rom_data   = 0;
    top->prog_rom_ack    = 0;
    top->gfx_rom_data    = 0;
    top->gfx_rom_ack     = 0;
    top->adpcm_rom_data  = 0;
    top->adpcm_rom_ack   = 0;
    top->z80_rom_data    = 0;
    top->z80_rom_ack     = 0;

    // Player inputs — all active-low: release all buttons/coins
    top->joystick_p1 = 0xFF;
    top->joystick_p2 = 0xFF;
    top->coin        = 0x3;   // both coins inactive (active low)
    top->service     = 1;
    top->dipsw1      = 0xFF;
    top->dipsw2      = 0xFF;

    // ── Simulation state ─────────────────────────────────────────────────────
    uint64_t iter         = 0;
    int      frame_num    = 0;
    bool     done         = false;

    // Video pixel counters (mirror toaplan_v2's internal timing)
    int      hcnt         = 0;   // [0, H_TOTAL)
    int      vcnt         = 0;   // [0, V_TOTAL)
    int      pix_acc      = 0;   // fractional pixel clock accumulator (fires at PIX_ACC_MOD)
    int      snd_div_cnt  = 0;   // sound clock divider

    // Frame buffer and pixel capture
    FrameBuffer fb;

    // vsync edge detection
    uint8_t vsync_n_prev = 1;

    // Phi toggle
    bool phi_toggle = false;

    // Bus diagnostics
    int      bus_cycles_c      = 0;
    bool     prev_asn_c        = true;
    bool     halted_reported   = false;
    int      pal_wr_count      = 0;
    int      wram_wr_count     = 0;

    // No-bus-cycle timeout: detect if CPU stops executing
    uint64_t last_bc_change_iter = 0;
    int      last_bc_snapshot    = 0;
    int      no_bc_reports       = 0;

    // Stall detection: track repeated reads to the same address
    uint32_t last_read_addr    = 0xFFFFFFFF;
    int      last_read_repeat  = 0;
    int      stall_reported    = 0;

    // Track last ROM fetch for progress snapshots
    uint32_t last_rom_pc       = 0;
    uint32_t snapshot_rom_pc[20] = {};
    int      snapshot_count    = 0;

    // Milestone tracking: first time CPU fetches from key addresses
    bool milestone_273E0 = false;  // game loop entry
    bool milestone_274A2 = false;  // JSR $258 VBlank sync
    bool milestone_27E   = false;  // inside VBlank sync poll loop
    bool milestone_1002CE_wr = false;  // IRQ2 handler sets VBlank flag

    // Pre-init loop tracing: log first N entries into range 0x29A-0x2C5
    // to see BTST #2 result and BEQ/JMP outcome
    int preinit_trace_count = 0;  // how many bus cycles in 0x29A-0x2C5 logged
    static constexpr int PREINIT_TRACE_MAX = 300;

    // Count how many times BEQ (0x2BC) and JMP (0x2BE) are fetched
    int preinit_beq_count = 0;
    int preinit_jmp_count = 0;
    int preinit_btst_io_count = 0;  // reads from $700001 while near pre-init loop

    // Reset duration
    static constexpr int RESET_ITERS = 20;

    top->reset_n = 0;

    // VCD timestamp
    uint64_t vcd_ts = 0;

    // ========================================================================
    // MAIN EVAL LOOP
    //
    // One eval per clock toggle (posedge / negedge).
    // Phi enabled on rising edge, cleared on falling edge (matching NMK pattern).
    // SDRAM channels ticked on every rising edge.
    // Pixel clock: 1-cycle pulse every PIX_DIV rising edges.
    // Sound clock: 1-cycle pulse every SND_DIV rising edges.
    // ========================================================================
    fprintf(stderr, "Running RTL BUS eval loop (bypass_en=0)...\n");

    for (iter = 0; !done && iter < (uint64_t)n_frames * 2000000ULL; iter++) {
        // Toggle clock
        top->clk_sys = top->clk_sys ^ 1;

        // Release reset after RESET_ITERS half-cycles
        if (iter >= RESET_ITERS) top->reset_n = 1;

        if (top->clk_sys == 1) {
            // ── Rising edge ──────────────────────────────────────────────────

            // Phi enables (C++-driven, matching minimal-test pattern)
            top->enPhi1 = phi_toggle ? 0 : 1;
            top->enPhi2 = phi_toggle ? 1 : 0;
            phi_toggle  = !phi_toggle;

            // Pixel clock: fractional accumulator generating 6.75 MHz from 32 MHz
            // Ratio = 6.75/32 = 27/128 → accumulate 27 per sys_clk, fire at 128
            pix_acc += PIX_ACC_INC;
            if (pix_acc >= PIX_ACC_MOD) {
                pix_acc -= PIX_ACC_MOD;
                top->clk_pix = 1;

                // Advance our pixel counters (mirrors toaplan_v2 internal)
                ++hcnt;
                if (hcnt >= VID_H_TOTAL) {
                    hcnt = 0;
                    ++vcnt;
                    if (vcnt >= VID_V_TOTAL) vcnt = 0;
                }
            } else {
                top->clk_pix = 0;
            }

            // Sound clock: ~3.5 MHz CE
            ++snd_div_cnt;
            if (snd_div_cnt >= SND_DIV) {
                snd_div_cnt  = 0;
                top->clk_sound = 1;
            } else {
                top->clk_sound = 0;
            }

            // ── SDRAM channels ───────────────────────────────────────────────

            // Program ROM: combinational zero-latency (bypass toggle-handshake).
            // toaplan_v2's prog_rom_addr is a REGISTERED word address (lags CPU
            // addr by 1 cycle). Since dtack asserts the same cycle as AS_n, we
            // must use the LIVE CPU byte address (dbg_cpu_addr << 1) to get
            // the correct data for the current bus cycle.
            {
                uint32_t prog_byte_addr = ((uint32_t)top->dbg_cpu_addr << 1) & 0x0FFFFFu;
                top->prog_rom_data = sdram.read_word(prog_byte_addr);
                top->prog_rom_ack  = top->prog_rom_req;  // always ack immediately
            }

            // GFX ROM: combinational zero-latency (bypass toggle-handshake).
            // gfx_rom_addr is a WORD address; *2 for byte addr.
            // SDRAM GFX base is 0x100000 (added when sdram.load() was called).
            {
                uint32_t gfx_byte_addr = (uint32_t)top->gfx_rom_addr * 2u + 0x100000u;
                top->gfx_rom_data = sdram.read_dword(gfx_byte_addr);
                top->gfx_rom_ack  = top->gfx_rom_req;  // always ack immediately
            }

            // ADPCM ROM: toggle-handshake 16-bit
            {
                auto r = adpcm_ch.tick(top->adpcm_rom_req,
                                       (uint32_t)top->adpcm_rom_addr);
                top->adpcm_rom_data = r.data;
                top->adpcm_rom_ack  = r.ack;
            }

            // Z80 ROM: byte-wide, at SDRAM 0x600000
            {
                uint32_t z80_byte_addr = 0x600000u + (uint32_t)top->z80_rom_addr;
                auto r = z80_ch.tick(top->z80_rom_req, z80_byte_addr);
                top->z80_rom_data = r.data;
                top->z80_rom_ack  = r.ack;
            }

            // ── Bus diagnostics ──────────────────────────────────────────────
            {
                uint8_t  asn_c  = top->dbg_cpu_as_n;
                uint8_t  rwn_c  = top->dbg_cpu_rw;
                uint32_t addr_c = ((uint32_t)top->dbg_cpu_addr << 1) & 0xFFFFFF;

                // Cycle-level trace: log EVERY clock when AS_n=0 during first func_2799E
                // iteration to see what the $700016 read actually delivers
                if (!asn_c && iter > RESET_ITERS && bus_cycles_c >= 590255 && bus_cycles_c <= 590275) {
                    fprintf(stderr, "  [iter%7" PRIu64 "|bc%d] ASn=%d RW=%d addr=%06X dtack_n=%d din=%04X dout=%04X uds=%d lds=%d\n",
                            iter, bus_cycles_c, (int)asn_c, (int)rwn_c, addr_c,
                            (int)top->dbg_cpu_dtack_n,
                            (unsigned)(top->dbg_cpu_din & 0xFFFF),
                            (unsigned)(top->dbg_cpu_dout & 0xFFFF),
                            (int)top->dbg_cpu_uds_n,
                            (int)top->dbg_cpu_lds_n);
                }

                // Count bus cycles on AS_n falling edge (new cycle start)
                if (!asn_c && prev_asn_c && iter > RESET_ITERS) {
                    bus_cycles_c++;

                    // Log first 60 bus cycles in detail
                    if (bus_cycles_c <= 60) {
                        fprintf(stderr, "  [%6" PRIu64 "|bc%d] ASn=0 RW=%d addr=%06X dtack_n=%d dout=%04X\n",
                                iter, bus_cycles_c, (int)rwn_c, addr_c,
                                (int)top->dbg_cpu_dtack_n,
                                (unsigned)(top->dbg_cpu_dout & 0xFFFF));
                    }

                    // Track ROM PC (reads from program ROM = instruction fetches)
                    if (rwn_c && addr_c < 0x080000) {
                        last_rom_pc = addr_c;

                        // Milestone: game loop entry
                        if (addr_c == 0x0273E0 && !milestone_273E0) {
                            milestone_273E0 = true;
                            fprintf(stderr, "  *** MILESTONE: CPU reached game loop 0x273E0 at bc=%d frame=%d ***\n",
                                    bus_cycles_c, frame_num);
                        }
                        // Milestone: VBlank sync call
                        if (addr_c == 0x0274A2 && !milestone_274A2) {
                            milestone_274A2 = true;
                            fprintf(stderr, "  *** MILESTONE: CPU reached JSR $258 (VBlank sync) 0x274A2 at bc=%d frame=%d ***\n",
                                    bus_cycles_c, frame_num);
                        }
                        // Milestone: inside VBlank sync poll loop
                        if (addr_c == 0x00027E && !milestone_27E) {
                            milestone_27E = true;
                            fprintf(stderr, "  *** MILESTONE: CPU entered VBlank poll loop 0x27E at bc=%d frame=%d ***\n",
                                    bus_cycles_c, frame_num);
                        }
                    }
                    // Milestone: IRQ2 handler writes VBlank flag
                    if (!rwn_c && addr_c == 0x1002CE && !milestone_1002CE_wr) {
                        milestone_1002CE_wr = true;
                        fprintf(stderr, "  *** MILESTONE: IRQ2 handler wrote VBlank flag 0x1002CE at bc=%d frame=%d ***\n",
                                bus_cycles_c, frame_num);
                    }

                    // Pre-init loop tracing: log every bus cycle in 0x29A-0x2C5
                    // to observe BTST result, BEQ vs JMP outcome
                    if (addr_c >= 0x00029A && addr_c <= 0x0002C5) {
                        if (preinit_trace_count < PREINIT_TRACE_MAX) {
                            preinit_trace_count++;
                            fprintf(stderr, "  [preinit bc%d fr%d] RW=%d addr=%06X din=%04X ipl=%d\n",
                                    bus_cycles_c, frame_num, (int)rwn_c, addr_c,
                                    (unsigned)(top->dbg_cpu_din & 0xFFFF),
                                    (int)(top->dbg_cpu_dtack_n));
                        }
                        // Count BEQ (0x2BC) and JMP (0x2BE) fetches
                        if (rwn_c && addr_c == 0x0002BC) {
                            preinit_beq_count++;
                            if (preinit_beq_count <= 20)
                                fprintf(stderr, "  [BEQ@2BC #%d bc=%d fr=%d]\n",
                                        preinit_beq_count, bus_cycles_c, frame_num);
                        }
                        if (rwn_c && addr_c == 0x0002BE) {
                            preinit_jmp_count++;
                            if (preinit_jmp_count <= 20)
                                fprintf(stderr, "  [JMP@2BE #%d bc=%d fr=%d] *** GAME LOOP PATH ***\n",
                                        preinit_jmp_count, bus_cycles_c, frame_num);
                        }
                    }
                    // Track reads from $700016/$700017 ($38000B → io_cs case 5)
                    // Also log reads from $700000/$700001 (BTST #2 target)
                    if (rwn_c && (addr_c == 0x700000 || addr_c == 0x70000A ||
                                  addr_c == 0x70000B || addr_c == 0x70000C ||
                                  (addr_c >= 0x700014 && addr_c <= 0x700018))) {
                        preinit_btst_io_count++;
                        if (preinit_btst_io_count <= 60)
                            fprintf(stderr, "  [IO read addr=%06X #%d bc=%d fr=%d] din=%04X uds=%d lds=%d io_cs_bits[3:1]=%d\n",
                                    addr_c, preinit_btst_io_count, bus_cycles_c, frame_num,
                                    (unsigned)(top->dbg_cpu_din & 0xFFFF),
                                    (int)top->dbg_cpu_uds_n,
                                    (int)top->dbg_cpu_lds_n,
                                    (addr_c >> 1) & 7);
                    }
                    // Log ALL bus cycles after VBlank poll entry (bc>=640000)
                    // Wide window: now that GP9001_BASE is fixed, CPU should advance further
                    if (bus_cycles_c >= 640000 && bus_cycles_c <= 680000) {
                        fprintf(stderr, "  [bc%d fr%d] RW=%d addr=%06X din=%04X uds=%d lds=%d dtack=%d\n",
                                bus_cycles_c, frame_num, (int)rwn_c, addr_c,
                                (unsigned)(top->dbg_cpu_din & 0xFFFF),
                                (int)top->dbg_cpu_uds_n,
                                (int)top->dbg_cpu_lds_n,
                                (int)top->dbg_cpu_dtack_n);
                    }

                    // Track repeated reads to same address (polling loop detection)
                    if (rwn_c && addr_c == last_read_addr) {
                        last_read_repeat++;
                        if (last_read_repeat == 200 && stall_reported < 10) {
                            stall_reported++;
                            fprintf(stderr, "\n*** STALL DETECTED at bc=%d frame=%d: addr=%06X read 200+ times, dout=%04X (last_rom_pc=%06X) ***\n",
                                    bus_cycles_c, frame_num, addr_c,
                                    (unsigned)(top->dbg_cpu_dout & 0xFFFF),
                                    last_rom_pc);
                        }
                    } else {
                        last_read_addr   = addr_c;
                        last_read_repeat = rwn_c ? 1 : 0;
                    }

                    // Track palette and work RAM writes
                    if (!rwn_c) {
                        // Truxton II palette at 0x300000; Batsugun at 0x500000
                        if ((addr_c >= 0x300000 && addr_c <= 0x300FFF) ||
                            (addr_c >= 0x500000 && addr_c <= 0x5003FF)) {
                            ++pal_wr_count;
                            if (pal_wr_count <= 5)
                                fprintf(stderr, "  PAL WR #%d addr=%06X data=%04X\n",
                                        pal_wr_count, addr_c,
                                        (unsigned)(top->dbg_cpu_din & 0xFFFF));
                        }
                        if (addr_c >= 0x100000 && addr_c <= 0x10FFFF) {
                            ++wram_wr_count;
                            if (wram_wr_count <= 3)
                                fprintf(stderr, "  WRAM WR #%d addr=%06X\n",
                                        wram_wr_count, addr_c);
                        }
                    }
                }

                // Periodic status summary every 20K bus cycles
                if (bus_cycles_c > 0 && (bus_cycles_c % 20000) == 0 &&
                    !prev_asn_c && asn_c) {
                    fprintf(stderr, "  [%dK bus] last_rom_pc=%06X pal_wr=%d wram_wr=%d frame=%d [273E0:%s 274A2:%s 27E:%s vbl_wr:%s]\n",
                            bus_cycles_c / 1000, last_rom_pc, pal_wr_count, wram_wr_count,
                            frame_num,
                            milestone_273E0 ? "Y" : "N",
                            milestone_274A2 ? "Y" : "N",
                            milestone_27E   ? "Y" : "N",
                            milestone_1002CE_wr ? "Y" : "N");
                }

                // Detect CPU halt
                if (top->dbg_cpu_halted_n == 0 && iter > RESET_ITERS + 100 &&
                    !halted_reported) {
                    halted_reported = true;
                    fprintf(stderr,
                            "\n*** CPU HALTED at iter %" PRIu64
                            " (bus_cycles=%d) ***\n",
                            iter, bus_cycles_c);
                }

                prev_asn_c = asn_c;
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

        // ── Pixel capture (on rising edge, after eval) ───────────────────────
        if (top->clk_sys == 1) {
            bool active = (!top->vblank) && (!top->hblank);
            if (active) {
                // Use internal hcnt/vcnt which track toaplan_v2 timing
                int cx = hcnt - 1;  // hcnt incremented above before eval
                int cy = vcnt;
                if (cx < 0) cx = 0;
                if (cx >= 0 && cx < VID_H_ACTIVE && cy >= 0 && cy < VID_V_ACTIVE)
                    fb.set(cx, cy, top->rgb_r, top->rgb_g, top->rgb_b);
            }
        }

        // ── Vsync edge detection → frame save ────────────────────────────────
        {
            uint8_t vsync_n_now = top->vsync_n;
            if (vsync_n_prev == 1 && vsync_n_now == 0) {
                char fname[64];
                snprintf(fname, sizeof(fname), "frame_%04d.ppm", frame_num);
                if (fb.write_ppm(fname)) {
                    int nonblack = fb.count_nonblack();
                    fprintf(stderr, "Frame %4d written: %s  (bus_cycles=%d, nonblack=%d)\n",
                            frame_num, fname, bus_cycles_c, nonblack);
                }

                // Per-frame RAM dump (gate-5 MAME comparison)
                if (ram_dump_f) {
                    dump_frame_ram(ram_dump_f, (uint32_t)frame_num, top);
                    if ((frame_num % 10) == 0) fflush(ram_dump_f);
                }

                ++frame_num;
                if (frame_num >= n_frames) done = true;
                fb = FrameBuffer();
            }
            vsync_n_prev = vsync_n_now;
        }

        if ((iter % 2000000) == 0 && iter > 0) {
            fprintf(stderr, "  iter %" PRIu64 "  bus_cycles=%d  frame=%d\n",
                    iter, bus_cycles_c, frame_num);
        }

        // Detect if CPU stops executing bus cycles for 200K iters
        if (bus_cycles_c != last_bc_snapshot) {
            last_bc_snapshot   = bus_cycles_c;
            last_bc_change_iter = iter;
            no_bc_reports      = 0;
        } else if (bus_cycles_c > 0 && (iter - last_bc_change_iter) >= 200000) {
            if (no_bc_reports < 3) {
                no_bc_reports++;
                uint32_t cur_addr = ((uint32_t)top->dbg_cpu_addr << 1) & 0xFFFFFF;
                uint8_t  cur_asn  = top->dbg_cpu_as_n;
                uint8_t  cur_dtack = top->dbg_cpu_dtack_n;
                fprintf(stderr, "\n*** CPU NO-BC-CHANGE: bc=%d frozen for %" PRIu64 " iters"
                        " (last change at iter %" PRIu64 "); current addr=%06X ASn=%d DTACKn=%d halted_n=%d ***\n",
                        bus_cycles_c, iter - last_bc_change_iter, last_bc_change_iter,
                        cur_addr, (int)cur_asn, (int)cur_dtack,
                        (int)top->dbg_cpu_halted_n);
                last_bc_change_iter = iter;  // reset so we don't spam
            }
        }
    }

    // ── Final summary ────────────────────────────────────────────────────────
    if (vcd) { vcd->close(); delete vcd; }
    if (ram_dump_f) { fflush(ram_dump_f); fclose(ram_dump_f); }
    top->final();
    delete top;

    fprintf(stderr,
            "\nSimulation complete. %d frames captured, %" PRIu64
            " iters (%d bus cycles).\n",
            frame_num, iter, bus_cycles_c);

    // Report CPU boot status
    if (bus_cycles_c >= 6)
        fprintf(stderr, "CPU BOOT: SUCCESS (>= 6 bus cycles)\n");
    else
        fprintf(stderr, "CPU BOOT: FAIL (only %d bus cycles)\n", bus_cycles_c);

    // Pre-init loop stats
    fprintf(stderr, "Pre-init loop stats:\n");
    fprintf(stderr, "  BEQ@0x2BC fetched: %d times\n", preinit_beq_count);
    fprintf(stderr, "  JMP@0x2BE fetched: %d times (game loop path)\n", preinit_jmp_count);
    fprintf(stderr, "  $700001 reads:     %d times\n", preinit_btst_io_count);

    return 0;
}
