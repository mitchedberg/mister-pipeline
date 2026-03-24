-- MAME RAM dump script for bgaregga (Raizing/Toaplan)
-- Auto-generated from MAME toaplan/raizing.cpp
-- Usage: mame bgaregga -autoboot_script dump_bgaregga.lua -nothrottle -str 5000
--
-- Address verified against MAME source: toaplan/raizing.cpp
-- bgaregga_map: AM_RANGE(0x100000, 0x10ffff) AM_RAM = 64KB work_ram at 0x100000
-- See also: raizing_arcade.sv WRAM_BASE = 24'h100000
-- DO NOT use 0xFF0000 — that is the Toaplan V2 (toaplan2.cpp) address, not Raizing.
-- Fixed: TASK-GD-002, 2026-03-23 (was 0xFF0000, caused all-zeros dumps)

local MAX_FRAMES = 5000
local DUMP_DIR = 'dumps/'

-- RAM regions to dump (from MAME memory map)
-- bgaregga work_ram: 0x100000-0x10FFFF (64KB)
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

print("Dump script loaded for bgaregga — will dump " .. MAX_FRAMES .. " frames to " .. DUMP_DIR .. " (WRAM 0x100000-0x10FFFF)")
