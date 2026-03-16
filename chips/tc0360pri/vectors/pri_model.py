"""
TC0360PRI behavioral model — Python reference implementation.
Matches tc0360pri.sv exactly.
"""


class TC0360PRI:
    def __init__(self):
        self.regs = [0] * 16

    def write(self, addr: int, data: int) -> None:
        self.regs[addr & 0xF] = data & 0xFF

    def read(self, addr: int) -> int:
        return self.regs[addr & 0xF]

    def _lookup_pri(self, sel: int, reg_lo: int, reg_hi: int) -> int:
        if sel == 0: return reg_lo & 0xF
        if sel == 1: return (reg_lo >> 4) & 0xF
        if sel == 2: return reg_hi & 0xF
        return (reg_hi >> 4) & 0xF

    def mix(self, color_in0: int, color_in1: int, color_in2: int) -> int:
        """
        Priority-resolve three 15-bit color inputs.
        Returns 13-bit palette index (0 = transparent/background).
        color_inN = {sel[1:0], palette_idx[12:0]}
        """
        inputs = [color_in0, color_in1, color_in2]
        reg_pairs = [(self.regs[4], self.regs[5]),
                     (self.regs[6], self.regs[7]),
                     (self.regs[8], self.regs[9])]

        best_pri   = 0
        best_color = 0

        # Process inputs 0..2 in order (lower index = tie-break winner)
        for i, (cin, (rlo, rhi)) in enumerate(zip(inputs, reg_pairs)):
            sel   = (cin >> 13) & 0x3
            pidx  = cin & 0x1FFF   # 13-bit palette index
            transparent = (pidx == 0)
            if transparent:
                continue
            pri = self._lookup_pri(sel, rlo, rhi)
            if pri == 0:
                continue
            # Strict greater-than to honor tie-break (first input wins ties)
            if pri > best_pri:
                best_pri   = pri
                best_color = pidx

        return best_color
