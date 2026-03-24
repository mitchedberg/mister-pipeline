-- MAME RAM dump script for baddudes (DECO 16-bit)
-- Auto-generated from MAME dataeast/dec0.cpp
-- Usage: mame baddudes -autoboot_script dump_baddudes.lua -nothrottle -str 3000

local MAX_FRAMES = 3000
local DUMP_DIR = 'dumps/'

-- RAM regions to dump (from MAME memory map)
local REGIONS = {
    {name='work_ram', start=0xFF0000, size=0x10000},
}

local frame_count = 0

emu.register_frame_done(function()
    frame_count = frame_count + 1
    if frame_count > MAX_FRAMES then return end

    local mem = manager.machine.devices[':maincpu'].spaces['program']
    local fname = string.format(DUMP_DIR .. 'baddudes_%05d.bin', frame_count)
    local f = io.open(fname, 'wb')
    if not f then return end

    for _, region in ipairs(REGIONS) do
        for addr = region.start, region.start + region.size - 1 do
            f:write(string.char(mem:read_u8(addr)))
        end
    end
    f:close()
end)

print("Dump script loaded for baddudes — will dump " .. MAX_FRAMES .. " frames")