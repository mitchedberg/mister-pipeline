// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Symbol table internal header
//
// Internal details; most calling programs do not need this header,
// unless using verilator public meta comments.

#ifndef VERILATED_VPSIKYO__SYMS_H_
#define VERILATED_VPSIKYO__SYMS_H_  // guard

#include "verilated.h"

// INCLUDE MODEL CLASS

#include "Vpsikyo.h"

// INCLUDE MODULE CLASSES
#include "Vpsikyo___024root.h"
#include "Vpsikyo_psikyo.h"

// SYMS CLASS (contains all model state)
class alignas(VL_CACHE_LINE_BYTES) Vpsikyo__Syms final : public VerilatedSyms {
  public:
    // INTERNAL STATE
    Vpsikyo* const __Vm_modelp;
    VlDeleter __Vm_deleter;
    bool __Vm_didInit = false;

    // MODULE INSTANCE STATE
    Vpsikyo___024root              TOP;
    Vpsikyo_psikyo                 TOP__psikyo;

    // CONSTRUCTORS
    Vpsikyo__Syms(VerilatedContext* contextp, const char* namep, Vpsikyo* modelp);
    ~Vpsikyo__Syms();

    // METHODS
    const char* name() const { return TOP.vlNamep; }
};

#endif  // guard
