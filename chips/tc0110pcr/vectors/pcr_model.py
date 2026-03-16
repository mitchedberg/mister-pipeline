"""
TC0110PCR behavioral model — Python reference implementation.

Matches tc0110pcr.sv exactly:
  - 4096 × 16-bit palette RAM
  - 2-register CPU interface (A0=0 addr latch, A0=1 data)
  - Address latch: step_mode=0: addr = cpu_din[12:1]
                   step_mode=1: addr = cpu_din[11:0]
  - Color format: bits[14:10]=B, bits[9:5]=G, bits[4:0]=R, bit[15]=stored/unused

Note: CPU read and video lookup both have registered (1-cycle) pipeline stages,
but this model returns the combinational data for golden vector generation.
The testbench accounts for RTL pipeline latency separately.
"""


class TC0110PCR:
    def __init__(self, step_mode: int = 0):
        self.step_mode = step_mode
        self.pal_ram = [0] * 4096   # 4096 × 16-bit entries
        self.addr_reg = 0

    def write_addr(self, cpu_din: int) -> None:
        """A0=0 write: latch palette address from cpu_din."""
        if self.step_mode == 0:
            self.addr_reg = (cpu_din >> 1) & 0xFFF   # standard: cpu_din[12:1]
        else:
            self.addr_reg = cpu_din & 0xFFF           # step-1: cpu_din[11:0]

    def write_data(self, cpu_din: int) -> None:
        """A0=1 write: store palette entry at current addr_reg."""
        self.pal_ram[self.addr_reg] = cpu_din & 0xFFFF

    def read_cpu(self) -> int:
        """CPU readback: returns full 16-bit entry at addr_reg."""
        return self.pal_ram[self.addr_reg]

    def color_lookup(self, pxl_in: int) -> tuple:
        """Video lookup: returns (r5, g5, b5) for given 12-bit palette index."""
        pxl_in = pxl_in & 0xFFF
        entry = self.pal_ram[pxl_in]
        r = entry & 0x1F
        g = (entry >> 5) & 0x1F
        b = (entry >> 10) & 0x1F
        return (r, g, b)

    @staticmethod
    def decode_color(data: int) -> tuple:
        """Decode a 16-bit palette word into (r5, g5, b5)."""
        r = data & 0x1F
        g = (data >> 5) & 0x1F
        b = (data >> 10) & 0x1F
        return (r, g, b)
