// Psikyo Gate 1 Verilator Testbench
// C++17 testbench for CPU interface & register file validation

#include <iostream>
#include <fstream>
#include <sstream>
#include <vector>
#include <string>
#include <cstdint>
#include <nlohmann/json.hpp>
#include "Vpsikyo.h"
#include "verilated.h"

using json = nlohmann::json;

struct TestVector {
    uint32_t addr;
    uint32_t write_data;
    bool is_write;
    uint32_t expected_read;
    int vsync_n;
    std::string name;
    std::string chip;
};

class Gate1Testbench {
private:
    Vpsikyo* dut;
    uint64_t tick_count;
    int pass_count;
    int fail_count;

    std::vector<TestVector> vectors;

public:
    Gate1Testbench() : dut(nullptr), tick_count(0), pass_count(0), fail_count(0) {
        dut = new Vpsikyo();
        dut->clk = 0;
        dut->rst_n = 0;
    }

    ~Gate1Testbench() {
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
        dut->eval();
        clock(10);
        dut->rst_n = 1;
        clock(2);
        dut->eval();
    }

    void write_register(uint32_t addr, uint16_t data) {
        dut->addr = addr;  // addr is already word-addressed from test vectors
        dut->din = data;
        dut->cs_n = 0;
        dut->wr_n = 0;
        dut->dsn = 3;  // Both bytes
        dut->eval();   // Evaluate before clock
        clock(1);      // Clock rising edge triggers the write
        dut->eval();   // Evaluate after clock

        dut->cs_n = 1;
        dut->wr_n = 1;
        dut->eval();
        clock(1);
        dut->eval();
    }

    uint16_t read_register(uint32_t addr) {
        dut->addr = addr;  // addr is already word-addressed from test vectors
        dut->cs_n = 0;
        dut->rd_n = 0;
        dut->dsn = 3;
        dut->eval();  // Evaluate combinational logic to get data on dout

        uint16_t result = dut->dout;
        dut->cs_n = 1;
        dut->rd_n = 1;
        dut->eval();
        return result;
    }

    void set_vsync(int vsync_n) {
        dut->vsync_n = vsync_n;
        clock(1);
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
                json j = json::parse(line);
                TestVector tv;
                tv.addr = j["addr"].get<uint32_t>();
                tv.is_write = j["is_write"].get<bool>();
                tv.vsync_n = j.value("vsync_n", 1);
                tv.name = j.value("name", "");
                tv.chip = j.value("chip", "");

                if (tv.is_write) {
                    tv.write_data = j["write_data"].is_null() ? 0 : j["write_data"].get<uint32_t>();
                } else {
                    tv.expected_read = j["read_data"].is_null() ? 0 : j["read_data"].get<uint32_t>();
                }

                vectors.push_back(tv);
            } catch (const json::exception& e) {
                std::cerr << "ERROR: Line " << line_num << ": " << e.what() << std::endl;
                return false;
            }
        }

        file.close();
        std::cout << "Loaded " << vectors.size() << " test vectors" << std::endl;
        return true;
    }

    void run_tests() {
        std::cout << "\n=== Gate 1 Test Execution ===" << std::endl;

        for (size_t i = 0; i < vectors.size(); ++i) {
            const TestVector& tv = vectors[i];

            // Set VSYNC state
            set_vsync(tv.vsync_n);

            if (tv.is_write) {
                write_register(tv.addr, tv.write_data);
                std::cout << "[" << (i + 1) << "] " << tv.chip << "::" << tv.name
                          << " WRITE addr=" << std::hex << tv.addr << "(0x" << (tv.addr >> 17) << ") data=0x" << tv.write_data
                          << std::dec << " → OK" << std::endl;
                pass_count++;
            } else {
                uint16_t result = read_register(tv.addr);
                bool match = (result == (tv.expected_read & 0xFFFF));

                if (match) {
                    std::cout << "[" << (i + 1) << "] " << tv.chip << "::" << tv.name
                              << " READ addr=" << std::hex << tv.addr << "(0x" << (tv.addr >> 17) << ") expected=0x" << (tv.expected_read & 0xFFFF)
                              << " got=0x" << result << std::dec << " → PASS" << std::endl;
                    pass_count++;
                } else {
                    std::cout << "[" << (i + 1) << "] " << tv.chip << "::" << tv.name
                              << " READ addr=" << std::hex << tv.addr << "(0x" << (tv.addr >> 17) << ") expected=0x" << (tv.expected_read & 0xFFFF)
                              << " got=0x" << result << std::dec << " → FAIL" << std::endl;
                    fail_count++;
                }
            }
        }
    }

    void print_summary() {
        std::cout << "\n=== Test Summary ===" << std::endl;
        std::cout << "Total vectors:  " << vectors.size() << std::endl;
        std::cout << "Passed:         " << pass_count << std::endl;
        std::cout << "Failed:         " << fail_count << std::endl;
        std::cout << "Success rate:   " << (100.0 * pass_count / vectors.size()) << "%" << std::endl;

        if (fail_count == 0) {
            std::cout << "\n✓ ALL TESTS PASSED" << std::endl;
        } else {
            std::cout << "\n✗ " << fail_count << " TESTS FAILED" << std::endl;
        }
    }
};

int main(int argc, char* argv[]) {
    Verilated::commandArgs(argc, argv);

    Gate1Testbench tb;
    tb.reset();

    // Load test vectors
    std::string vector_file = "gate1_vectors.jsonl";
    if (argc > 1) {
        vector_file = argv[1];
    }

    if (!tb.load_vectors(vector_file)) {
        return 1;
    }

    // Run all tests
    tb.run_tests();
    tb.print_summary();

    return 0;
}
