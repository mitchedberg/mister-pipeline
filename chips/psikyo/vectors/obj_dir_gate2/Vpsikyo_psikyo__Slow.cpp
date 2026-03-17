// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vpsikyo.h for the primary calling header

#include "Vpsikyo__pch.h"

void Vpsikyo_psikyo___ctor_var_reset(Vpsikyo_psikyo* vlSelf);

Vpsikyo_psikyo::Vpsikyo_psikyo() = default;
Vpsikyo_psikyo::~Vpsikyo_psikyo() = default;

void Vpsikyo_psikyo::ctor(Vpsikyo__Syms* symsp, const char* namep) {
    vlSymsp = symsp;
    vlNamep = strdup(Verilated::catName(vlSymsp->name(), namep));
    // Reset structure values
    Vpsikyo_psikyo___ctor_var_reset(this);
}

void Vpsikyo_psikyo::__Vconfigure(bool first) {
    (void)first;  // Prevent unused variable warning
}

void Vpsikyo_psikyo::dtor() {
    VL_DO_DANGLING(std::free(const_cast<char*>(vlNamep)), vlNamep);
}
