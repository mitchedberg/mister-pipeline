CHIP_DIR   := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))/..

RTL        := $(CHIP_DIR)/rtl/gp9001.sv
VEC_DIR    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TB         := $(VEC_DIR)/tb_gate1.cpp
OBJ_DIR    := $(VEC_DIR)/obj_dir
VERILATOR  := verilator
PYTHON     := python3

VEC1       := $(VEC_DIR)/gate1_vectors.jsonl
SIM_BIN    := $(OBJ_DIR)/Vgp9001

.PHONY: all vectors build run clean test

all: vectors build run

test: all

vectors: $(VEC1)

$(VEC1): $(VEC_DIR)/generate_gate1.py $(VEC_DIR)/gate1_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_gate1.py

build: $(SIM_BIN)
$(SIM_BIN): $(TB) $(RTL)
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR) -Wall --top-module gp9001 \
	    -O0 -fno-dfg -fno-dfg-peephole \
	    $(RTL) \
	    $(TB) --build -CFLAGS "-O2 -std=c++17" 2>&1

run: $(SIM_BIN) $(VEC1)
	cd $(VEC_DIR) && $(SIM_BIN) $(VEC1)

clean:
	rm -rf $(OBJ_DIR)
	rm -f $(VEC1)
