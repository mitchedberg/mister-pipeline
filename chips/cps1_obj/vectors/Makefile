# Gate 4: Verilator behavioral comparison for cps1_obj
# Usage:
#   make vectors   — generate test vectors (Python)
#   make build     — compile Verilator testbench
#   make run       — run the simulation
#   make           — vectors + build + run

CHIP_DIR   := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
RTL        := $(CHIP_DIR)/rtl/cps1_obj.sv
TB         := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/tb_cps1_obj.cpp)
VEC_DIR    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
OBJ_DIR    := $(VEC_DIR)/obj_dir

VERILATOR  := verilator
PYTHON     := python3

VECFILE    := $(VEC_DIR)/tier1_vectors.jsonl
RAMFILE    := $(VEC_DIR)/tier1_obj_ram.jsonl
SIM_BIN    := $(OBJ_DIR)/Vcps1_obj

.PHONY: all vectors build run clean

all: vectors build run

vectors: $(VECFILE) $(RAMFILE)

$(VECFILE) $(RAMFILE): $(VEC_DIR)/generate_vectors.py $(VEC_DIR)/obj_model.py
	@echo "--- Generating test vectors..."
	cd $(VEC_DIR) && $(PYTHON) generate_vectors.py

build: $(SIM_BIN)

$(SIM_BIN): $(TB) $(RTL)
	@echo "--- Compiling Verilator testbench..."
	$(VERILATOR) --cc --exe \
	    --Mdir $(OBJ_DIR) \
	    -Wall \
	    --top-module cps1_obj \
	    $(RTL) \
	    $(TB) \
	    --build \
	    -CFLAGS "-O2 -std=c++17" \
	    2>&1
	@echo "--- Build complete: $(SIM_BIN)"

run: $(SIM_BIN) $(VECFILE) $(RAMFILE)
	@echo "--- Running Gate 4 simulation..."
	cd $(VEC_DIR) && $(SIM_BIN) $(VECFILE) $(RAMFILE)

clean:
	rm -rf $(OBJ_DIR)
	rm -f $(VECFILE) $(RAMFILE)
