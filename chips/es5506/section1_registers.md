# ES5506 — Section 1: Register Map

**Source:** MAME `src/devices/sound/es5506.cpp` / `es5506.h`

---

## CPU Interface

- 8-bit data bus, 8-bit address bus
- In Taito F3: accessed through TC0400YSC sound communication chip (Z80 side)
- Page register selects which voice's registers are visible

---

## Voice Registers (32 voices, selected by page register)

Each voice has the following registers (accessed via page select + register address):

| Reg | Name | Width | Description |
|-----|------|-------|-------------|
| 0 | CR | 16 | Control: loop mode [1:0], IRQ enable [2], dir [3], stop [4], lpe [5], ble [6], irqe [7] |
| 1 | START | 32 | Sample start address (integer + fractional) |
| 2 | END | 32 | Sample end/loop address |
| 3 | ACCUM | 32 | Address accumulator (current playback position) |
| 4 | O4(n-1) | 16 | Filter history pole 4 |
| 5 | O3(n-1) | 16 | Filter history pole 3 |
| 6 | O2(n-1) | 16 | Filter history pole 2 |
| 7 | O1(n-1) | 16 | Filter history pole 1 |
| 8 | W_ST | 16 | Wavetable start bank (high bits of sample ROM address) |
| 9 | W_END | 16 | Wavetable end bank |
| A | LVR | 16 | Left volume [15:8] + ramp [7:0] |
| B | RVR | 16 | Right volume [15:8] + ramp [7:0] |
| C | K2 | 16 | Filter coefficient 2 (highpass cutoff) |
| D | K1 | 16 | Filter coefficient 1 (lowpass cutoff) |
| E | (reserved) | | |
| F | (page/IRQ) | | Host page register + IRQ vector |

---

## Control Register (CR) Bit Fields

```
Bit 0-1: LOOP mode
  00 = no loop (stop at END)
  01 = loop forward
  10 = loop bidirectional
  11 = loop backward
Bit 2: IRQ enable (fire IRQ when loop/end reached)
Bit 3: Direction (0=forward, 1=reverse)
Bit 4: STOP (1 = voice stopped)
Bit 5: LPE (loop enable)
Bit 6: BLE (bidirectional loop enable)
Bit 7: IRQE (IRQ enable — duplicate of bit 2 in some variants)
Bit 8: CA (channel assign — ES5506 specific)
Bit 14-15: Filter mode (ES5506)
  00 = HP/LP (highpass pole 1, lowpass poles 2-4)
  01 = LP/LP (lowpass all 4 poles)
  10 = LP/HP
  11 = HP/HP
```

---

## Sample Format

**16-bit linear PCM:**
- Signed 16-bit samples in ROM
- Address accumulator is 32-bit fixed-point (upper bits = integer address, lower = fractional for interpolation)

**8-bit u-law compressed:**
- 8-bit encoded samples, decoded via 256-entry u-law lookup table
- Decode: exponent = rawval >> 13; mantissa computation per CCITT u-law standard

---

## Filter (4-pole per voice)

```
K1 = lowpass cutoff coefficient  (16-bit, Q1.15 fixed-point)
K2 = highpass cutoff coefficient (16-bit, Q1.15 fixed-point)

Pole update per sample:
  o1 = lowpass(K1, input, o1_prev)       // pole 1: always lowpass
  o2 = lowpass/highpass(K2, o1, o2_prev) // pole 2: mode-dependent
  o3 = lowpass/highpass(K2, o2, o3_prev) // pole 3
  o4 = lowpass/highpass(K2, o3, o4_prev) // pole 4

Lowpass:  out = ((K1 >> FILTER_SHIFT) * (prev_out - in)) / (1<<FILTER_BIT) + in
Highpass: out = prev_out - prev_in + ((K2 >> FILTER_SHIFT) * in) / (1<<(FILTER_BIT+1)) + in/2
```

---

## Clock and Sample Rate

```
Input clock: 16 MHz (Taito F3)
Divide by 16 for voice update clock: 1 MHz
32 voices time-multiplexed → output rate: 1MHz / 32 = ~31.25 KHz
```

---

## IRQ

- Each voice can fire an IRQ when its accumulator reaches END (or loop point)
- IRQ vector register stores which voice triggered
- In Taito F3: routed through TC0400YSC to Z80 sound CPU
