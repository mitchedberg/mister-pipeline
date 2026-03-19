-- mame_ram_dump.lua
-- Per-frame RAM dump for Thunder Dragon (tdragon) validation.
-- Writes a binary file: for each frame, a 4-byte LE frame number followed by
-- the raw contents of each monitored memory region in order.
--
-- Run with: mame tdragon -autoboot_script mame_ram_dump.lua
--
-- Memory layout dumped each frame (~84 KB/frame):
--   Main RAM:    0x080000-0x08FFFF  (64 KB)
--   Palette:     0x0C8000-0x0C87FF  (2 KB)
--   BG VRAM:     0x0CC000-0x0CFFFF  (16 KB)
--   TX VRAM:     0x0D0000-0x0D07FF  (2 KB)
--   Scroll regs: 0x0C4000-0x0C4007  (8 bytes)
-- Total per frame: 65536 + 2048 + 16384 + 2048 + 8 = 86024 bytes + 4 header

local MAX_FRAMES = 2000
local OUTPUT_FILE = "tdragon_frames.bin"

-- Region definitions: { label, start, end_inclusive }
local REGIONS = {
    { "MainRAM",    0x080000, 0x08FFFF },  -- 64 KB
    { "Palette",    0x0C8000, 0x0C87FF },  --  2 KB
    { "BGVRAM",     0x0CC000, 0x0CFFFF },  -- 16 KB
    { "TXVRAM",     0x0D0000, 0x0D07FF },  --  2 KB
    { "ScrollRegs", 0x0C4000, 0x0C4007 },  --  8 bytes
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

frame_notifier = emu.add_machine_frame_notifier(function()
    on_frame()
end)

-- Open output immediately (machine is already running when script loads).
print("[mame_ram_dump] Script loaded — opening output immediately.")
open_output()
print("[mame_ram_dump] Output: " .. OUTPUT_FILE)
print("[mame_ram_dump] Max frames: " .. MAX_FRAMES)
print("[mame_ram_dump] Bytes per frame: " .. (4 + 65536 + 2048 + 16384 + 2048 + 8) .. " (~84 KB)")
