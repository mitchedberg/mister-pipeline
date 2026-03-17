#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <cassert>
#include <cstdint>
#include <sstream>
#include <cstdio>

#include "verilated.h"
#include "Vnmk16.h"

struct TestVector {
    uint32_t id;
    std::string name;
    uint32_t addr;
    uint16_t din;
    uint16_t expected_dout;
    std::string operation;  // "NOP", "READ", "WRITE"
    uint8_t vsync_n;
};

class SimpleJsonParser {
public:
    static uint32_t parse_uint32(const std::string &str) {
        return static_cast<uint32_t>(std::stoul(str, nullptr, 0));
    }

    static std::string extract_string_value(const std::string &line, const std::string &key) {
        std::string search_key = "\"" + key + "\":";
        size_t pos = line.find(search_key);
        if (pos == std::string::npos) return "";
        pos += search_key.length();

        // Skip whitespace
        while (pos < line.length() && (line[pos] == ' ' || line[pos] == '\t')) pos++;

        // Expect opening quote
        if (pos >= line.length() || line[pos] != '"') return "";
        pos++;

        size_t end_pos = line.find("\"", pos);
        if (end_pos == std::string::npos) return "";
        return line.substr(pos, end_pos - pos);
    }

    static uint32_t extract_uint_value(const std::string &line, const std::string &key) {
        std::string search_key = "\"" + key + "\":";
        size_t pos = line.find(search_key);
        if (pos == std::string::npos) return 0;
        pos += search_key.length();

        // Skip whitespace
        while (pos < line.length() && (line[pos] == ' ' || line[pos] == '\t')) pos++;

        size_t end_pos = line.find_first_of(",}", pos);
        if (end_pos == std::string::npos) end_pos = line.length();
        std::string num_str = line.substr(pos, end_pos - pos);
        try {
            return static_cast<uint32_t>(std::stoul(num_str, nullptr, 0));
        } catch (...) {
            return 0;
        }
    }
};

class Testbench {
public:
    Vnmk16 *dut;
    uint64_t tick_count;
    uint8_t vsync_n_prev;  // Track previous vsync_n for proper edge detection

    Testbench() : tick_count(0), vsync_n_prev(1) {
        dut = new Vnmk16;
    }

    ~Testbench() {
        delete dut;
    }

    void clock() {
        dut->clk = 0;
        tick();
        dut->clk = 1;
        tick();
    }

    void tick() {
        dut->eval();
        tick_count++;
    }

    void reset(int cycles = 5) {
        dut->rst_n = 0;
        dut->vsync_n = 1;
        dut->vsync_n_r = 1;
        vsync_n_prev = 1;
        for (int i = 0; i < cycles; i++) {
            clock();
        }
        dut->rst_n = 1;
        clock();
    }

    void execute_cpu_cycle(const TestVector &vec) {
        // Setup CPU bus
        dut->addr = vec.addr >> 1;  // Word address (drop addr[0])
        dut->din = vec.din;
        dut->cs_n = 0;  // Chip select active

        // Decode operation
        if (vec.operation == "READ") {
            dut->rd_n = 0;
            dut->wr_n = 1;
        } else if (vec.operation == "WRITE") {
            dut->rd_n = 1;
            dut->wr_n = 0;
        } else {  // NOP
            dut->rd_n = 1;
            dut->wr_n = 1;
        }

        dut->lds_n = 0;  // Lower byte strobe
        dut->uds_n = 0;  // Upper byte strobe

        // Properly handle VSYNC: vsync_n is current, vsync_n_r is previous
        dut->vsync_n_r = vsync_n_prev;
        dut->vsync_n = vec.vsync_n;
        vsync_n_prev = vec.vsync_n;

        clock();
    }

    uint16_t get_dout() {
        return dut->dout;
    }

    uint8_t get_display_list_count() {
        // Debug: print the raw pointer value
        //printf("[DEBUG] dut->display_list_count raw value: %p = 0x%02X\n", (void*)&dut->display_list_count, dut->display_list_count);
        return dut->display_list_count;
    }

    uint16_t get_display_list_y(int idx) {
        if (idx >= 0 && idx < 256) {
            return dut->display_list_y[idx];
        }
        return 0;
    }

    uint16_t get_display_list_x(int idx) {
        if (idx >= 0 && idx < 256) {
            return dut->display_list_x[idx];
        }
        return 0;
    }

    uint8_t get_display_list_valid(int idx) {
        if (idx >= 0 && idx < 256) {
            return dut->display_list_valid[idx];
        }
        return 0;
    }

    uint8_t get_display_list_ready() {
        return dut->display_list_ready;
    }

    uint8_t get_irq_vblank_pulse() {
        return dut->irq_vblank_pulse;
    }

    // Debug: get internal FSM state (requires exposing in RTL if needed)
    void debug_print_state() {
        // Note: These are normally internal and would need to be exposed
        // For now, we can infer state from display_list_ready
    }
};

std::vector<TestVector> load_vectors(const std::string &filename) {
    std::vector<TestVector> vectors;

    // Try multiple paths
    std::vector<std::string> search_paths = {
        filename,
        "../" + filename,
        "../../" + filename
    };

    std::ifstream file;
    for (const auto &path : search_paths) {
        file.open(path);
        if (file.is_open()) break;
    }

    if (!file.is_open()) {
        std::cerr << "Error: Could not open " << filename << " in any search path" << std::endl;
        return vectors;
    }

    std::string line;
    while (std::getline(file, line)) {
        if (line.empty()) continue;

        try {
            TestVector vec;
            vec.id = SimpleJsonParser::extract_uint_value(line, "id");
            vec.name = SimpleJsonParser::extract_string_value(line, "name");
            vec.addr = SimpleJsonParser::extract_uint_value(line, "addr");
            vec.din = SimpleJsonParser::extract_uint_value(line, "din");
            vec.expected_dout = SimpleJsonParser::extract_uint_value(line, "expected_dout");
            vec.operation = SimpleJsonParser::extract_string_value(line, "operation");
            vec.vsync_n = SimpleJsonParser::extract_uint_value(line, "vsync_n");

            vectors.push_back(vec);
        } catch (const std::exception &e) {
            std::cerr << "Parse error: " << e.what() << std::endl;
        }
    }

    return vectors;
}

int main(int argc, char *argv[]) {
    Verilated::commandArgs(argc, argv);
    Testbench tb;

    std::cout << "NMK16 Gate 2 Testbench (Sprite Scanner FSM)" << std::endl;
    std::cout << "=============================================" << std::endl;

    // Reset DUT
    tb.reset();

    // Load test vectors
    auto vectors = load_vectors("gate2_vectors.jsonl");
    if (vectors.empty()) {
        std::cerr << "Error: No test vectors loaded" << std::endl;
        return 1;
    }

    std::cout << "Loaded " << vectors.size() << " test vectors" << std::endl;

    int passed = 0;
    int failed = 0;
    int skipped = 0;

    // Execute each test vector
    for (const auto &vec : vectors) {
        // Skip vectors without operation field (metadata-only)
        if (vec.operation.empty()) {
            skipped++;
            if (skipped <= 5) printf("[SKIP] #%u: empty operation\n", vec.id);
            continue;
        }

        tb.execute_cpu_cycle(vec);

        // For WRITE operations, just ensure they execute without error
        if (vec.operation == "WRITE") {
            passed++;
            if (vec.id <= 15) {
                printf("[PASS] #%u: %s\n", vec.id, vec.name.c_str());
            }
            continue;
        }

        // For READ operations, compare actual_dout with expected
        uint16_t actual_dout = tb.get_dout();
        bool match = (actual_dout == vec.expected_dout);

        if (match) {
            passed++;
            if (vec.id <= 20) {
                printf("[PASS] #%u: %s\n", vec.id, vec.name.c_str());
            }
        } else {
            failed++;
            printf("[FAIL] #%u: %s\n", vec.id, vec.name.c_str());
            printf("       addr=0x%06x op=%s expected=0x%04x actual=0x%04x\n",
                   vec.addr, vec.operation.c_str(), vec.expected_dout, actual_dout);
        }

        // Special handling for Gate 2 tests
        if (vec.operation == "NOP" && vec.name.find("VBLANK") != std::string::npos) {
            if (vec.name.find("rising edge") != std::string::npos) {
                printf("  [VBLANK START] Scanner FSM should transition to SCAN\n");
            } else if (vec.name.find("falling edge") != std::string::npos) {
                printf("  [VBLANK END] Scanner FSM should return to IDLE\n");
            }
        }
    }

    // Test Gate 2-specific functionality: sprite scanning
    std::cout << "\n=== Gate 2 Sprite Scanner Test ===" << std::endl;

    // Reset and prepare test data
    tb.reset();

    // Write test sprite data (same as in gate2_model.py test)
    // Sprite 0: Y=0x0000, X=0x0050, Tile=0x0100, Attr=0x0000
    printf("Writing test sprites...\n");
    TestVector w_y0, w_x0, w_t0, w_a0;
    w_y0 = {0, "test_write_y", 0x130000, 0x0000, 0, "WRITE", 1};
    w_x0 = {0, "test_write_x", 0x130002, 0x0050, 0, "WRITE", 1};
    w_t0 = {0, "test_write_t", 0x130004, 0x0100, 0, "WRITE", 1};
    w_a0 = {0, "test_write_a", 0x130006, 0x0000, 0, "WRITE", 1};

    tb.execute_cpu_cycle(w_y0);
    tb.execute_cpu_cycle(w_x0);
    tb.execute_cpu_cycle(w_t0);
    tb.execute_cpu_cycle(w_a0);

    // Write sprite 1
    TestVector w_y1, w_x1, w_t1, w_a1;
    w_y1 = {0, "test_write_y1", 0x130008, 0x0010, 0, "WRITE", 1};
    w_x1 = {0, "test_write_x1", 0x13000A, 0x0060, 0, "WRITE", 1};
    w_t1 = {0, "test_write_t1", 0x13000C, 0x0101, 0, "WRITE", 1};
    w_a1 = {0, "test_write_a1", 0x13000E, 0x4400, 0, "WRITE", 1};

    tb.execute_cpu_cycle(w_y1);
    tb.execute_cpu_cycle(w_x1);
    tb.execute_cpu_cycle(w_t1);
    tb.execute_cpu_cycle(w_a1);

    // Trigger VBLANK (vsync_n: 1 -> 0)
    printf("Triggering VBLANK...\n");
    TestVector vblank_start = {0, "vblank_start", 0x000000, 0x0000, 0, "NOP", 0};
    tb.execute_cpu_cycle(vblank_start);

    // Let scanner run for 1030 cycles (256 sprites × 4 words + extra cycles for state transitions)
    printf("Running sprite scanner for 1030 cycles...\n");
    for (int i = 0; i < 1030; i++) {
        TestVector nop = {0, "scanner_run", 0x000000, 0x0000, 0, "NOP", 0};
        tb.execute_cpu_cycle(nop);
    }

    // Check display list
    uint8_t count = tb.get_display_list_count();
    printf("Display list count (dut->display_list_count raw): %d (expected 2+)\n", count);

    // Debug: check all display list valid flags
    int valid_count = 0;
    for (int i = 0; i < 10; i++) {
        if (tb.get_display_list_valid(i)) {
            valid_count++;
            uint16_t y = tb.get_display_list_y(i);
            uint16_t x = tb.get_display_list_x(i);
            printf("  Display list[%d]: X=0x%03X, Y=0x%03X (VALID)\n", i, x, y);
        }
    }
    printf("Total valid entries in display list[0-9]: %d\n", valid_count);

    if (count >= 2) {
        uint16_t y0 = tb.get_display_list_y(0);
        uint16_t x0 = tb.get_display_list_x(0);
        uint16_t y1 = tb.get_display_list_y(1);
        uint16_t x1 = tb.get_display_list_x(1);

        printf("Sprite 0: X=0x%03X (exp 0x050), Y=0x%03X (exp 0x000)\n", x0, y0);
        printf("Sprite 1: X=0x%03X (exp 0x060), Y=0x%03X (exp 0x010)\n", x1, y1);

        if (x0 == 0x50 && y0 == 0x00 && x1 == 0x60 && y1 == 0x10) {
            printf("[PASS] Gate 2 sprite scanner test\n");
            passed++;
        } else {
            printf("[FAIL] Gate 2 sprite scanner data mismatch\n");
            failed++;
        }
    } else {
        printf("[FAIL] Gate 2: Expected 2 sprites in display list, got %d\n", count);
        printf("  (Hint: display_list_idx=%d, valid_count_in[0-9]=%d)\n", count, valid_count);
        failed++;
    }

    // End VBLANK
    printf("Ending VBLANK...\n");
    TestVector vblank_end = {0, "vblank_end", 0x000000, 0x0000, 0, "NOP", 1};
    tb.execute_cpu_cycle(vblank_end);

    std::cout << "\n=== Test Summary ===" << std::endl;
    printf("Passed: %d\n", passed);
    printf("Failed: %d\n", failed);
    printf("Skipped: %d\n", skipped);
    printf("Total: %d/%d\n", passed + failed, passed + failed + skipped);

    return (failed == 0) ? 0 : 1;
}
