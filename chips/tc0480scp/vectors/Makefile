CHIP_DIR   := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))/..

RTL        := $(CHIP_DIR)/rtl/tc0480scp.sv
VEC_DIR    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TB         := $(VEC_DIR)/tb_tc0480scp.cpp
OBJ_DIR    := $(VEC_DIR)/obj_dir
VERILATOR  := verilator
PYTHON     := python3
VEC1       := $(VEC_DIR)/step1_vectors.jsonl
SIM_BIN    := $(OBJ_DIR)/Vtc0480scp

.PHONY: all vectors build run clean test
all: vectors build run

test: all

vectors: $(VEC1)

$(VEC1): $(VEC_DIR)/generate_vectors.py $(VEC_DIR)/scp_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_vectors.py

build: $(SIM_BIN)
$(SIM_BIN): $(TB) $(RTL)
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR) -Wall --top-module tc0480scp \
	    $(RTL) \
	    $(TB) --build -CFLAGS "-O2 -std=c++17" 2>&1

run: $(SIM_BIN) $(VEC1)
	cd $(VEC_DIR) && $(SIM_BIN) $(VEC1)

clean:
	rm -rf $(OBJ_DIR)
	rm -f $(VEC1)
