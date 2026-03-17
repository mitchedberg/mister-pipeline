# TC0650FDA Step 1 — Verilator build + test
#
# Targets:
#   make            — generate vectors, build, run
#   make vectors    — generate tier1_vectors.jsonl from Python model
#   make build      — compile Verilator simulation binary
#   make run        — run the simulation
#   make clean      — remove generated files

CHIP_DIR   := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
RTL        := $(CHIP_DIR)/rtl/tc0650fda.sv
TB         := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/tb_tc0650fda.cpp)
VEC_DIR    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
OBJ_DIR    := $(VEC_DIR)/obj_dir

VERILATOR  := verilator
PYTHON     := python3

VECFILE    := $(VEC_DIR)/tier1_vectors.jsonl
SIM_BIN    := $(OBJ_DIR)/Vtc0650fda

.PHONY: all vectors build run clean test

all: vectors build run

test: all

vectors: $(VECFILE)

$(VECFILE): $(VEC_DIR)/generate_vectors.py $(VEC_DIR)/fda_model.py
	@echo "--- Generating test vectors..."
	cd $(VEC_DIR) && $(PYTHON) generate_vectors.py

build: $(SIM_BIN)

$(SIM_BIN): $(TB) $(RTL)
	@echo "--- Compiling Verilator testbench..."
	$(VERILATOR) --cc --exe \
	    --Mdir $(OBJ_DIR) \
	    -Wall \
	    --top-module tc0650fda \
	    $(RTL) \
	    $(TB) \
	    --build \
	    -CFLAGS "-O2 -std=c++17" \
	    2>&1
	@echo "--- Build complete: $(SIM_BIN)"

run: $(SIM_BIN) $(VECFILE)
	@echo "--- Running Step 1 simulation..."
	cd $(VEC_DIR) && $(SIM_BIN) $(VECFILE)

clean:
	rm -rf $(OBJ_DIR)
	rm -f $(VECFILE)
