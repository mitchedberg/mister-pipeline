# Psikyo Gates 1, 2 & 3 Testbench Makefile
# Targets: all, gate1, gate2, gate3, vectors, build, run, test, clean

RTL_DIR = ../rtl
VERILATOR ?= verilator
CXX = clang++
CXXFLAGS = -std=c++17 -O2 -I/opt/homebrew/include
LDFLAGS = -L/opt/homebrew/lib
LIBS = -lm

RTL       = $(RTL_DIR)/psikyo.sv
RTL_GATE3 = $(RTL_DIR)/psikyo_gate3.sv

TB_GATE1 = tb_gate1.cpp
TB_GATE2 = tb_gate2.cpp
TB_GATE3 = tb_gate3.cpp

OBJ_DIR_GATE1 = obj_dir_gate1
OBJ_DIR_GATE2 = obj_dir_gate2
OBJ_DIR_GATE3 = obj_dir_gate3

TARGET_GATE1 = $(OBJ_DIR_GATE1)/Vpsikyo
TARGET_GATE2 = $(OBJ_DIR_GATE2)/Vpsikyo
TARGET_GATE3 = $(OBJ_DIR_GATE3)/Vpsikyo_gate3

PYTHON = python3

.PHONY: all gate1 gate2 gate3 vectors vectors-gate1 vectors-gate2 vectors-gate3 \
        build build-gate1 build-gate2 build-gate3 \
        test test-gate1 test-gate2 test-gate3 run clean help

all: test

gate1: vectors-gate1 build-gate1 test-gate1

gate2: vectors-gate2 build-gate2 test-gate2

gate3: vectors-gate3 build-gate3 test-gate3

vectors: vectors-gate1 vectors-gate2 vectors-gate3

vectors-gate1:
	$(PYTHON) generate_gate1.py

vectors-gate2:
	$(PYTHON) generate_gate2.py

vectors-gate3:
	$(PYTHON) generate_gate3.py

build: build-gate1 build-gate2 build-gate3

build-gate1: vectors-gate1 $(TARGET_GATE1)

build-gate2: vectors-gate2 $(TARGET_GATE2)

build-gate3: vectors-gate3 $(TARGET_GATE3)

$(TARGET_GATE1): $(RTL) $(TB_GATE1)
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR_GATE1) -Wall --top-module psikyo \
		-Wno-MODMISSING \
		-O0 -fno-dfg -fno-dfg-peephole \
		$(RTL) $(TB_GATE1) --build -CFLAGS "-O2 -std=c++17 -I/opt/homebrew/include" 2>&1

$(TARGET_GATE2): $(RTL) $(TB_GATE2)
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR_GATE2) -Wall --top-module psikyo \
		-Wno-MODMISSING \
		-O0 -fno-dfg -fno-dfg-peephole \
		$(RTL) $(TB_GATE2) --build -CFLAGS "-O2 -std=c++17 -I/opt/homebrew/include" 2>&1

$(TARGET_GATE3): $(RTL_GATE3) $(TB_GATE3)
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR_GATE3) -Wall --top-module psikyo_gate3 \
		-Wno-MODMISSING \
		-O0 -fno-dfg -fno-dfg-peephole \
		$(RTL_GATE3) $(TB_GATE3) --build -CFLAGS "-O2 -std=c++17 -I/opt/homebrew/include" 2>&1

test: test-gate1 test-gate2 test-gate3

test-gate1: build-gate1
	cd $(OBJ_DIR_GATE1) && ./Vpsikyo ../gate1_vectors.jsonl

test-gate2: build-gate2
	cd $(OBJ_DIR_GATE2) && ./Vpsikyo ../gate2_vectors.jsonl

test-gate3: build-gate3
	cd $(OBJ_DIR_GATE3) && ./Vpsikyo_gate3 ../gate3_vectors.jsonl 2>&1 | tee gate3_test.log
	@grep -q "Failed: 0" $(OBJ_DIR_GATE3)/gate3_test.log && \
		echo "PASS: Gate 3 all tests passed" || \
		(echo "FAIL: Gate 3 some tests failed" && exit 1)

run: test

clean:
	rm -rf $(OBJ_DIR_GATE1) $(OBJ_DIR_GATE2) $(OBJ_DIR_GATE3)
	rm -f gate1_vectors.jsonl gate2_vectors.jsonl gate3_vectors.jsonl
	rm -f *.vcd *.log

help:
	@echo "Psikyo Gate 1, 2 & 3 Test Targets:"
	@echo "  all         - Run all tests (default)"
	@echo "  gate1       - Run Gate 1 tests only"
	@echo "  gate2       - Run Gate 2 tests only"
	@echo "  gate3       - Run Gate 3 tests only"
	@echo "  vectors     - Generate all test vectors"
	@echo "  build       - Compile all testbenches"
	@echo "  test        - Run all tests"
	@echo "  clean       - Remove build artifacts"
