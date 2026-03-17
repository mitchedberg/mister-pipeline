# Kaneko 16 Gate 1 Test Build
# Generates vectors, builds Verilator model, runs tests

VERILATOR := verilator
RTL := ../rtl/kaneko16.sv
TB := tb_gate1.cpp
OBJ_DIR := obj_dir
BIN := $(OBJ_DIR)/Vkaneko16

# Python interpreter
PYTHON := python3

.PHONY: all vectors build run test clean

all: test

vectors: gate1_vectors.jsonl

gate1_vectors.jsonl: generate_gate1.py gate1_model.py
	$(PYTHON) generate_gate1.py > gate1_vectors.jsonl 2>generate_gate1.log

build: $(BIN)

$(BIN): $(RTL) $(TB) vectors
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR) -Wall --top-module kaneko16 \
	    -Wno-MODMISSING \
	    -O0 -fno-dfg -fno-dfg-peephole \
	    $(RTL) $(TB) --build -CFLAGS "-O2 -std=c++17" 2>&1 | tee verilator_build.log

run: build
	$(BIN) < gate1_vectors.jsonl 2>&1 | tee test_results.txt

test: run
	@echo "Tests completed. Check test_results.txt for details."

clean:
	rm -rf $(OBJ_DIR)
	rm -f gate1_vectors.jsonl
	rm -f test_results.txt
	rm -f generate_gate1.log
	rm -f verilator_build.log

.SECONDARY: vectors
