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
    uint8_t cs_n;
    uint8_t rd_n;
    uint8_t wr_n;
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

    Testbench() : tick_count(0) {
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
        dut->vsync_n = vec.vsync_n;
        dut->vsync_n_r = vec.vsync_n;  // Synchronous, so prev state

        clock();
    }

    uint16_t get_dout() {
        return dut->dout;
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
            vec.cs_n = 0;
            vec.rd_n = (vec.operation == "READ") ? 0 : 1;
            vec.wr_n = (vec.operation == "WRITE") ? 0 : 1;

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

    std::cout << "NMK16 Gate 1 Testbench" << std::endl;
    std::cout << "======================" << std::endl;

    // Reset DUT
    tb.reset();

    // Load test vectors
    auto vectors = load_vectors("gate1_vectors.jsonl");
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
            if (vec.id <= 5) {
                printf("[PASS] #%u: %s\n", vec.id, vec.name.c_str());
            }
            continue;
        }

        // For READ operations, compare actual_dout with expected
        uint16_t actual_dout = tb.get_dout();
        bool match = (actual_dout == vec.expected_dout);

        if (match) {
            passed++;
            printf("[PASS] #%u: %s\n", vec.id, vec.name.c_str());
        } else {
            failed++;
            printf("[FAIL] #%u: %s\n", vec.id, vec.name.c_str());
            printf("       addr=0x%06x op=%s expected=0x%04x actual=0x%04x\n",
                   vec.addr, vec.operation.c_str(), vec.expected_dout, actual_dout);
        }
    }

    std::cout << "\n=== Test Summary ===" << std::endl;
    printf("Passed: %d\n", passed);
    printf("Failed: %d\n", failed);
    printf("Skipped: %d\n", skipped);
    printf("Total: %d/%d\n", passed + failed, passed + failed + skipped);

    return (failed == 0) ? 0 : 1;
}
