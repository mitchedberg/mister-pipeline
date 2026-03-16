CHIP_DIR   := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))/..

RTL        := $(CHIP_DIR)/rtl/tc0180vcu.sv $(CHIP_DIR)/rtl/tc0180vcu_tx.sv $(CHIP_DIR)/rtl/tc0180vcu_bg.sv
TB         := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))tb_tc0180vcu.cpp)
VEC_DIR    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
OBJ_DIR    := $(VEC_DIR)/obj_dir
VERILATOR  := verilator
PYTHON     := python3
VECFILE    := $(VEC_DIR)/tier1_vectors.jsonl
SIM_BIN    := $(OBJ_DIR)/Vtc0180vcu

.PHONY: all vectors build run clean
all: vectors build run

vectors: $(VECFILE)
$(VECFILE): $(VEC_DIR)/generate_vectors.py $(VEC_DIR)/vcu_model.py
	cd $(VEC_DIR) && $(PYTHON) generate_vectors.py

build: $(SIM_BIN)
$(SIM_BIN): $(TB) $(RTL)
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR) -Wall --top-module tc0180vcu \
	    $(CHIP_DIR)/rtl/tc0180vcu_tx.sv $(CHIP_DIR)/rtl/tc0180vcu_bg.sv \
	    $(CHIP_DIR)/rtl/tc0180vcu.sv \
	    $(TB) --build -CFLAGS "-O2 -std=c++17" 2>&1

run: $(SIM_BIN) $(VECFILE)
	cd $(VEC_DIR) && $(SIM_BIN) $(VECFILE)

clean:
	rm -rf $(OBJ_DIR)
	rm -f $(VECFILE)
