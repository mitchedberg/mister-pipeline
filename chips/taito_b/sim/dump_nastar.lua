-- MAME RAM dump script for Nastar (Taito B)
-- Usage: mame nastar -rompath <path> -autoboot_script dump_nastar.lua -nothrottle -str 3000
--
-- Address: taito_b nastar work_ram at 0x600000-0x607FFF (32KB)
-- See also: taito_b.sv WRAM_BASE = 23'h300000 (word), byte 0x600000

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
        print("[nastar_dump] ERROR: cannot open " .. fname)
        return
    end

    -- WRAM: 0x600000-0x607FFF (32KB)
    for addr = 0x600000, 0x607FFF do
        f:write(string.char(mem:read_u8(addr)))
    end
    f:close()

    if frame_count % 200 == 0 then
        print(string.format("[nastar_dump] frame %d / %d", frame_count, MAX_FRAMES))
    end
end)

print(string.format("[nastar_dump] Loaded — will dump %d frames to %s (WRAM 0x600000-0x607FFF)", MAX_FRAMES, DUMP_DIR))
