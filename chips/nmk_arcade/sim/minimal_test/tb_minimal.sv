// tb_minimal.sv — Minimal fx68k wrapper for isolated CPU testing
// No SDRAM, no NMK arcade, no complex bus logic.
// The C++ testbench drives all signals externally.

module tb_minimal(
    input  logic        clk,
    input  logic        reset,
    input  logic        enPhi1,
    input  logic        enPhi2,
    input  logic [15:0] iEdb,
    input  logic        DTACKn,
    input  logic        VPAn,
    output logic [23:1] eab,
    output logic [15:0] oEdb,
    output logic        eRWn,
    output logic        ASn,
    output logic        LDSn,
    output logic        UDSn,
    output logic        oHALTEDn,
    output logic        FC0, FC1, FC2
);

fx68k u_cpu(
    .clk(clk),
    .HALTn(1'b1),
    .extReset(reset),
    .pwrUp(reset),
    .enPhi1(enPhi1),
    .enPhi2(enPhi2),
    .eRWn(eRWn),
    .ASn(ASn),
    .LDSn(LDSn),
    .UDSn(UDSn),
    .E(),
    .VMAn(),
    .FC0(FC0),
    .FC1(FC1),
    .FC2(FC2),
    .BGn(),
    .oRESETn(),
    .oHALTEDn(oHALTEDn),
    .DTACKn(DTACKn),
    .VPAn(VPAn),
    .BERRn(1'b1),
    .BRn(1'b1),
    .BGACKn(1'b1),
    .IPL0n(1'b1),
    .IPL1n(1'b1),
    .IPL2n(1'b1),
    .iEdb(iEdb),
    .oEdb(oEdb),
    .eab(eab)
);

endmodule
