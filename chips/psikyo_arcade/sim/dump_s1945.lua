-- MAME RAM dump script for S1945 (Psikyo)
-- Usage: mame s1945 -rompath /path/to/roms -autoboot_script dump_s1945.lua -nothrottle -str 2500
--
-- Address verified: psikyo.cpp work_ram at 0xFE0000-0xFEFFFF (64KB)
-- See also: psikyo_arcade.sv WRAM_BASE = 23'h7F0000 (byte 0xFE0000)

local MAX_FRAMES = 2000
local DUMP_DIR   = os.getenv("MAME_DUMP_DIR") or "."
local frame_count = 0

emu.register_frame_done(function()
    frame_count = frame_count + 1
    if frame_count > MAX_FRAMES then
        manager.machine:exit()
        return
    end

    local mem = manager.machine.devices[':maincpu'].spaces['program']
    local fname = string.format("%s/frame_%05d.bin", DUMP_DIR, frame_count)
    local f = io.open(fname, 'wb')
    if not f then
        print("[s1945_dump] ERROR: cannot open " .. fname)
        return
    end

    -- WRAM lower 64KB: 0xFE0000-0xFEFFFF
    for addr = 0xFE0000, 0xFEFFFF do
        f:write(string.char(mem:read_u8(addr)))
    end
    f:close()

    if frame_count % 200 == 0 then
        print(string.format("[s1945_dump] frame %d / %d", frame_count, MAX_FRAMES))
    end
end)

print(string.format("[s1945_dump] Loaded — will dump %d frames to %s (WRAM 0xFE0000-0xFEFFFF)", MAX_FRAMES, DUMP_DIR))
