// Psikyo Gate 2 Verilator Testbench (Sprite Scanner)
// C++17 testbench for PS2001B sprite scanner validation
// NO external libraries — hand-rolled JSON parser

#include <iostream>
#include <fstream>
#include <sstream>
#include <vector>
#include <string>
#include <cstdint>
#include <cstring>
#include <cassert>
#include "Vpsikyo.h"
#include "verilated.h"

struct TestVector {
    uint32_t vector_id;
    int vsync_n;
    uint32_t spr_table_base;
    uint16_t spr_count;
    uint8_t spr_y_offset;
    uint8_t expected_display_list_count;
    std::vector<uint8_t> expected_valid_sprites;
    std::string name;
    std::string chip;
};

// Hand-rolled JSON parser (minimal, single-line)
class JSONParser {
private:
    std::string line;
    size_t pos;

    void skip_whitespace() {
        while (pos < line.length() && (line[pos] == ' ' || line[pos] == '\t' || line[pos] == '\n' || line[pos] == '\r')) {
            pos++;
        }
    }

    std::string parse_string() {
        skip_whitespace();
        if (pos >= line.length() || line[pos] != '"') {
            throw std::runtime_error("Expected '\"'");
        }
        pos++; // skip opening quote
        std::string result;
        while (pos < line.length() && line[pos] != '"') {
            if (line[pos] == '\\' && pos + 1 < line.length()) {
                pos++;
                result += line[pos];
            } else {
                result += line[pos];
            }
            pos++;
        }
        if (pos >= line.length()) {
            throw std::runtime_error("Unterminated string");
        }
        pos++; // skip closing quote
        return result;
    }

    double parse_number() {
        skip_whitespace();
        size_t start = pos;
        if (pos < line.length() && line[pos] == '-') {
            pos++;
        }
        while (pos < line.length() && (std::isdigit(line[pos]) || line[pos] == '.')) {
            pos++;
        }
        if (start == pos) {
            throw std::runtime_error("Invalid number");
        }
        return std::stod(line.substr(start, pos - start));
    }

    std::vector<uint8_t> parse_array() {
        std::vector<uint8_t> result;
        skip_whitespace();
        if (pos >= line.length() || line[pos] != '[') {
            throw std::runtime_error("Expected '['");
        }
        pos++; // skip opening bracket
        skip_whitespace();

        while (pos < line.length() && line[pos] != ']') {
            result.push_back((uint8_t)parse_number());
            skip_whitespace();
            if (pos < line.length() && line[pos] == ',') {
                pos++;
            }
            skip_whitespace();
        }

        if (pos >= line.length()) {
            throw std::runtime_error("Unterminated array");
        }
        pos++; // skip closing bracket
        return result;
    }

public:
    bool get_uint32(const std::string& key, uint32_t& value) {
        size_t key_pos = line.find("\"" + key + "\"");
        if (key_pos == std::string::npos) {
            return false;
        }
        pos = key_pos + key.length() + 2;
        skip_whitespace();
        if (pos >= line.length() || line[pos] != ':') {
            return false;
        }
        pos++;
        value = (uint32_t)parse_number();
        return true;
    }

    bool get_uint16(const std::string& key, uint16_t& value) {
        uint32_t v;
        if (!get_uint32(key, v)) {
            return false;
        }
        value = (uint16_t)v;
        return true;
    }

    bool get_uint8(const std::string& key, uint8_t& value) {
        uint32_t v;
        if (!get_uint32(key, v)) {
            return false;
        }
        value = (uint8_t)v;
        return true;
    }

    bool get_int(const std::string& key, int& value) {
        uint32_t v;
        if (!get_uint32(key, v)) {
            return false;
        }
        value = (int)v;
        return true;
    }

    bool get_string(const std::string& key, std::string& value) {
        size_t key_pos = line.find("\"" + key + "\"");
        if (key_pos == std::string::npos) {
            return false;
        }
        pos = key_pos + key.length() + 2;
        skip_whitespace();
        if (pos >= line.length() || line[pos] != ':') {
            return false;
        }
        pos++;
        value = parse_string();
        return true;
    }

    bool get_array_uint8(const std::string& key, std::vector<uint8_t>& value) {
        size_t key_pos = line.find("\"" + key + "\"");
        if (key_pos == std::string::npos) {
            return false;
        }
        pos = key_pos + key.length() + 2;
        skip_whitespace();
        if (pos >= line.length() || line[pos] != ':') {
            return false;
        }
        pos++;
        value = parse_array();
        return true;
    }

    bool parse(const std::string& input) {
        line = input;
        pos = 0;
        return true;
    }
};

class Gate2Testbench {
private:
    Vpsikyo* dut;
    uint64_t tick_count;
    int pass_count;
    int fail_count;
    std::vector<TestVector> vectors;

public:
    Gate2Testbench() : dut(nullptr), tick_count(0), pass_count(0), fail_count(0) {
        dut = new Vpsikyo();
        dut->clk = 0;
        dut->rst_n = 0;
    }

    ~Gate2Testbench() {
        delete dut;
    }

    void clock(int cycles = 1) {
        for (int i = 0; i < cycles; ++i) {
            dut->clk = !dut->clk;
            dut->eval();
            if (dut->clk) {
                tick_count++;
            }
        }
    }

    void reset() {
        dut->rst_n = 0;
        dut->cs_n = 1;
        dut->rd_n = 1;
        dut->wr_n = 1;
        dut->dsn = 0;
        dut->vsync_n = 1;
        dut->addr = 0;
        dut->din = 0;
        dut->eval();
        clock(10);
        dut->rst_n = 1;
        clock(2);
        dut->eval();
    }

    void write_ps2001b_register(uint16_t offset, uint16_t data) {
        uint32_t addr = 0x00040000 + offset; // Word-addressed: 0x00040000 is PS2001B base
        dut->addr = addr >> 1;
        dut->din = data;
        dut->cs_n = 0;
        dut->wr_n = 0;
        dut->dsn = 3;
        dut->eval();
        clock(1);
        dut->eval();

        dut->cs_n = 1;
        dut->wr_n = 1;
        dut->eval();
        clock(1);
        dut->eval();
    }

    void set_vsync(int vsync_n) {
        dut->vsync_n = vsync_n;
        dut->eval();
        clock(1);
    }

    bool check_display_list(uint8_t expected_count, const std::vector<uint8_t>& expected_valid) {
        // Wait for scanner to complete (up to 300 cycles for worst case 256-sprite scan)
        uint8_t last_count = 0;
        bool count_stable = false;

        for (int i = 0; i < 300; i++) {
            uint8_t current_count = dut->display_list_count;

            // If count stabilizes for 5 cycles, assume scan is done
            if (current_count == last_count && current_count == expected_count) {
                count_stable = true;
                break;
            }
            last_count = current_count;
            clock(1);
        }

        // Check display list count
        uint8_t actual_count = dut->display_list_count;
        if (actual_count != expected_count) {
            std::cerr << "FAIL: Expected " << (int)expected_count << " sprites, got " << (int)actual_count << std::endl;
            return false;
        }

        // Check which sprites are valid
        for (int i = 0; i < 256; i++) {
            bool expected_valid_here = false;
            for (uint8_t idx : expected_valid) {
                if (idx == i) {
                    expected_valid_here = true;
                    break;
                }
            }

            bool actual_valid = dut->display_list_valid[i];
            if (actual_valid != expected_valid_here) {
                std::cerr << "FAIL: Sprite " << i << " validity mismatch" << std::endl;
                return false;
            }
        }

        return true;
    }

    bool load_vectors(const std::string& filename) {
        std::ifstream file(filename);
        if (!file.is_open()) {
            std::cerr << "ERROR: Cannot open test vectors file: " << filename << std::endl;
            return false;
        }

        std::string line;
        int line_num = 0;
        while (std::getline(file, line)) {
            line_num++;
            if (line.empty()) continue;

            try {
                JSONParser parser;
                parser.parse(line);

                TestVector tv;
                tv.vector_id = 0;
                tv.vsync_n = 1;
                tv.spr_table_base = 0;
                tv.spr_count = 0;
                tv.spr_y_offset = 0;
                tv.expected_display_list_count = 0;

                parser.get_uint32("vector_id", tv.vector_id);
                parser.get_int("vsync_n", tv.vsync_n);
                parser.get_uint32("spr_table_base", tv.spr_table_base);
                parser.get_uint16("spr_count", tv.spr_count);
                parser.get_uint8("spr_y_offset", tv.spr_y_offset);
                parser.get_uint8("expected_display_list_count", tv.expected_display_list_count);
                parser.get_array_uint8("expected_valid_sprites", tv.expected_valid_sprites);
                parser.get_string("name", tv.name);
                parser.get_string("chip", tv.chip);

                vectors.push_back(tv);
            } catch (const std::exception& e) {
                std::cerr << "ERROR: Line " << line_num << ": " << e.what() << std::endl;
                return false;
            }
        }

        file.close();
        std::cout << "Loaded " << vectors.size() << " test vectors" << std::endl;
        return true;
    }

    void run_tests() {
        std::cout << "\n=== Gate 2 (Sprite Scanner) Test Execution ===" << std::endl;

        for (size_t i = 0; i < vectors.size(); ++i) {
            const TestVector& tv = vectors[i];

            // Setup: Write sprite control registers
            // PS2001B registers:
            //   0x00: CTRL
            //   0x04/0x06: TABLE_BASE (32-bit, 2 words)
            //   0x08: COUNT
            //   0x0A: Y_OFFSET

            // Write TABLE_BASE low word
            write_ps2001b_register(0x04, tv.spr_table_base & 0xFFFF);
            // Write TABLE_BASE high word
            write_ps2001b_register(0x06, (tv.spr_table_base >> 16) & 0xFFFF);
            // Write COUNT
            write_ps2001b_register(0x08, tv.spr_count);
            // Write Y_OFFSET
            write_ps2001b_register(0x0A, tv.spr_y_offset);

            // Trigger VSYNC rising edge
            // The rising edge is detected when vsync_n_scan_r=1 and vsync_n=0
            // Initially vsync_n=1, so we need to:
            // 1. Set vsync_n=0 and clock once to capture vsync_n_scan_r latching to 1
            // 2. This makes vsync_scan_rising=1 on that clock cycle
            // 3. Then set vsync_n back to 1

            dut->vsync_n = 0;
            dut->eval();
            clock(1);  // Cycle where rising edge is detected
            // At this point, vsync_n=0, vsync_n_scan_r was 1, so vsync_scan_rising=1
            // This causes scanner_next_state to transition to SCAN

            dut->vsync_n = 1;
            dut->eval();
            clock(1);  // Now vsync_scan_rising becomes 0

            // Check display list - allow plenty of time for scanner to run
            bool pass = check_display_list(tv.expected_display_list_count, tv.expected_valid_sprites);

            if (pass) {
                std::cout << "[" << (i + 1) << "] " << tv.name
                          << " (count=" << (int)tv.expected_display_list_count << ") → PASS" << std::endl;
                pass_count++;
            } else {
                std::cout << "[" << (i + 1) << "] " << tv.name
                          << " (count=" << (int)tv.expected_display_list_count << ") → FAIL" << std::endl;
                fail_count++;
            }

            // Reset for next test
            clock(5);
        }
    }

    void print_summary() {
        std::cout << "\n=== Test Summary ===" << std::endl;
        std::cout << "Total vectors:  " << vectors.size() << std::endl;
        std::cout << "Passed:         " << pass_count << std::endl;
        std::cout << "Failed:         " << fail_count << std::endl;
        if (vectors.size() > 0) {
            std::cout << "Success rate:   " << (100.0 * pass_count / vectors.size()) << "%" << std::endl;
        }

        if (fail_count == 0) {
            std::cout << "\n✓ ALL TESTS PASSED" << std::endl;
        } else {
            std::cout << "\n✗ " << fail_count << " TESTS FAILED" << std::endl;
        }
    }

    int get_fail_count() const {
        return fail_count;
    }
};

int main(int argc, char* argv[]) {
    Verilated::commandArgs(argc, argv);

    Gate2Testbench tb;
    tb.reset();

    // Load test vectors
    std::string vector_file = "gate2_vectors.jsonl";
    if (argc > 1) {
        vector_file = argv[1];
    }

    if (!tb.load_vectors(vector_file)) {
        return 1;
    }

    // Run all tests
    tb.run_tests();
    tb.print_summary();

    return (tb.get_fail_count() == 0) ? 0 : 1;
}
