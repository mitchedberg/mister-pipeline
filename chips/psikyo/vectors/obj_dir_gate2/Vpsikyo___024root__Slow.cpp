// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Design implementation internals
// See Vpsikyo.h for the primary calling header

#include "Vpsikyo__pch.h"

void Vpsikyo___024root___ctor_var_reset(Vpsikyo___024root* vlSelf);

Vpsikyo___024root::Vpsikyo___024root(Vpsikyo__Syms* symsp, const char* namep)
 {
    vlSymsp = symsp;
    vlNamep = strdup(namep);
    // Reset structure values
    Vpsikyo___024root___ctor_var_reset(this);
}

void Vpsikyo___024root::__Vconfigure(bool first) {
    (void)first;  // Prevent unused variable warning
}

Vpsikyo___024root::~Vpsikyo___024root() {
    VL_DO_DANGLING(std::free(const_cast<char*>(vlNamep)), vlNamep);
}
