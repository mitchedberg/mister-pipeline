# TC0650FDA chip-level Makefile
# Delegates to vectors/Makefile for Verilator simulation.

.PHONY: all test vectors build run clean

all test: vectors build run

vectors:
	$(MAKE) -C vectors vectors

build:
	$(MAKE) -C vectors build

run:
	$(MAKE) -C vectors run

clean:
	$(MAKE) -C vectors clean
