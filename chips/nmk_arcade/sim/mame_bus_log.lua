-- mame_bus_log.lua
-- Bus transaction logger for Thunder Dragon (tdragon) validation.
-- Installs read/write taps on all non-ROM memory regions and logs every
-- access as a tab-separated line to tdragon_bus.log.
--
-- Run with: mame tdragon -autoboot_script mame_bus_log.lua
--
-- Logged regions (ROM at 0x000000-0x03FFFF is intentionally skipped):
--   Main RAM:    0x080000-0x08FFFF  (64 KB)
--   Palette:     0x0C8000-0x0C87FF  (2 KB)
--   BG VRAM:     0x0CC000-0x0CFFFF  (16 KB)
--   TX VRAM:     0x0D0000-0x0D07FF  (2 KB)
--   Scroll regs: 0x0C4000-0x0C4007  (8 bytes)
--
-- Log columns (tab-separated):
--   frame  cycle  R/W  width  address(hex)  data(hex)  mask(hex)
--
-- Width encoding:
--   W  = 16-bit word access (native M68000 width)
--   BH = byte access, upper byte (odd address or mask)
--   BL = byte access, lower byte (even address or mask)

local MAX_LINES = 5000000
local OUTPUT_FILE = "tdragon_bus.log"
local CPU_HZ = 12000000  -- 12 MHz M68000

-- Non-ROM regions to tap (ROM 0x000000-0x03FFFF is skipped).
local TAP_REGIONS = {
    { "MainRAM",    0x080000, 0x08FFFF },
    { "Palette",    0x0C8000, 0x0C87FF },
    { "BGVRAM",     0x0CC000, 0x0CFFFF },
    { "TXVRAM",     0x0D0000, 0x0D07FF },
    { "ScrollRegs", 0x0C4000, 0x0C4007 },
}

local outfile = nil
local line_count = 0
local current_frame = 0
local taps = {}           -- keep references so they aren't GC'd
local frame_notifier = nil
local reset_notifier = nil
local stop_notifier = nil
local space = nil

-- Determine width string from a 16-bit mask.
-- M68000 byte-enables: 0xFF00 = upper byte, 0x00FF = lower byte, 0xFFFF = word.
local function width_str(mask)
    if mask == nil or mask == 0xFFFF then
        return "W"
    elseif mask == 0xFF00 then
        return "BH"
    elseif mask == 0x00FF then
        return "BL"
    else
        return string.format("M%04X", mask)
    end
end

local function current_cycle()
    -- manager.machine.time returns an attotime; as_ticks converts to ticks at the given rate.
    return manager.machine.time:as_ticks(CPU_HZ)
end

local function log_access(rw, mask, addr, data)
    if not outfile then return end
    if line_count >= MAX_LINES then
        if line_count == MAX_LINES then
            print("[mame_bus_log] Reached MAX_LINES (" .. MAX_LINES .. "), stopping log")
            outfile:close()
            outfile = nil
            line_count = line_count + 1
        end
        return
    end

    local cycle = current_cycle()
    local w = width_str(mask)
    outfile:write(string.format("%d\t%d\t%s\t%s\t%06X\t%04X\t%04X\n",
        current_frame, cycle, rw, w,
        addr, data or 0, mask or 0xFFFF))
    line_count = line_count + 1

    if line_count % 100000 == 0 then
        print("[mame_bus_log] " .. line_count .. " lines written (frame " .. current_frame .. ")")
        outfile:flush()
    end
end

local function install_taps()
    -- Remove any old taps first.
    for _, tap in ipairs(taps) do
        tap:remove()
    end
    taps = {}

    if not space then
        print("[mame_bus_log] ERROR: address space not resolved, cannot install taps")
        return
    end

    for _, region in ipairs(TAP_REGIONS) do
        local label = region[1]
        local rstart = region[2]
        local rend   = region[3]

        -- Read tap.
        local rtap = space:install_read_tap(rstart, rend, "log_r_" .. label,
            function(addr, data, mask)
                log_access("R", mask, addr, data)
                return data  -- pass through unchanged
            end)
        if rtap then
            table.insert(taps, rtap)
        else
            print("[mame_bus_log] WARNING: failed to install read tap on " .. label)
        end

        -- Write tap.
        local wtap = space:install_write_tap(rstart, rend, "log_w_" .. label,
            function(addr, data, mask)
                log_access("W", mask, addr, data)
                -- Write taps are not expected to return a value.
            end)
        if wtap then
            table.insert(taps, wtap)
        else
            print("[mame_bus_log] WARNING: failed to install write tap on " .. label)
        end

        print(string.format("[mame_bus_log] Tapped %-12s 0x%06X-0x%06X", label, rstart, rend))
    end

    print("[mame_bus_log] " .. #taps .. " taps installed")
end

local function open_output()
    outfile = io.open(OUTPUT_FILE, "w")
    if not outfile then
        print("[mame_bus_log] ERROR: cannot open " .. OUTPUT_FILE)
        return false
    end
    line_count = 0
    current_frame = 0

    -- Write header.
    outfile:write("frame\tcycle\tRW\twidth\taddress\tdata\tmask\n")

    -- Resolve address space.
    local cpu = manager.machine.devices[":maincpu"]
    if not cpu then
        print("[mame_bus_log] ERROR: device :maincpu not found")
        outfile:close()
        outfile = nil
        return false
    end
    space = cpu.spaces["program"]
    if not space then
        print("[mame_bus_log] ERROR: program space not found on :maincpu")
        outfile:close()
        outfile = nil
        return false
    end

    print("[mame_bus_log] Opened " .. OUTPUT_FILE .. " (max " .. MAX_LINES .. " lines)")
    install_taps()
    return true
end

local function close_output()
    -- Remove taps first so no more callbacks fire after close.
    for _, tap in ipairs(taps) do
        tap:remove()
    end
    taps = {}

    if outfile then
        outfile:flush()
        outfile:close()
        outfile = nil
        print("[mame_bus_log] Closed output after " .. line_count .. " lines")
    end
end

-- Count frames so log lines include the current frame number.
frame_notifier = emu.add_machine_frame_notifier(function()
    current_frame = current_frame + 1
end)

reset_notifier = emu.add_machine_reset_notifier(function()
    print("[mame_bus_log] Machine reset — opening log and installing taps")
    open_output()
    current_frame = 0
end)

stop_notifier = emu.add_machine_stop_notifier(function()
    print("[mame_bus_log] Machine stop — closing log")
    close_output()
end)

print("[mame_bus_log] Script loaded. Waiting for machine reset.")
print("[mame_bus_log] Output: " .. OUTPUT_FILE)
print("[mame_bus_log] MAX_LINES: " .. MAX_LINES)
print("[mame_bus_log] CPU clock assumed: " .. CPU_HZ .. " Hz (12 MHz)")
print("[mame_bus_log] ROM (0x000000-0x03FFFF) is intentionally not tapped.")
