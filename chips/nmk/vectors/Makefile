# NMK16 Gate 1 Test Makefile
# Targets: all, vectors, build, run, test, clean

VERILATOR ?= verilator
OBJ_DIR := obj
RTL := ../rtl/nmk16.sv
TB := tb_gate1.cpp
EXE := $(OBJ_DIR)/Vnmk16

.PHONY: all vectors build run test clean

all: vectors build test

vectors: gate1_vectors.jsonl

gate1_vectors.jsonl: generate_gate1.py gate1_model.py
	python3 generate_gate1.py

build: $(EXE)

$(EXE): $(RTL) $(TB) | $(OBJ_DIR)
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR) -Wall --top-module nmk16 \
		-Wno-MODMISSING \
		-O0 -fno-dfg -fno-dfg-peephole \
		$(RTL) $(TB) --build -CFLAGS "-O2 -std=c++17" 2>&1

$(OBJ_DIR):
	mkdir -p $(OBJ_DIR)

run: build gate1_vectors.jsonl
	cd $(OBJ_DIR) && ./Vnmk16

test: build gate1_vectors.jsonl
	cd $(OBJ_DIR) && ./Vnmk16 2>&1 | tee test_output.log
	@grep -q "Failed: 0" test_output.log && echo "✓ All tests passed" || (echo "✗ Some tests failed" && exit 1)

clean:
	rm -rf $(OBJ_DIR) gate1_vectors.jsonl *.log

.SILENT: clean
