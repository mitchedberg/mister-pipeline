// Kaneko 16 Gate 2 Testbench
// Verilator C++17 testbench for sprite scanner validation

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>

#include "Vkaneko16.h"
#include "verilated.h"

// Simple JSON parser (no external dependencies)
class JSONParser {
public:
    static bool parse_json_line(const std::string& line, std::string& op,
                                uint32_t& sprite_idx, uint16_t& x, uint16_t& y,
                                uint16_t& tile, uint8_t& palette, uint8_t& flip_x,
                                uint8_t& flip_y, uint8_t& priority, uint8_t& size,
                                uint8_t& expected_count) {
        // Parse "op": "..." field
        size_t op_pos = line.find("\"op\"");
        if (op_pos == std::string::npos) return false;

        size_t op_start = line.find("\"", op_pos + 4) + 1;
        size_t op_end = line.find("\"", op_start);
        op = line.substr(op_start, op_end - op_start);

        // Parse numeric fields
        sprite_idx = parse_field(line, "sprite_index", 0);
        x = parse_field(line, "\"x\"", 0);
        y = parse_field(line, "\"y\"", 0);
        tile = parse_field(line, "\"tile\"", 0);
        palette = parse_field(line, "\"palette\"", 0);
        flip_x = parse_field(line, "\"flip_x\"", 0);
        flip_y = parse_field(line, "\"flip_y\"", 0);
        priority = parse_field(line, "\"priority\"", 0);
        size = parse_field(line, "\"size\"", 0);
        expected_count = parse_field(line, "expected_count", 0);

        return true;
    }

private:
    static uint32_t parse_field(const std::string& line, const std::string& field,
                                uint32_t default_val) {
        size_t pos = line.find("\"" + field + "\"");
        if (pos == std::string::npos) {
            pos = line.find(field);
            if (pos == std::string::npos) return default_val;
        }

        // Find the colon
        size_t colon_pos = line.find(":", pos);
        if (colon_pos == std::string::npos) return default_val;

        // Skip whitespace and look for number
        size_t start = colon_pos + 1;
        while (start < line.size() && (line[start] == ' ' || line[start] == '\"')) {
            start++;
        }

        size_t end = start;
        while (end < line.size() && isxdigit(line[end])) {
            end++;
        }

        if (end == start) return default_val;

        std::string num_str = line.substr(start, end - start);
        return std::stoul(num_str, nullptr, 0);
    }
};

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

    void sprite_ram_write(uint16_t addr, uint16_t data) {
        dut->cpu_addr = (0x120000 | addr) & 0x1FFFFF;
        dut->cpu_din = data;
        dut->cpu_cs_n = 0;
        dut->cpu_wr_n = 0;
        dut->cpu_lds_n = 0;
        dut->cpu_uds_n = 0;
        dut->cpu_rd_n = 1;
        tick();
        tick();
        dut->cpu_cs_n = 1;
        dut->cpu_wr_n = 1;
        tick();
    }

    void vsync_pulse() {
        dut->vsync_n = 1;
        tick();
        tick();
        dut->vsync_n = 0;  // Falling edge triggers scan
        tick();
        tick();
        dut->vsync_n = 1;
        tick();
        tick();
        // Wait for scan to complete (256 sprites + overhead)
        for (int i = 0; i < 400; i++) {
            tick();
        }
    }

    uint16_t get_display_list_count() {
        return dut->display_list_count;
    }

    bool is_display_list_ready() {
        return dut->display_list_ready;
    }

    // Note: Verilator flattens packed structs to QData
    // packed struct layout:
    // [54]      = valid
    // [53:50]   = size
    // [49:46]   = prio
    // [45]      = flip_y
    // [44]      = flip_x
    // [43:40]   = palette
    // [42:27]   = x (9 bits, but 16-bit slot)
    // [26:11]   = tile_num
    // [10:1]    = y (9 bits, but 10-bit slot)

    uint16_t get_sprite_x(int idx) {
        if (idx >= 0 && idx < 256) {
            uint64_t val = dut->display_list[idx];
            return (val >> 27) & 0x1FF;
        }
        return 0;
    }

    uint16_t get_sprite_y(int idx) {
        if (idx >= 0 && idx < 256) {
            uint64_t val = dut->display_list[idx];
            return (val >> 1) & 0x1FF;
        }
        return 0;
    }

    uint16_t get_sprite_tile(int idx) {
        if (idx >= 0 && idx < 256) {
            uint64_t val = dut->display_list[idx];
            return (val >> 11) & 0xFFFF;
        }
        return 0;
    }

    uint8_t get_sprite_palette(int idx) {
        if (idx >= 0 && idx < 256) {
            uint64_t val = dut->display_list[idx];
            return (val >> 40) & 0x0F;
        }
        return 0;
    }

    bool get_sprite_flip_x(int idx) {
        if (idx >= 0 && idx < 256) {
            uint64_t val = dut->display_list[idx];
            return (val >> 44) & 0x01;
        }
        return false;
    }

    bool get_sprite_flip_y(int idx) {
        if (idx >= 0 && idx < 256) {
            uint64_t val = dut->display_list[idx];
            return (val >> 45) & 0x01;
        }
        return false;
    }

    uint8_t get_sprite_priority(int idx) {
        if (idx >= 0 && idx < 256) {
            uint64_t val = dut->display_list[idx];
            return (val >> 46) & 0x0F;
        }
        return 0;
    }

    uint8_t get_sprite_size(int idx) {
        if (idx >= 0 && idx < 256) {
            uint64_t val = dut->display_list[idx];
            return (val >> 50) & 0x0F;
        }
        return 0;
    }

    bool get_sprite_valid(int idx) {
        if (idx >= 0 && idx < 256) {
            uint64_t val = dut->display_list[idx];
            return (val >> 54) & 0x01;
        }
        return false;
    }
};

int main(int argc, char **argv) {
    TestBench tb;
    tb.reset();

    int pass_count = 0;
    int fail_count = 0;

    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.empty()) continue;

        std::string op;
        uint32_t sprite_idx = 0;
        uint16_t x = 0, y = 0, tile = 0;
        uint8_t palette = 0, flip_x = 0, flip_y = 0, priority = 0, size = 0;
        uint8_t expected_count = 0;

        if (!JSONParser::parse_json_line(line, op, sprite_idx, x, y, tile, palette,
                                         flip_x, flip_y, priority, size,
                                         expected_count)) {
            continue;  // Skip unparseable lines
        }

        if (op == "write_sprite") {
            // Write sprite descriptor to RAM
            uint16_t base_addr = (sprite_idx & 0xFF) * 8;
            tb.sprite_ram_write(base_addr + 0, y & 0x01FF);
            tb.sprite_ram_write(base_addr + 1, tile);
            tb.sprite_ram_write(base_addr + 2, x & 0x01FF);

            uint16_t attr = (palette & 0x0F) | ((flip_x & 0x01) << 4) |
                            ((flip_y & 0x01) << 5) | ((priority & 0x0F) << 6) |
                            ((size & 0x0F) << 10);
            tb.sprite_ram_write(base_addr + 3, attr);

            printf("PASS [write_sprite] Sprite %d: Y=0x%03X, X=0x%03X, Tile=0x%04X\n",
                   sprite_idx, y, x, tile);
            pass_count++;

        } else if (op == "vsync_pulse") {
            // Trigger VBlank and wait for scan to complete
            tb.vsync_pulse();
            uint16_t count = tb.get_display_list_count();
            bool ready = tb.is_display_list_ready();

            if (ready && count == expected_count) {
                printf("PASS [vsync_pulse] Display list scanned: %d sprites ready\n", count);
                pass_count++;
            } else {
                printf("FAIL [vsync_pulse] Expected %d sprites, got %d (ready=%d)\n",
                       expected_count, count, ready);
                fail_count++;
            }

        } else if (op == "check_display_list_ready") {
            bool ready = tb.is_display_list_ready();
            if (ready) {
                printf("PASS [check_display_list_ready] Display list is ready\n");
                pass_count++;
            } else {
                printf("FAIL [check_display_list_ready] Display list not ready\n");
                fail_count++;
            }
        }
    }

    // Summary
    printf("\n========== TEST SUMMARY ==========\n");
    printf("PASS: %d\n", pass_count);
    printf("FAIL: %d\n", fail_count);
    printf("TOTAL: %d\n", pass_count + fail_count);

    return (fail_count > 0) ? 1 : 0;
}
