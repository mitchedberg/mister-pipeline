// =============================================================================
// tb_system.cpp — NMK Arcade full-system Verilator testbench
//
// Wraps nmk_arcade.sv and drives all external interfaces:
//   - Clock (40 MHz) and reset
//   - MC68000 CPU bus stub (returns 0x4E71 NOP for all ROM reads so the CPU
//     spins in an NOP loop; the video hardware still cycles normally)
//   - Video timing generator (software-modelled NMK16 standard: 384×224 @ ~60 Hz)
//   - Five SDRAM channels (ToggleSdramChannel behavioral model)
//   - Player inputs (all held at 0xFF = no input, active-low)
//
// Environment variables:
//   N_FRAMES   — number of vertical frames to simulate (default 30)
//   ROM_PROG   — path to program ROM binary  (SDRAM 0x000000)
//   ROM_SPR    — path to sprite ROM binary   (SDRAM 0x0C0000)
//   ROM_BG     — path to BG tile ROM binary  (SDRAM 0x140000)
//   ROM_ADPCM  — path to ADPCM ROM binary    (SDRAM 0x200000)
//   ROM_Z80    — path to Z80 sound ROM binary(SDRAM 0x280000)
//   DUMP_VCD   — set to "1" to enable VCD trace (slow)
//
// Output:
//   frame_NNNN.ppm — one PPM file per vertical frame
//
// Video resolution: 384×224 (NMK16 standard)
//   Horizontal: 384 active + ~128 blanking = 512 total pixels/line
//   Vertical:   224 active +  ~38 blanking = 262 total lines/frame
//   At 40 MHz system clock, pixel clock divider = 2 → 20 MHz pixel clock
//   Htotal = 512, Vtotal = 262 → ~60.0 Hz
// =============================================================================

#include "Vnmk_arcade.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include "sdram_model.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <algorithm>

// ── Video timing constants (NMK16 standard 384×224) ─────────────────────────
static constexpr int VID_H_ACTIVE  = 384;
static constexpr int VID_V_ACTIVE  = 224;
static constexpr int VID_H_TOTAL   = 512;   // pixels per line
static constexpr int VID_V_TOTAL   = 262;   // lines per frame
static constexpr int VID_H_BLANK   = VID_H_TOTAL - VID_H_ACTIVE;
static constexpr int VID_V_BLANK   = VID_V_TOTAL - VID_V_ACTIVE;
static constexpr int VID_HSYNC_START = VID_H_ACTIVE + 16;
static constexpr int VID_HSYNC_END   = VID_HSYNC_START + 32;
static constexpr int VID_VSYNC_START = VID_V_ACTIVE + 4;
static constexpr int VID_VSYNC_END   = VID_VSYNC_START + 4;

// Pixel clock: one pixel every 2 system clocks (20 MHz from 40 MHz)
static constexpr int PIX_DIV = 2;

// ── CPU bus stub ─────────────────────────────────────────────────────────────
// The MC68000 CPU is NOT inside nmk_arcade.sv — it is an external component.
// We drive the bus from C++: return 0x4E71 (NOP) for all reads.
// The CPU stub uses a minimal 68K bus transaction model:
//   1. Assert AS_n, drive addr
//   2. Wait for DTACK_n to go low
//   3. Sample data
//   4. Deassert AS_n
// We model a trivially-simple CPU: after reset, read the reset vector from
// 0x000000 (SSP) and 0x000004 (PC), then execute NOP forever.

struct CpuStub {
    enum class Phase { RESET, FETCH_SSP_HI, FETCH_SSP_LO, FETCH_PC_HI, FETCH_PC_LO, RUN };

    Phase    phase       = Phase::RESET;
    int      reset_hold  = 0;
    uint32_t pc          = 0;
    uint32_t ssp         = 0;
    uint16_t hi_word     = 0;
    int      dtack_wait  = 0;
    bool     bus_active  = false;
    uint32_t bus_addr    = 0;   // word address (A[23:1])
    bool     bus_started = false;

    // Called after reset completes: begin reading reset vectors
    void start_reset_vectors() {
        phase      = Phase::FETCH_SSP_HI;
        bus_addr   = 0;          // SSP high word at byte 0x000000 → word addr 0
        bus_active = false;
        bus_started= false;
        dtack_wait = 0;
    }

    // Returns the current word address to drive on cpu_addr[23:1]
    uint32_t cpu_addr_word() const { return bus_addr; }
};

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
    const char* env_spr    = getenv("ROM_SPR");
    const char* env_bg     = getenv("ROM_BG");
    const char* env_adpcm  = getenv("ROM_ADPCM");
    const char* env_z80    = getenv("ROM_Z80");
    const char* env_vcd    = getenv("DUMP_VCD");

    int n_frames = env_frames ? atoi(env_frames) : 30;
    if (n_frames < 1) n_frames = 1;

    fprintf(stderr, "NMK Arcade simulation: %d frames\n", n_frames);

    // ── Load ROM data ────────────────────────────────────────────────────────
    SdramModel sdram;
    if (env_prog)  sdram.load(env_prog,  0x000000);
    if (env_spr)   sdram.load(env_spr,   0x0C0000);
    if (env_bg)    sdram.load(env_bg,    0x140000);
    if (env_adpcm) sdram.load(env_adpcm, 0x200000);
    // Z80 ROM is byte-addressed; load at 0x280000
    if (env_z80)   sdram.load(env_z80,   0x280000);

    // ── SDRAM channels ───────────────────────────────────────────────────────
    ToggleSdramChannel     prog_ch(sdram);
    ToggleSdramChannel     spr_ch(sdram);
    ToggleSdramChannel     bg_ch(sdram);
    ToggleSdramChannel     adpcm_ch(sdram);
    ToggleSdramChannelByte z80_ch(sdram);

    // ── Instantiate DUT ──────────────────────────────────────────────────────
    Vnmk_arcade* top = new Vnmk_arcade();

    // ── Optional VCD trace ───────────────────────────────────────────────────
    VerilatedVcdC* vcd = nullptr;
    if (env_vcd && env_vcd[0] == '1') {
        Verilated::traceEverOn(true);
        vcd = new VerilatedVcdC();
        top->trace(vcd, 99);
        vcd->open("sim_nmk_arcade.vcd");
        fprintf(stderr, "VCD trace enabled: sim_nmk_arcade.vcd\n");
    }

    // ── Initial port state ───────────────────────────────────────────────────
    top->clk_sys       = 0;
    top->clk_pix       = 0;
    top->reset_n       = 0;

    // CPU bus — deasserted
    top->cpu_addr      = 0;
    top->cpu_din       = 0;
    top->cpu_lds_n     = 1;
    top->cpu_uds_n     = 1;
    top->cpu_rw        = 1;   // read
    top->cpu_as_n      = 1;

    // SDRAM inputs
    top->prog_rom_data     = 0;
    top->prog_rom_ack      = 0;
    top->spr_rom_sdram_data= 0;
    top->spr_rom_sdram_ack = 0;
    top->bg_rom_sdram_data = 0;
    top->bg_rom_sdram_ack  = 0;
    top->adpcm_rom_data    = 0;
    top->adpcm_rom_ack     = 0;
    top->z80_rom_data      = 0;
    top->z80_rom_ack       = 0;

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
    uint64_t cycle      = 0;
    int      frame_num  = 0;
    bool     done       = false;

    // Video timing counters
    int  hcnt           = 0;   // horizontal pixel counter [0, H_TOTAL)
    int  vcnt           = 0;   // vertical line counter [0, V_TOTAL)
    int  pix_div_cnt    = 0;   // pixel clock divider counter

    // Frame buffer and pixel capture
    FrameBuffer fb;
    int  px             = 0;   // current write X (0..H_ACTIVE-1)
    int  py             = 0;   // current write Y (0..V_ACTIVE-1)
    bool in_active      = false;

    // vsync edge detection
    uint8_t vsync_n_prev = 1;

    // CPU stub state
    CpuStub cpu;
    int reset_cycles_remaining = 16;
    bool cpu_bus_cycle_active  = false;
    int  dtack_wait            = 0;

    // ── Helper: posedge clk tick ─────────────────────────────────────────────
    auto tick = [&]() {
        // ── Video timing ─────────────────────────────────────────────────────
        ++pix_div_cnt;
        if (pix_div_cnt >= PIX_DIV) {
            pix_div_cnt = 0;
            top->clk_pix = 1;  // one-cycle-wide pulse

            // Compute sync/blank signals
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

            // Drive hpos/vpos to the GPU
            // hpos is 9-bit: x position within the active line
            // vpos is 8-bit: y position within the active frame
            top->hpos = (uint16_t)(h_active ? hcnt : 0);
            top->vpos = (uint8_t) (v_active ? vcnt : 0);

            // Advance pixel counter
            ++hcnt;
            if (hcnt >= VID_H_TOTAL) {
                hcnt = 0;
                ++vcnt;
                if (vcnt >= VID_V_TOTAL) {
                    vcnt = 0;
                }
            }
        } else {
            top->clk_pix = 0;
        }

        // ── SDRAM channels ───────────────────────────────────────────────────
        {
            auto r = prog_ch.tick(top->prog_rom_req, top->prog_rom_addr);
            top->prog_rom_data = r.data;
            top->prog_rom_ack  = r.ack;
        }
        {
            auto r = spr_ch.tick(top->spr_rom_sdram_req, top->spr_rom_sdram_addr);
            top->spr_rom_sdram_data = r.data;
            top->spr_rom_sdram_ack  = r.ack;
        }
        {
            auto r = bg_ch.tick(top->bg_rom_sdram_req, top->bg_rom_sdram_addr);
            top->bg_rom_sdram_data = r.data;
            top->bg_rom_sdram_ack  = r.ack;
        }
        {
            auto r = adpcm_ch.tick(top->adpcm_rom_req, (uint32_t)top->adpcm_rom_addr);
            top->adpcm_rom_data = r.data;
            top->adpcm_rom_ack  = r.ack;
        }
        {
            // Z80 ROM: addr is 16-bit, mapped from SDRAM base 0x280000
            uint32_t z80_byte_addr = 0x280000u + (uint32_t)top->z80_rom_addr;
            auto r = z80_ch.tick(top->z80_rom_req, z80_byte_addr);
            top->z80_rom_data = r.data;
            top->z80_rom_ack  = r.ack;
        }

        // ── CPU bus stub ─────────────────────────────────────────────────────
        // Simple strategy: after reset, run NOP (0x4E71) bus cycles forever.
        // The CPU reads one word per ~8 cycles (10 MHz effective).
        // We use a simplistic state machine: every ~8 clk_sys cycles, issue one
        // read cycle. This mimics the 68K fetch rate at 10 MHz / 40 MHz ratio.
        if (reset_cycles_remaining > 0) {
            top->cpu_as_n = 1;
            top->cpu_rw   = 1;
            --reset_cycles_remaining;
        } else if (!cpu_bus_cycle_active) {
            // Start a new read cycle: read from PC address (word-aligned)
            // We stub PC at 0 and never advance it — the CPU sees NOPs.
            static uint32_t stub_addr = 0;
            top->cpu_addr  = (uint16_t)(stub_addr >> 1) & 0x7FFF; // word addr [14:1]
            top->cpu_rw    = 1;    // read
            top->cpu_uds_n = 0;
            top->cpu_lds_n = 0;
            top->cpu_as_n  = 0;
            cpu_bus_cycle_active = true;
            dtack_wait = 0;
        } else {
            // Bus cycle in progress — wait for DTACK_n
            if (top->cpu_dtack_n == 0) {
                // DTACK received — complete the cycle
                // (We ignore the data since we're just stubbing NOP execution)
                top->cpu_as_n  = 1;
                top->cpu_uds_n = 1;
                top->cpu_lds_n = 1;
                cpu_bus_cycle_active = false;
            } else {
                ++dtack_wait;
                if (dtack_wait > 32) {
                    // Timeout — give up and deassert
                    top->cpu_as_n  = 1;
                    top->cpu_uds_n = 1;
                    top->cpu_lds_n = 1;
                    cpu_bus_cycle_active = false;
                    dtack_wait = 0;
                }
            }
        }

        // ── Posedge eval ─────────────────────────────────────────────────────
        top->clk_sys = 1;
        top->eval();
        if (vcd) vcd->dump((vluint64_t)(cycle * 2 + 1));

        // ── Capture pixel (on posedge, after DUT has settled) ────────────────
        // Capture when inside the active display area, driven by our own
        // hcnt/vcnt counters (one-cycle ahead of the DUT output register, which
        // is fine for a visual dump).
        {
            // Use the previous cycle's hcnt/vcnt (before the pixel advance above)
            // For simplicity, capture using DUT's own vsync/hsync outputs.
            // Active area: !vblank && !hblank from DUT
            bool active = (!top->vblank) && (!top->hblank);
            if (active) {
                // hpos and vpos are driven from our counters above
                int cx = (int)top->hpos;
                int cy = (int)top->vpos;
                if (cx >= 0 && cx < VID_H_ACTIVE && cy >= 0 && cy < VID_V_ACTIVE) {
                    fb.set(cx, cy, top->rgb_r, top->rgb_g, top->rgb_b);
                }
            }
        }

        // ── Detect vsync falling edge (DUT output) ────────────────────────────
        uint8_t vsync_n_now = top->vsync_n;
        if (vsync_n_prev == 1 && vsync_n_now == 0) {
            // Vertical sync start — write the frame we just captured
            char fname[64];
            snprintf(fname, sizeof(fname), "frame_%04d.ppm", frame_num);
            if (fb.write_ppm(fname))
                fprintf(stderr, "Frame %4d written: %s\n", frame_num, fname);
            ++frame_num;
            if (frame_num >= n_frames) done = true;
            // Clear frame buffer for next frame
            fb = FrameBuffer();
        }
        vsync_n_prev = vsync_n_now;

        // ── Negedge ──────────────────────────────────────────────────────────
        top->clk_sys = 0;
        top->clk_pix = 0;
        top->eval();
        if (vcd) vcd->dump((vluint64_t)(cycle * 2));

        ++cycle;

        if ((cycle % 100000) == 0) {
            fprintf(stderr, "  cycle %7" PRIu64 "  frame %d / %d\n",
                    cycle, frame_num, n_frames);
        }
    };

    // ── Reset sequence ────────────────────────────────────────────────────────
    top->reset_n = 0;
    for (int i = 0; i < 16; i++) tick();
    top->reset_n = 1;
    reset_cycles_remaining = 0;  // CPU stub can start after HW reset

    fprintf(stderr, "Reset released. Running %d frames...\n", n_frames);

    // ── Main simulation loop ─────────────────────────────────────────────────
    while (!done && !Verilated::gotFinish()) {
        tick();
    }

    // ── Final cleanup ────────────────────────────────────────────────────────
    if (vcd) {
        vcd->close();
        delete vcd;
    }
    top->final();
    delete top;

    fprintf(stderr, "Simulation complete. %d frames captured, %" PRIu64 " cycles.\n",
            frame_num, cycle);
    return 0;
}
