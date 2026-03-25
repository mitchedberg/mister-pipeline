-- MAME RAM dump script for Batsugun (Toaplan V2)
-- Auto-generated from MAME toaplan/toaplan2.cpp
-- Usage: mame batsugun -autoboot_script dump_batsugun.lua -nothrottle -str 3000
--
-- Address verified against MAME source: toaplan/toaplan2.cpp
-- batsugun_map: AM_RANGE(0x100000, 0x10ffff) AM_RAM = 64KB work_ram at 0x100000
-- See also: toaplan_v2.sv WRAM_BASE = 23'h080000 (byte 0x100000)
-- Reference: dumps for bgaregga (also Toaplan V2, same WRAM layout)

local MAX_FRAMES = 3000
local DUMP_DIR = 'dumps/'

-- RAM regions to dump (from MAME memory map)
-- batsugun work_ram: 0x100000-0x10FFFF (64KB)
local REGIONS = {
    {name='work_ram', start=0x100000, size=0x10000},
}

local frame_count = 0

emu.register_frame_done(function()
    frame_count = frame_count + 1
    if frame_count > MAX_FRAMES then return end

    local mem = manager.machine.devices[':maincpu'].spaces['program']
    local fname = string.format(DUMP_DIR .. 'frame_%05d.bin', frame_count)
    local f = io.open(fname, 'wb')
    if not f then return end

    for _, region in ipairs(REGIONS) do
        for addr = region.start, region.start + region.size - 1 do
            f:write(string.char(mem:read_u8(addr)))
        end
    end
    f:close()
end)

print("Dump script loaded for batsugun — will dump " .. MAX_FRAMES .. " frames to " .. DUMP_DIR .. " (WRAM 0x100000-0x10FFFF)")
