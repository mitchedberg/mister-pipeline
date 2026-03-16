`default_nettype none
module fail_latch (
    input  logic       clk,
    input  logic [1:0] sel,
    output logic [7:0] out
);
// INTENTIONALLY BROKEN: case without default infers latch
// Gate 2.5 must catch this (-Wall LATCH warning)
always_comb begin
    case (sel)
        2'b00: out = 8'hAA;
        2'b01: out = 8'hBB;
        2'b10: out = 8'hCC;
        // missing 2'b11 case — infers latch on 'out'
    endcase
end
endmodule
