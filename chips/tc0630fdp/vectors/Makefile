CHIP_DIR   := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))/..

RTL        := $(CHIP_DIR)/rtl/tc0630fdp.sv
TB         := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))tb_tc0630fdp.cpp)
VEC_DIR    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
OBJ_DIR    := $(VEC_DIR)/obj_dir
VERILATOR  := verilator
PYTHON     := python3
VECFILE    := $(VEC_DIR)/step1_vectors.jsonl
SIM_BIN    := $(OBJ_DIR)/Vtc0630fdp

.PHONY: all vectors build run clean test
all: vectors build run

test: all

vectors: $(VECFILE)
$(VECFILE): $(VEC_DIR)/generate_vectors.py $(VEC_DIR)/fdp_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_vectors.py

build: $(SIM_BIN)
$(SIM_BIN): $(TB) $(RTL)
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR) -Wall --top-module tc0630fdp \
	    $(RTL) \
	    $(TB) --build -CFLAGS "-O2 -std=c++17" 2>&1

run: $(SIM_BIN) $(VECFILE)
	cd $(VEC_DIR) && $(SIM_BIN) $(VECFILE)

clean:
	rm -rf $(OBJ_DIR)
	rm -f $(VECFILE)
