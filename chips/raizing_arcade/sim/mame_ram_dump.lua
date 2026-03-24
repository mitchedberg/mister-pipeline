-- mame_ram_dump.lua
-- Per-frame RAM dump for Battle Garegga (Raizing RA9503) validation.
-- Writes a binary file: for each frame, a 4-byte LE frame number followed by
-- the raw contents of each monitored memory region in order.
--
-- Run with: mame bgaregg -autoboot_script mame_ram_dump.lua -nothrottle -str 3000
--
-- Memory layout dumped each frame (~114 KB/frame):
--   Main RAM:        0x100000-0x10FFFF  (64 KB) — Battle Garegga work RAM
--   Palette RAM:     0x400000-0x400FFF  (4 KB)
--   Text VRAM:       0x500000-0x501FFF  (8 KB)
--   Text line sel:   0x502000-0x502FFF  (4 KB)
--   Text line scrl:  0x503000-0x5031FF  (512 B)
-- Total per frame: 65536 + 4096 + 8192 + 4096 + 512 = 82432 bytes + 4 header
--
-- NOTE: Previous incorrect addresses (0xFF0000 from auto-generation) are NOT used.
-- Battle Garegga WRAM is at 0x100000-0x10FFFF per raizing.cpp bgaregga_state.
-- See HARDWARE.md Section "Memory Map: Battle Garegga (bgaregga_state)" for details.

local MAX_FRAMES = 3000
local OUTPUT_FILE = "bgaregg_frames.bin"

-- Region definitions: { label, start, end_inclusive }
local REGIONS = {
    { "MainRAM",     0x100000, 0x10FFFF },  -- 64 KB
    { "Palette",     0x400000, 0x400FFF },  --  4 KB
    { "TextVRAM",    0x500000, 0x501FFF },  --  8 KB
    { "TextLineSel", 0x502000, 0x502FFF },  --  4 KB
    { "TextLineScr", 0x503000, 0x5031FF },  -- 512 B
}

local outfile = nil
local frame_count = 0
local space = nil
local frame_notifier = nil
local reset_notifier = nil
local stop_notifier = nil

-- Pack a 32-bit unsigned integer as 4 little-endian bytes.
local function pack_u32_le(n)
    local b0 = n % 256;        n = math.floor(n / 256)
    local b1 = n % 256;        n = math.floor(n / 256)
    local b2 = n % 256;        n = math.floor(n / 256)
    local b3 = n % 256
    return string.char(b0, b1, b2, b3)
end

local function open_output()
    outfile = io.open(OUTPUT_FILE, "wb")
    if not outfile then
        print("[mame_ram_dump] ERROR: cannot open " .. OUTPUT_FILE)
        return false
    end
    frame_count = 0
    print("[mame_ram_dump] Opened " .. OUTPUT_FILE .. " for writing (max " .. MAX_FRAMES .. " frames)")

    -- Resolve the address space once on reset so we don't look it up every frame.
    local cpu = manager.machine.devices[":maincpu"]
    if not cpu then
        print("[mame_ram_dump] ERROR: device :maincpu not found")
        outfile:close()
        outfile = nil
        return false
    end
    space = cpu.spaces["program"]
    if not space then
        print("[mame_ram_dump] ERROR: program space not found on :maincpu")
        outfile:close()
        outfile = nil
        return false
    end
    print("[mame_ram_dump] Resolved :maincpu program space OK")
    return true
end

local function close_output()
    if outfile then
        outfile:close()
        outfile = nil
        print("[mame_ram_dump] Closed output after " .. frame_count .. " frames")
    end
end

local function on_frame()
    if not outfile then return end
    if frame_count >= MAX_FRAMES then
        if frame_count == MAX_FRAMES then
            print("[mame_ram_dump] Reached MAX_FRAMES (" .. MAX_FRAMES .. "), stopping dump")
            close_output()
            frame_count = frame_count + 1  -- prevent repeated prints
        end
        return
    end

    -- Write 4-byte little-endian frame number.
    outfile:write(pack_u32_le(frame_count))

    -- Write each region as a raw binary blob.
    local any_nil = false
    for _, region in ipairs(REGIONS) do
        local data = space:read_range(region[2], region[3], 8)
        if data then
            outfile:write(data)
        else
            -- Fallback: write zeros for the region so frame offsets stay consistent.
            local region_len = region[3] - region[2] + 1
            outfile:write(string.rep("\0", region_len))
            if not any_nil then
                print("[mame_ram_dump] WARNING: read_range returned nil for " .. region[1]
                      .. " on frame " .. frame_count)
                any_nil = true
            end
        end
    end

    frame_count = frame_count + 1

    if frame_count == 1 then
        print("[mame_ram_dump] First frame dumped OK")
    end
    if frame_count % 100 == 0 then
        print("[mame_ram_dump] Dumped " .. frame_count .. " frames")
        outfile:flush()
    end
end

-- Register notifiers.
-- NOTE: In MAME 0.280+, autoboot scripts run AFTER the machine is already
-- running. The reset notifier may never fire for the initial boot.
-- Open output immediately on script load as a fallback.
reset_notifier = emu.add_machine_reset_notifier(function()
    print("[mame_ram_dump] Machine reset — reopening output file")
    close_output()
    open_output()
end)

stop_notifier = emu.add_machine_stop_notifier(function()
    print("[mame_ram_dump] Machine stop — closing output file")
    close_output()
end)

-- MAME 0.257 uses emu.register_frame_done for per-frame callbacks.
-- Older MAME uses emu.add_machine_frame_notifier.
if emu.register_frame_done then
    emu.register_frame_done(on_frame)
    print("[mame_ram_dump] Registered per-frame callback (emu.register_frame_done)")
elseif emu.add_machine_frame_notifier then
    frame_notifier = emu.add_machine_frame_notifier(function() on_frame() end)
    print("[mame_ram_dump] Registered per-frame callback (emu.add_machine_frame_notifier)")
else
    print("[mame_ram_dump] ERROR: No per-frame callback API available")
end

-- Open output immediately (machine is already running when script loads).
print("[mame_ram_dump] Script loaded — opening output immediately.")
open_output()
print("[mame_ram_dump] Output: " .. OUTPUT_FILE)
print("[mame_ram_dump] Max frames: " .. MAX_FRAMES)
print("[mame_ram_dump] Bytes per frame: " .. (4 + 65536 + 4096 + 8192 + 4096 + 512) .. " (~82.4 KB)")
