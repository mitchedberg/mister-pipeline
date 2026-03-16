# Gate 4: Verilator behavioral comparison for tc0110pcr
# Usage:
#   make vectors   — generate test vectors (Python)
#   make build     — compile Verilator testbench
#   make run       — run the simulation
#   make           — vectors + build + run

CHIP_DIR   := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
RTL        := $(CHIP_DIR)/rtl/tc0110pcr.sv
TB         := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/tb_tc0110pcr.cpp)
VEC_DIR    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
OBJ_DIR    := $(VEC_DIR)/obj_dir

VERILATOR  := verilator
PYTHON     := python3

VECFILE    := $(VEC_DIR)/tier1_vectors.jsonl
SIM_BIN    := $(OBJ_DIR)/Vtc0110pcr

.PHONY: all vectors build run clean

all: vectors build run

vectors: $(VECFILE)

$(VECFILE): $(VEC_DIR)/generate_vectors.py $(VEC_DIR)/pcr_model.py
	@echo "--- Generating test vectors..."
	cd $(VEC_DIR) && $(PYTHON) generate_vectors.py

build: $(SIM_BIN)

$(SIM_BIN): $(TB) $(RTL)
	@echo "--- Compiling Verilator testbench..."
	$(VERILATOR) --cc --exe \
	    --Mdir $(OBJ_DIR) \
	    -Wall \
	    --top-module tc0110pcr \
	    $(RTL) \
	    $(TB) \
	    --build \
	    -CFLAGS "-O2 -std=c++17" \
	    2>&1
	@echo "--- Build complete: $(SIM_BIN)"

run: $(SIM_BIN) $(VECFILE)
	@echo "--- Running Gate 4 simulation..."
	cd $(VEC_DIR) && $(SIM_BIN) $(VECFILE)

clean:
	rm -rf $(OBJ_DIR)
	rm -f $(VECFILE)
