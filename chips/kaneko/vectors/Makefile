# Kaneko 16 Gate Tests
# Generates vectors, builds Verilator model, runs tests

VERILATOR := verilator
RTL := ../rtl/kaneko16.sv
OBJ_DIR := obj_dir
OBJ_DIR_G1 := obj_dir_gate1
OBJ_DIR_G2 := obj_dir_gate2
OBJ_DIR_G3 := obj_dir_gate3
BIN_G1 := $(OBJ_DIR_G1)/Vkaneko16
BIN_G2 := $(OBJ_DIR_G2)/Vkaneko16
BIN_G3 := $(OBJ_DIR_G3)/Vkaneko16

# Python interpreter
PYTHON := python3

.PHONY: all vectors build run test clean gate1 gate2 gate3

all: gate1 gate2 gate3

# ====================================================================
# Gate 1 Tests
# ====================================================================

gate1: $(BIN_G1)
	$(BIN_G1) < gate1_vectors.jsonl 2>&1 | tee test_results_gate1.txt
	@echo "Gate 1 tests completed. Check test_results_gate1.txt for details."

vectors: gate1_vectors.jsonl gate2_vectors.jsonl gate3_vectors.jsonl

gate1_vectors.jsonl: generate_gate1.py gate1_model.py
	$(PYTHON) generate_gate1.py > gate1_vectors.jsonl 2>generate_gate1.log

$(BIN_G1): $(RTL) tb_gate1.cpp gate1_vectors.jsonl
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR_G1) -Wall --top-module kaneko16 \
	    -Wno-MODMISSING -Wno-UNSIGNED -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CMPCONST \
	    -O0 -fno-dfg -fno-dfg-peephole \
	    $(RTL) tb_gate1.cpp --build -CFLAGS "-O2 -std=c++17" 2>&1 | tee verilator_build_gate1.log

# ====================================================================
# Gate 2 Tests
# ====================================================================

gate2: $(BIN_G2)
	$(BIN_G2) < gate2_vectors.jsonl 2>&1 | tee test_results_gate2.txt
	@echo "Gate 2 tests completed. Check test_results_gate2.txt for details."

gate2_vectors.jsonl: generate_gate2.py gate2_model.py
	$(PYTHON) generate_gate2.py > gate2_vectors.jsonl 2>generate_gate2.log

$(BIN_G2): $(RTL) tb_gate2.cpp gate2_vectors.jsonl
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR_G2) -Wall --top-module kaneko16 \
	    -Wno-MODMISSING -Wno-UNSIGNED -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CMPCONST \
	    -O0 -fno-dfg -fno-dfg-peephole \
	    $(RTL) tb_gate2.cpp --build -CFLAGS "-O2 -std=c++17" 2>&1 | tee verilator_build_gate2.log

# ====================================================================
# Gate 3 Tests — per-scanline sprite rasterizer (VU-001/VU-002)
# ====================================================================

gate3: $(BIN_G3)
	$(BIN_G3) gate3_vectors.jsonl 2>&1 | tee test_results_gate3.txt
	@echo "Gate 3 tests completed. Check test_results_gate3.txt for details."

gate3_vectors.jsonl: generate_gate3.py gate3_model.py
	$(PYTHON) generate_gate3.py 2>generate_gate3.log

$(BIN_G3): $(RTL) tb_gate3.cpp gate3_vectors.jsonl
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR_G3) -Wall --top-module kaneko16 \
	    -Wno-MODMISSING -Wno-UNSIGNED -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CMPCONST \
	    -Wno-UNOPTFLAT \
	    -O0 -fno-dfg -fno-dfg-peephole \
	    $(RTL) tb_gate3.cpp --build -CFLAGS "-O2 -std=c++17" 2>&1 | tee verilator_build_gate3.log

clean:
	rm -rf $(OBJ_DIR_G1) $(OBJ_DIR_G2) $(OBJ_DIR_G3) $(OBJ_DIR)
	rm -f gate1_vectors.jsonl gate2_vectors.jsonl gate3_vectors.jsonl
	rm -f test_results_gate1.txt test_results_gate2.txt test_results_gate3.txt test_results.txt
	rm -f generate_gate1.log generate_gate2.log generate_gate3.log
	rm -f verilator_build_gate1.log verilator_build_gate2.log verilator_build_gate3.log verilator_build.log

.SECONDARY: gate1_vectors.jsonl gate2_vectors.jsonl gate3_vectors.jsonl
