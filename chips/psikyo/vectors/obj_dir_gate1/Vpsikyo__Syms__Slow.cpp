// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Symbol table implementation internals

#include "Vpsikyo__pch.h"

Vpsikyo__Syms::Vpsikyo__Syms(VerilatedContext* contextp, const char* namep, Vpsikyo* modelp)
    : VerilatedSyms{contextp}
    // Setup internal state of the Syms class
    , __Vm_modelp{modelp}
    // Setup top module instance
    , TOP{this, namep}
{
    // Check resources
    Verilated::stackCheck(248);
    // Setup sub module instances
    TOP__psikyo.ctor(this, "psikyo");
    // Configure time unit / time precision
    _vm_contextp__->timeunit(-12);
    _vm_contextp__->timeprecision(-12);
    // Setup each module's pointers to their submodules
    TOP.__PVT__psikyo = &TOP__psikyo;
    // Setup each module's pointer back to symbol table (for public functions)
    TOP.__Vconfigure(true);
    TOP__psikyo.__Vconfigure(true);
    // Setup scopes
}

Vpsikyo__Syms::~Vpsikyo__Syms() {
    // Tear down scopes
    // Tear down sub module instances
    TOP__psikyo.dtor();
}
