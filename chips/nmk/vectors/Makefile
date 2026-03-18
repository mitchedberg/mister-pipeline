# NMK16 Test Makefile
# Targets: gate1, gate2, gate3, gate4, all, clean

VERILATOR ?= verilator
OBJ_DIR := obj
OBJ_DIR_G1 := obj_gate1
OBJ_DIR_G2 := obj_gate2
OBJ_DIR_G3 := obj_gate3
OBJ_DIR_G4 := obj_gate4
RTL := ../rtl/nmk16.sv

.PHONY: gate1 gate2 gate3 gate4 all clean

# Gate 1 targets
gate1: gate1_vectors.jsonl gate1_build gate1_test

gate1_vectors.jsonl: generate_gate1.py gate1_model.py
	python3 generate_gate1.py

gate1_build: $(OBJ_DIR_G1)/Vnmk16

$(OBJ_DIR_G1)/Vnmk16: $(RTL) tb_gate1.cpp | $(OBJ_DIR_G1)
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR_G1) -Wall --top-module nmk16 \
		-Wno-MODMISSING \
		-O0 -fno-dfg -fno-dfg-peephole \
		$(RTL) tb_gate1.cpp --build -CFLAGS "-O2 -std=c++17" 2>&1

gate1_test: gate1_build gate1_vectors.jsonl
	cd $(OBJ_DIR_G1) && ./Vnmk16 2>&1 | tee gate1_test.log
	@grep -q "Failed: 0" $(OBJ_DIR_G1)/gate1_test.log && echo "✓ Gate 1: All tests passed" || (echo "✗ Gate 1: Some tests failed" && exit 1)

$(OBJ_DIR_G1):
	mkdir -p $(OBJ_DIR_G1)

# Gate 2 targets
gate2: gate2_vectors.jsonl gate2_build gate2_test

gate2_vectors.jsonl: generate_gate2.py gate2_model.py
	python3 generate_gate2.py

gate2_build: $(OBJ_DIR_G2)/Vnmk16

$(OBJ_DIR_G2)/Vnmk16: $(RTL) tb_gate2.cpp | $(OBJ_DIR_G2)
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR_G2) -Wall --top-module nmk16 \
		-Wno-MODMISSING \
		-O0 -fno-dfg -fno-dfg-peephole \
		$(RTL) tb_gate2.cpp --build -CFLAGS "-O2 -std=c++17" 2>&1

gate2_test: gate2_build gate2_vectors.jsonl
	cd $(OBJ_DIR_G2) && ./Vnmk16 2>&1 | tee gate2_test.log
	@grep -q "Failed: 0" $(OBJ_DIR_G2)/gate2_test.log && echo "✓ Gate 2: All tests passed" || (echo "✗ Gate 2: Some tests failed" && exit 1)

$(OBJ_DIR_G2):
	mkdir -p $(OBJ_DIR_G2)

# Gate 3 targets
gate3: gate3_vectors.jsonl gate3_build gate3_test

gate3_vectors.jsonl: generate_gate3.py gate3_model.py
	python3 generate_gate3.py

gate3_build: $(OBJ_DIR_G3)/Vnmk16

$(OBJ_DIR_G3)/Vnmk16: $(RTL) tb_gate3.cpp | $(OBJ_DIR_G3)
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR_G3) -Wall --top-module nmk16 \
		-Wno-MODMISSING \
		-O0 -fno-dfg -fno-dfg-peephole \
		$(RTL) tb_gate3.cpp --build -CFLAGS "-O2 -std=c++17" 2>&1

gate3_test: gate3_build gate3_vectors.jsonl
	cd $(OBJ_DIR_G3) && ./Vnmk16 ../gate3_vectors.jsonl 2>&1 | tee gate3_test.log
	@grep -q "Failed: 0" $(OBJ_DIR_G3)/gate3_test.log && echo "✓ Gate 3: All tests passed" || (echo "✗ Gate 3: Some tests failed" && exit 1)

$(OBJ_DIR_G3):
	mkdir -p $(OBJ_DIR_G3)

# Gate 4 targets
gate4: gate4_vectors.jsonl gate4_build gate4_test

gate4_vectors.jsonl: generate_gate4.py gate4_model.py
	python3 generate_gate4.py

gate4_build: $(OBJ_DIR_G4)/Vnmk16

$(OBJ_DIR_G4)/Vnmk16: $(RTL) tb_gate4.cpp | $(OBJ_DIR_G4)
	$(VERILATOR) --cc --exe --Mdir $(OBJ_DIR_G4) -Wall --top-module nmk16 \
		-Wno-MODMISSING \
		-O0 -fno-dfg -fno-dfg-peephole \
		$(RTL) tb_gate4.cpp --build -CFLAGS "-O2 -std=c++17" 2>&1

gate4_test: gate4_build gate4_vectors.jsonl
	cd $(OBJ_DIR_G4) && ./Vnmk16 ../gate4_vectors.jsonl 2>&1 | tee gate4_test.log
	@grep -q "Failed: 0" $(OBJ_DIR_G4)/gate4_test.log && echo "✓ Gate 4: All tests passed" || (echo "✗ Gate 4: Some tests failed" && exit 1)

$(OBJ_DIR_G4):
	mkdir -p $(OBJ_DIR_G4)

# Combined targets
all: gate1 gate2 gate3 gate4
	@echo ""
	@echo "=== ALL GATES PASSED ==="

clean:
	rm -rf $(OBJ_DIR_G1) $(OBJ_DIR_G2) $(OBJ_DIR_G3) $(OBJ_DIR_G4) \
		gate1_vectors.jsonl gate2_vectors.jsonl gate3_vectors.jsonl gate4_vectors.jsonl *.log

.SILENT: clean
