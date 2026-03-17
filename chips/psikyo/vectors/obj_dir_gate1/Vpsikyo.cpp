// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Model implementation (design independent parts)

#include "Vpsikyo__pch.h"

//============================================================
// Constructors

Vpsikyo::Vpsikyo(VerilatedContext* _vcontextp__, const char* _vcname__)
    : VerilatedModel{*_vcontextp__}
    , vlSymsp{new Vpsikyo__Syms(contextp(), _vcname__, this)}
    , clk{vlSymsp->TOP.clk}
    , rst_n{vlSymsp->TOP.rst_n}
    , cs_n{vlSymsp->TOP.cs_n}
    , rd_n{vlSymsp->TOP.rd_n}
    , wr_n{vlSymsp->TOP.wr_n}
    , dsn{vlSymsp->TOP.dsn}
    , vsync_n{vlSymsp->TOP.vsync_n}
    , nmi_n{vlSymsp->TOP.nmi_n}
    , irq1_n{vlSymsp->TOP.irq1_n}
    , irq2_n{vlSymsp->TOP.irq2_n}
    , irq3_n{vlSymsp->TOP.irq3_n}
    , spr_dma_enable{vlSymsp->TOP.spr_dma_enable}
    , spr_render_enable{vlSymsp->TOP.spr_render_enable}
    , spr_mode{vlSymsp->TOP.spr_mode}
    , spr_palette_bank{vlSymsp->TOP.spr_palette_bank}
    , spr_y_offset{vlSymsp->TOP.spr_y_offset}
    , display_list_count{vlSymsp->TOP.display_list_count}
    , display_list_ready{vlSymsp->TOP.display_list_ready}
    , bg_enable{vlSymsp->TOP.bg_enable}
    , bg_tile_size{vlSymsp->TOP.bg_tile_size}
    , bg_priority{vlSymsp->TOP.bg_priority}
    , color_key_ctrl{vlSymsp->TOP.color_key_ctrl}
    , color_key_color{vlSymsp->TOP.color_key_color}
    , color_key_mask{vlSymsp->TOP.color_key_mask}
    , z80_busy{vlSymsp->TOP.z80_busy}
    , z80_irq_pending{vlSymsp->TOP.z80_irq_pending}
    , z80_cmd_reply{vlSymsp->TOP.z80_cmd_reply}
    , sprite_ram_wsel{vlSymsp->TOP.sprite_ram_wsel}
    , sprite_ram_wr_en{vlSymsp->TOP.sprite_ram_wr_en}
    , din{vlSymsp->TOP.din}
    , dout{vlSymsp->TOP.dout}
    , spr_count{vlSymsp->TOP.spr_count}
    , vsync_irq_line{vlSymsp->TOP.vsync_irq_line}
    , hsync_irq_col{vlSymsp->TOP.hsync_irq_col}
    , sprite_ram_addr{vlSymsp->TOP.sprite_ram_addr}
    , sprite_ram_din{vlSymsp->TOP.sprite_ram_din}
    , addr{vlSymsp->TOP.addr}
    , spr_table_base{vlSymsp->TOP.spr_table_base}
    , sprite_ram_dout{vlSymsp->TOP.sprite_ram_dout}
    , priority_table{vlSymsp->TOP.priority_table}
    , display_list_x{vlSymsp->TOP.display_list_x}
    , display_list_y{vlSymsp->TOP.display_list_y}
    , display_list_tile{vlSymsp->TOP.display_list_tile}
    , display_list_palette{vlSymsp->TOP.display_list_palette}
    , display_list_flip_x{vlSymsp->TOP.display_list_flip_x}
    , display_list_flip_y{vlSymsp->TOP.display_list_flip_y}
    , display_list_priority{vlSymsp->TOP.display_list_priority}
    , display_list_size{vlSymsp->TOP.display_list_size}
    , display_list_valid{vlSymsp->TOP.display_list_valid}
    , bg_chr_bank{vlSymsp->TOP.bg_chr_bank}
    , bg_scroll_x{vlSymsp->TOP.bg_scroll_x}
    , bg_scroll_y{vlSymsp->TOP.bg_scroll_y}
    , bg_tilemap_base{vlSymsp->TOP.bg_tilemap_base}
    , __PVT__psikyo{vlSymsp->TOP.__PVT__psikyo}
    , rootp{&(vlSymsp->TOP)}
{
    // Register model with the context
    contextp()->addModel(this);
}

Vpsikyo::Vpsikyo(const char* _vcname__)
    : Vpsikyo(Verilated::threadContextp(), _vcname__)
{
}

//============================================================
// Destructor

Vpsikyo::~Vpsikyo() {
    delete vlSymsp;
}

//============================================================
// Evaluation function

#ifdef VL_DEBUG
void Vpsikyo___024root___eval_debug_assertions(Vpsikyo___024root* vlSelf);
#endif  // VL_DEBUG
void Vpsikyo___024root___eval_static(Vpsikyo___024root* vlSelf);
void Vpsikyo___024root___eval_initial(Vpsikyo___024root* vlSelf);
void Vpsikyo___024root___eval_settle(Vpsikyo___024root* vlSelf);
void Vpsikyo___024root___eval(Vpsikyo___024root* vlSelf);

void Vpsikyo::eval_step() {
    VL_DEBUG_IF(VL_DBG_MSGF("+++++TOP Evaluate Vpsikyo::eval_step\n"); );
#ifdef VL_DEBUG
    // Debug assertions
    Vpsikyo___024root___eval_debug_assertions(&(vlSymsp->TOP));
#endif  // VL_DEBUG
    vlSymsp->__Vm_deleter.deleteAll();
    if (VL_UNLIKELY(!vlSymsp->__Vm_didInit)) {
        VL_DEBUG_IF(VL_DBG_MSGF("+ Initial\n"););
        Vpsikyo___024root___eval_static(&(vlSymsp->TOP));
        Vpsikyo___024root___eval_initial(&(vlSymsp->TOP));
        Vpsikyo___024root___eval_settle(&(vlSymsp->TOP));
        vlSymsp->__Vm_didInit = true;
    }
    VL_DEBUG_IF(VL_DBG_MSGF("+ Eval\n"););
    Vpsikyo___024root___eval(&(vlSymsp->TOP));
    // Evaluate cleanup
    Verilated::endOfEval(vlSymsp->__Vm_evalMsgQp);
}

//============================================================
// Events and timing
bool Vpsikyo::eventsPending() { return false; }

uint64_t Vpsikyo::nextTimeSlot() {
    VL_FATAL_MT(__FILE__, __LINE__, "", "No delays in the design");
    return 0;
}

//============================================================
// Utilities

const char* Vpsikyo::name() const {
    return vlSymsp->name();
}

//============================================================
// Invoke final blocks

void Vpsikyo___024root___eval_final(Vpsikyo___024root* vlSelf);

VL_ATTR_COLD void Vpsikyo::final() {
    Vpsikyo___024root___eval_final(&(vlSymsp->TOP));
}

//============================================================
// Implementations of abstract methods from VerilatedModel

const char* Vpsikyo::hierName() const { return vlSymsp->name(); }
const char* Vpsikyo::modelName() const { return "Vpsikyo"; }
unsigned Vpsikyo::threads() const { return 1; }
void Vpsikyo::prepareClone() const { contextp()->prepareClone(); }
void Vpsikyo::atClone() const {
    contextp()->threadPoolpOnClone();
}
