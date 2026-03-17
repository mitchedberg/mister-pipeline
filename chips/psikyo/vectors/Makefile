# Psikyo Gate 1 Testbench Makefile
# Targets: all, vectors, build, run, test, clean

RTL_DIR = ../rtl
VERILATOR ?= verilator
CXX = clang++
CXXFLAGS = -std=c++17 -O2 -I/opt/homebrew/include
LDFLAGS = -L/opt/homebrew/lib
LIBS = -lm

RTL = $(RTL_DIR)/psikyo.sv
TB = tb_gate1.cpp
OBJ_DIR = obj_dir
TARGET = $(OBJ_DIR)/Vpsikyo

PYTHON = python3

.PHONY: all vectors build run test clean

all: vectors build test

vectors:
	$(PYTHON) generate_gate1.py

build: vectors $(TARGET)

$(TARGET): $(RTL) $(TB)
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR) -Wall --top-module psikyo \
		-Wno-MODMISSING \
		-O0 -fno-dfg -fno-dfg-peephole \
		$(RTL) $(TB) --build -CFLAGS "-O2 -std=c++17 -I/opt/homebrew/include" 2>&1

run: build
	cd $(OBJ_DIR) && ./Vpsikyo ../gate1_vectors.jsonl

test: build
	cd $(OBJ_DIR) && ./Vpsikyo ../gate1_vectors.jsonl

clean:
	rm -rf $(OBJ_DIR) gate1_vectors.jsonl
	rm -f *.vcd

help:
	@echo "Psikyo Gate 1 Test Targets:"
	@echo "  all     - Generate vectors, build, and run tests (default)"
	@echo "  vectors - Generate test vectors (gate1_vectors.jsonl)"
	@echo "  build   - Compile Verilator testbench"
	@echo "  run     - Run compiled testbench"
	@echo "  test    - Run full test suite"
	@echo "  clean   - Remove build artifacts"
