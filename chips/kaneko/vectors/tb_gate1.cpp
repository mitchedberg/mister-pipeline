// Kaneko 16 Gate 1 Testbench
// Verilator C++17 testbench for RTL validation

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>

#include "Vkaneko16.h"
#include "verilated.h"

class TestBench {
  public:
    Vkaneko16 *dut;
    uint64_t sim_time;

    TestBench() : sim_time(0) {
        dut = new Vkaneko16();
        dut->clk = 0;
        dut->rst_n = 1;
    }

    ~TestBench() {
        delete dut;
    }

    void reset() {
        dut->clk = 0;
        dut->rst_n = 0;
        tick();
        tick();
        dut->rst_n = 1;
        tick();
        tick();
    }

    void tick() {
        dut->clk = !dut->clk;
        dut->eval();
        if (dut->clk) {
            sim_time++;
        }
    }

    void cpu_write(uint32_t addr, uint16_t data, int lds_n, int uds_n) {
        dut->cpu_addr = addr & 0x1FFFFF;
        dut->cpu_din = data;
        dut->cpu_cs_n = 0;
        dut->cpu_wr_n = 0;
        dut->cpu_lds_n = lds_n;
        dut->cpu_uds_n = uds_n;
        dut->cpu_rd_n = 1;
        tick();
        tick();
        dut->cpu_cs_n = 1;
        dut->cpu_wr_n = 1;
        tick();
    }

    void cpu_read(uint32_t addr) {
        dut->cpu_addr = addr & 0x1FFFFF;
        dut->cpu_cs_n = 0;
        dut->cpu_rd_n = 0;
        dut->cpu_wr_n = 1;
        dut->cpu_lds_n = 0;
        dut->cpu_uds_n = 0;
        tick();
        tick();
        // NOTE: Do NOT deselect yet - caller will read cpu_dout while still selected
    }

    void sprite_ram_write(uint16_t addr, uint16_t data) {
        cpu_write(0x120000 | addr, data, 0, 0);
    }

    void sprite_ram_read(uint16_t addr) {
        cpu_read(0x120000 | addr);
    }

    void vsync_pulse() {
        dut->vsync_n = 1;
        tick();
        tick();
        dut->vsync_n = 0;
        tick();
        tick();
        dut->vsync_n = 1;
        tick();
        tick();
    }

    uint16_t get_cpu_dout() {
        return dut->cpu_dout;
    }

    uint8_t get_watchdog_counter() {
        return dut->watchdog_counter;
    }

    uint16_t get_scroll_x_0() {
        return dut->scroll_x_0;
    }

    uint16_t get_scroll_y_0() {
        return dut->scroll_y_0;
    }

    uint16_t get_scroll_x_1() {
        return dut->scroll_x_1;
    }

    uint16_t get_scroll_y_1() {
        return dut->scroll_y_1;
    }
};

// Test vector data
struct TestVector {
    int id;
    const char *name;
    const char *op;
    uint32_t addr;
    uint16_t data;
    int lds_n;
    int uds_n;
    uint16_t expected_val;
};

int main(int argc, char **argv) {
    TestBench tb;
    tb.reset();

    int pass_count = 0;
    int fail_count = 0;

    // ====================================================================
    // Test 1: BG0 Scroll X write
    // ====================================================================
    {
        tb.cpu_write(0x0000, 0x5634, 0, 0);
        tb.cpu_read(0x0000);
        uint16_t actual = tb.get_cpu_dout();
        uint16_t expected = 0x5634;
        if (actual == expected) {
            printf("PASS [1] BG0 Scroll X write (expected=0x%04x, actual=0x%04x)\n", expected, actual);
            pass_count++;
        } else {
            printf("FAIL [1] BG0 Scroll X write (expected=0x%04x, actual=0x%04x)\n", expected, actual);
            fail_count++;
        }
    }

    // ====================================================================
    // Test 2: BG0 Scroll Y write
    // ====================================================================
    {
        tb.cpu_write(0x0002, 0xEFAB, 0, 0);
        tb.cpu_read(0x0002);
        uint16_t actual = tb.get_cpu_dout();
        uint16_t expected = 0xEFAB;
        if (actual == expected) {
            printf("PASS [2] BG0 Scroll Y write (expected=0x%04x, actual=0x%04x)\n", expected, actual);
            pass_count++;
        } else {
            printf("FAIL [2] BG0 Scroll Y write (expected=0x%04x, actual=0x%04x)\n", expected, actual);
            fail_count++;
        }
    }

    // ====================================================================
    // Test 3: BG1 Scroll X write
    // ====================================================================
    {
        tb.cpu_write(0x0100, 0x1111, 0, 0);
        tb.cpu_read(0x0100);
        uint16_t actual = tb.get_cpu_dout();
        uint16_t expected = 0x1111;
        if (actual == expected) {
            printf("PASS [3] BG1 Scroll X write (expected=0x%04x, actual=0x%04x)\n", expected, actual);
            pass_count++;
        } else {
            printf("FAIL [3] BG1 Scroll X write (expected=0x%04x, actual=0x%04x)\n", expected, actual);
            fail_count++;
        }
    }

    // ====================================================================
    // Test 4: BG1 Scroll Y write
    // ====================================================================
    {
        tb.cpu_write(0x0102, 0x2222, 0, 0);
        tb.cpu_read(0x0102);
        uint16_t actual = tb.get_cpu_dout();
        uint16_t expected = 0x2222;
        if (actual == expected) {
            printf("PASS [4] BG1 Scroll Y write (expected=0x%04x, actual=0x%04x)\n", expected, actual);
            pass_count++;
        } else {
            printf("FAIL [4] BG1 Scroll Y write (expected=0x%04x, actual=0x%04x)\n", expected, actual);
            fail_count++;
        }
    }

    // ====================================================================
    // Test 5: BG2 Scroll X write
    // ====================================================================
    {
        tb.cpu_write(0x0200, 0x3333, 0, 0);
        tb.cpu_read(0x0200);
        uint16_t actual = tb.get_cpu_dout();
        uint16_t expected = 0x3333;
        if (actual == expected) {
            printf("PASS [5] BG2 Scroll X write (expected=0x%04x, actual=0x%04x)\n", expected, actual);
            pass_count++;
        } else {
            printf("FAIL [5] BG2 Scroll X write (expected=0x%04x, actual=0x%04x)\n", expected, actual);
            fail_count++;
        }
    }

    // ====================================================================
    // Test 6: BG2 Scroll Y write
    // ====================================================================
    {
        tb.cpu_write(0x0202, 0x4444, 0, 0);
        tb.cpu_read(0x0202);
        uint16_t actual = tb.get_cpu_dout();
        uint16_t expected = 0x4444;
        if (actual == expected) {
            printf("PASS [6] BG2 Scroll Y write (expected=0x%04x, actual=0x%04x)\n", expected, actual);
            pass_count++;
        } else {
            printf("FAIL [6] BG2 Scroll Y write (expected=0x%04x, actual=0x%04x)\n", expected, actual);
            fail_count++;
        }
    }

    // ====================================================================
    // Test 7: BG3 Scroll X write
    // ====================================================================
    {
        tb.cpu_write(0x0300, 0x5555, 0, 0);
        tb.cpu_read(0x0300);
        uint16_t actual = tb.get_cpu_dout();
        uint16_t expected = 0x5555;
        if (actual == expected) {
            printf("PASS [7] BG3 Scroll X write (expected=0x%04x, actual=0x%04x)\n", expected, actual);
            pass_count++;
        } else {
            printf("FAIL [7] BG3 Scroll X write (expected=0x%04x, actual=0x%04x)\n", expected, actual);
            fail_count++;
        }
    }

    // ====================================================================
    // Test 8: BG3 Scroll Y write
    // ====================================================================
    {
        tb.cpu_write(0x0302, 0x6666, 0, 0);
        tb.cpu_read(0x0302);
        uint16_t actual = tb.get_cpu_dout();
        uint16_t expected = 0x6666;
        if (actual == expected) {
            printf("PASS [8] BG3 Scroll Y write (expected=0x%04x, actual=0x%04x)\n", expected, actual);
            pass_count++;
        } else {
            printf("FAIL [8] BG3 Scroll Y write (expected=0x%04x, actual=0x%04x)\n", expected, actual);
            fail_count++;
        }
    }

    // ====================================================================
    // Test 9: Layer Control BG0
    // ====================================================================
    {
        tb.cpu_write(0x0004, 0x55, 0, 1);
        tb.cpu_read(0x0004);
        uint16_t actual = tb.get_cpu_dout() & 0xFF;
        uint8_t expected = 0x55;
        if (actual == expected) {
            printf("PASS [9] Layer Control BG0 write (expected=0x%02x, actual=0x%02x)\n", expected, actual);
            pass_count++;
        } else {
            printf("FAIL [9] Layer Control BG0 write (expected=0x%02x, actual=0x%02x)\n", expected, actual);
            fail_count++;
        }
    }

    // ====================================================================
    // Test 10: Sprite Control
    // ====================================================================
    {
        tb.cpu_write(0x0400, 0xAA, 0, 1);
        tb.cpu_read(0x0400);
        uint16_t actual = tb.get_cpu_dout() & 0xFF;
        uint8_t expected = 0xAA;
        if (actual == expected) {
            printf("PASS [10] Sprite Control write (expected=0x%02x, actual=0x%02x)\n", expected, actual);
            pass_count++;
        } else {
            printf("FAIL [10] Sprite Control write (expected=0x%02x, actual=0x%02x)\n", expected, actual);
            fail_count++;
        }
    }

    // ====================================================================
    // Test 11: GFX Bank Select
    // ====================================================================
    {
        tb.cpu_write(0x0020, 0x42, 0, 1);
        tb.cpu_read(0x0020);
        uint16_t actual = tb.get_cpu_dout() & 0x7F;
        uint8_t expected = 0x42;
        if (actual == expected) {
            printf("PASS [11] GFX Bank Select write (expected=0x%02x, actual=0x%02x)\n", expected, actual);
            pass_count++;
        } else {
            printf("FAIL [11] GFX Bank Select write (expected=0x%02x, actual=0x%02x)\n", expected, actual);
            fail_count++;
        }
    }

    // ====================================================================
    // Test 12: Joystick 1
    // ====================================================================
    {
        tb.cpu_write(0x8000, 0x1234, 0, 0);
        tb.cpu_read(0x8000);
        uint16_t actual = tb.get_cpu_dout();
        uint16_t expected = 0x1234;
        if (actual == expected) {
            printf("PASS [12] Joystick 1 write (expected=0x%04x, actual=0x%04x)\n", expected, actual);
            pass_count++;
        } else {
            printf("FAIL [12] Joystick 1 write (expected=0x%04x, actual=0x%04x)\n", expected, actual);
            fail_count++;
        }
    }

    // ====================================================================
    // Test 13: Watchdog Kick
    // ====================================================================
    {
        tb.cpu_write(0x8008, 0x0000, 0, 0);
        uint8_t actual = tb.get_watchdog_counter();
        // Note: watchdog increments every clock, so after cpu_write's ticks, it will have incremented
        // cpu_write does ~3 ticks, so expect counter to be small but not zero
        // Actually, let me just check that it's close to 0 (hasn't overflowed)
        if (actual < 10) {
            printf("PASS [13] Watchdog kick reset (counter=%02x, acceptable)\n", actual);
            pass_count++;
        } else {
            printf("FAIL [13] Watchdog kick reset (expected < 10, actual=0x%02x)\n", actual);
            fail_count++;
        }
    }

    // ====================================================================
    // Test 14: Sprite RAM Write
    // ====================================================================
    {
        tb.sprite_ram_write(0x0000, 0xABCD);
        tb.sprite_ram_read(0x0000);
        uint16_t actual = tb.get_cpu_dout();
        uint16_t expected = 0xABCD;
        if (actual == expected) {
            printf("PASS [14] Sprite RAM write/read (expected=0x%04x, actual=0x%04x)\n", expected, actual);
            pass_count++;
        } else {
            printf("FAIL [14] Sprite RAM write/read (expected=0x%04x, actual=0x%04x)\n", expected, actual);
            fail_count++;
        }
    }

    // ====================================================================
    // Test 15: VBlank Edge - Shadow → Active Latch
    // ====================================================================
    {
        tb.cpu_write(0x0000, 0x7777, 0, 0);
        tb.cpu_write(0x0102, 0x8888, 0, 0);
        tb.vsync_pulse();
        uint16_t actual_x = tb.get_scroll_x_0();
        uint16_t actual_y = tb.get_scroll_y_1();
        uint16_t expected_x = 0x7777;
        uint16_t expected_y = 0x8888;

        bool pass = (actual_x == expected_x) && (actual_y == expected_y);
        if (pass) {
            printf("PASS [15] VBlank edge latch (x=0x%04x, y=0x%04x)\n", actual_x, actual_y);
            pass_count++;
        } else {
            printf("FAIL [15] VBlank edge latch (expected x=0x%04x y=0x%04x, actual x=0x%04x y=0x%04x)\n",
                   expected_x, expected_y, actual_x, actual_y);
            fail_count++;
        }
    }

    // ====================================================================
    // Test 16-20: More Sprite RAM tests
    // ====================================================================
    for (int i = 0; i < 5; i++) {
        uint16_t addr = (i + 1) * 2;
        uint16_t data = 0x4000 + (i * 0x0100);
        tb.sprite_ram_write(addr, data);
        tb.sprite_ram_read(addr);
        uint16_t actual = tb.get_cpu_dout();
        if (actual == data) {
            printf("PASS [%d] Sprite RAM [0x%04x] = 0x%04x\n", 16 + i, addr, actual);
            pass_count++;
        } else {
            printf("FAIL [%d] Sprite RAM [0x%04x] (expected=0x%04x, actual=0x%04x)\n", 16 + i, addr, data, actual);
            fail_count++;
        }
    }

    // Summary
    printf("\n========== TEST SUMMARY ==========\n");
    printf("PASS: %d\n", pass_count);
    printf("FAIL: %d\n", fail_count);
    printf("TOTAL: %d\n", pass_count + fail_count);

    return (fail_count > 0) ? 1 : 0;
}
