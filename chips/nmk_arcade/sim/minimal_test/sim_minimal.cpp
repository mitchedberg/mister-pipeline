// sim_minimal.cpp — Minimal fx68k Verilator testbench
//
// Tests ONLY the fx68k CPU with a flat ROM array.
// No SDRAM model, no NMK arcade, no complex bus logic.
//
// Phi pattern (from fx68k_adapter.sv):
//   cpu_ce fires every N system clocks (here: every rising edge, so N=1)
//   enPhi1 = cpu_ce &  ~phi_toggle  (even cpu_ce pulses)
//   enPhi2 = cpu_ce &   phi_toggle  (odd  cpu_ce pulses)
//   phi_toggle alternates on every cpu_ce; starts at 0 so first = phi1
//
// DTACK timing (standard 68000 cycle):
//   ASn goes low → CPU is on the bus
//   We present data and assert DTACKn=0 immediately (0-wait-state)
//   CPU samples DTACKn on rising edge while enPhi2 would fire → terminates cycle
//   ASn goes high → bus cycle complete, deassert DTACKn
//
// Environment variables:
//   ROM_FILE — path to interleaved program ROM binary

#include "Vtb_minimal.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>

// =============================================================================
// Memory: flat 1 MB array (ROM + writable RAM)
// =============================================================================
static constexpr size_t MEM_SIZE = 1 * 1024 * 1024;
static uint8_t mem[MEM_SIZE];

static uint16_t mem_read16(uint32_t byte_addr) {
    byte_addr &= (MEM_SIZE - 1);
    return ((uint16_t)mem[byte_addr] << 8) | mem[byte_addr + 1];
}

static void mem_write16(uint32_t byte_addr, uint16_t data, bool upper, bool lower) {
    byte_addr &= (MEM_SIZE - 1);
    if (upper) mem[byte_addr]     = (data >> 8) & 0xFF;
    if (lower) mem[byte_addr + 1] = data & 0xFF;
}

// =============================================================================
// Main
// =============================================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    // Suppress $stop from fx68k unique-case assertions during CPU init.
    Verilated::fatalOnError(false);

    // Load ROM
    const char* rom_file = getenv("ROM_FILE");
    if (!rom_file) {
        fprintf(stderr, "Error: ROM_FILE not set. Usage: ROM_FILE=/path/to/prog.bin ./sim_minimal\n");
        return 1;
    }

    memset(mem, 0xFF, sizeof(mem));

    FILE* f = fopen(rom_file, "rb");
    if (!f) {
        fprintf(stderr, "Error: Cannot open %s\n", rom_file);
        return 1;
    }
    size_t rom_bytes = fread(mem, 1, MEM_SIZE, f);
    fclose(f);
    fprintf(stdout, "Loaded %zu bytes from %s\n", rom_bytes, rom_file);

    uint32_t sp_init = ((uint32_t)mem[0]<<24)|((uint32_t)mem[1]<<16)|((uint32_t)mem[2]<<8)|mem[3];
    uint32_t pc_init = ((uint32_t)mem[4]<<24)|((uint32_t)mem[5]<<16)|((uint32_t)mem[6]<<8)|mem[7];
    fprintf(stdout, "Reset vector: SP=0x%08X  PC=0x%08X\n\n", sp_init, pc_init);

    Vtb_minimal* top = new Vtb_minimal;

    // -------------------------------------------------------------------------
    // Phi toggle: alternates on every rising clock edge.
    // phi_toggle=0 → enPhi1=1, enPhi2=0
    // phi_toggle=1 → enPhi1=0, enPhi2=1
    // -------------------------------------------------------------------------
    bool phi_toggle = false;

    // Bus state
    bool     dtack_n   = true;
    bool     prev_asn  = true;  // previous cycle's ASn value

    int      bus_cycles_done = 0;
    bool     success_printed = false;
    int      extra_cycles    = 0;

    // Initialize DUT
    top->clk    = 0;
    top->reset  = 1;
    top->enPhi1 = 0;
    top->enPhi2 = 0;
    top->iEdb   = 0xFFFF;
    top->DTACKn = 1;
    top->VPAn   = 1;
    top->eval();

    static constexpr int RESET_CLOCKS   = 20;  // hold reset for 20 clock half-cycles
    static constexpr int MAX_ITERATIONS = 100000;
    static constexpr int PRINT_LIMIT    = 200;

    fprintf(stdout, "%-8s %-4s %-4s %-10s %-6s %-6s %-8s %-5s %-5s\n",
            "iter", "ASn", "RWn", "addr", "data", "DTACKn", "HALTEDn", "phi1", "phi2");
    fprintf(stdout, "%-8s %-4s %-4s %-10s %-6s %-6s %-8s %-5s %-5s\n",
            "--------", "----", "----", "----------", "------", "------", "--------", "-----", "-----");

    for (int iter = 0; iter < MAX_ITERATIONS; iter++) {

        // Toggle clock
        top->clk = top->clk ^ 1;

        // Release reset after RESET_CLOCKS half-cycles
        if (iter >= RESET_CLOCKS) {
            top->reset = 0;
        }

        // On rising edge: update phi enables and bus logic
        if (top->clk == 1) {
            // Phi alternates every rising edge (after reset)
            if (iter >= RESET_CLOCKS) {
                top->enPhi1 = phi_toggle ? 0 : 1;
                top->enPhi2 = phi_toggle ? 1 : 0;
                phi_toggle  = !phi_toggle;
            } else {
                // During reset, let phi run so fx68k initializes properly
                top->enPhi1 = phi_toggle ? 0 : 1;
                top->enPhi2 = phi_toggle ? 1 : 0;
                phi_toggle  = !phi_toggle;
            }

            // Read current ASn BEFORE we set iEdb/DTACKn this cycle.
            // We look at the previous eval's output.
            uint8_t asn = top->ASn;
            uint8_t rwn = top->eRWn;
            uint32_t byte_addr = ((uint32_t)top->eab << 1) & 0xFFFFFF;

            // Detect bus cycle start (ASn low)
            if (!asn) {
                if (prev_asn) {
                    // Rising → falling edge of ASn: new bus cycle starting
                    // (prev_asn=1 means ASn just went low)
                }

                // Bus cycle active: present data and/or accept write
                if (rwn) {
                    // Read: present data on iEdb
                    top->iEdb = mem_read16(byte_addr);
                } else {
                    // Write: capture data from oEdb
                    bool upper = !top->UDSn;
                    bool lower = !top->LDSn;
                    mem_write16(byte_addr, top->oEdb, upper, lower);
                    top->iEdb = 0xFFFF;
                }

                // Assert DTACK immediately (0-wait-state)
                dtack_n = false;

            } else {
                // ASn is high: bus idle
                if (!prev_asn) {
                    // ASn just went high: bus cycle complete
                    bus_cycles_done++;
                }
                dtack_n   = true;
                top->iEdb = 0xFFFF;
            }

            top->DTACKn = dtack_n ? 1 : 0;

            // VPAn: autovector on interrupt acknowledge (FC=111 + !ASn)
            uint8_t fc = (top->FC2 << 2) | (top->FC1 << 1) | top->FC0;
            top->VPAn  = (fc == 0x7 && !top->ASn) ? 0 : 1;

            // Print first PRINT_LIMIT rising-edge states where ASn is active
            if (!asn && bus_cycles_done < PRINT_LIMIT) {
                fprintf(stdout, "%-8d %-4d %-4d %08X   %-6X %-6d %-8d %-5d %-5d\n",
                        iter, (int)asn, (int)rwn, byte_addr,
                        (int)top->iEdb, (int)top->DTACKn, (int)top->oHALTEDn,
                        (int)top->enPhi1, (int)top->enPhi2);
            }

            prev_asn = asn;
        } else {
            // Falling edge: clear phi enables
            top->enPhi1 = 0;
            top->enPhi2 = 0;
        }

        top->eval();

        // Success check
        if (!success_printed && bus_cycles_done > 6) {
            success_printed = true;
            fprintf(stdout, "\n*** SUCCESS: CPU is executing! (%d bus cycles completed) ***\n\n",
                    bus_cycles_done);
            fprintf(stdout, "%-10s %-8s %-4s %-12s %-6s\n",
                    "BusCycle#", "iter", "RWn", "addr", "data");
            fprintf(stdout, "%-10s %-8s %-4s %-12s %-6s\n",
                    "----------", "--------", "----", "------------", "------");
        }

        if (success_printed && extra_cycles < 1000 && top->clk == 1 && !top->ASn) {
            uint32_t byte_addr = ((uint32_t)top->eab << 1) & 0xFFFFFF;
            uint16_t data_at   = mem_read16(byte_addr);
            fprintf(stdout, "%-10d %-8d %-4d %08X     data=%04X\n",
                    bus_cycles_done, iter, (int)top->eRWn, byte_addr, data_at);
            extra_cycles++;
        }
    }

    fprintf(stdout, "\n--- Simulation complete ---\n");
    fprintf(stdout, "Total bus cycles: %d\n", bus_cycles_done);
    if (!success_printed) {
        fprintf(stdout, "RESULT: CPU did NOT complete more than 6 bus cycles in %d iterations.\n",
                MAX_ITERATIONS);
        fprintf(stdout, "Check reset/phi timing or ROM data.\n");
    }

    top->final();
    delete top;
    return 0;
}
