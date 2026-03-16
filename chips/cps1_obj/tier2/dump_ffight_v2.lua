-- =============================================================================
-- dump_ffight_v2.lua  —  CPS1 Final Fight OBJ RAM dumper (corrected)
-- =============================================================================
-- OBJ_BASE = 0x9000 for ffight → OBJ RAM at CPU 0x900000 (start of GFX RAM)
-- SCROLL1 tile maps also start at 0x900000 but occupy different sub-ranges.
-- OBJ RAM is 0x800 bytes = 0x900000-0x9007FF.
--
-- Strategy:
--  1. Intercept OBJ_BASE writes to track actual OBJ RAM location
--  2. Watch for OBJ RAM writes to detect active sprite frames
--  3. When we see active sprite data (non-zero entries), capture and exit
-- =============================================================================

local obj_base_addr  = 0x900000   -- default assumption
local obj_ram_writes = 0
local sprite_frame   = nil
local frame          = 0
local done           = false

local OUTPUT_DIR = "/Volumes/2TB_20260220/Projects/MiSTer_Pipeline/chips/cps1_obj/tier2/"

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]

-- ---------------------------------------------------------------------------
-- JSON encoder
-- ---------------------------------------------------------------------------
local function json_val(v)
    local t = type(v)
    if t == "nil"     then return "null"
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "number"  then return string.format("%d", math.floor(v + 0.5))
    elseif t == "string"  then return '"' .. v:gsub('\\','\\\\'):gsub('"','\\"') .. '"'
    elseif t == "table" then
        local n = #v
        if n > 0 then
            local parts = {}
            for i = 1, n do parts[i] = json_val(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, val in pairs(v) do
                parts[#parts+1] = json_val(tostring(k)) .. ":" .. json_val(val)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

-- ---------------------------------------------------------------------------
-- Track OBJ_BASE register writes to find actual OBJ RAM address
-- ---------------------------------------------------------------------------
local tap_cpsa = mem:install_write_tap(0x800100, 0x800101, "objbase_watch",
    function(offset, data, mask)
        local new_addr = (data & 0xFFFF) * 0x100
        if new_addr ~= obj_base_addr then
            obj_base_addr = new_addr
            print(string.format("[f%d] OBJ_BASE=0x%04X → OBJ RAM at 0x%06X",
                frame, data & 0xFFFF, obj_base_addr))
        end
    end
)

-- ---------------------------------------------------------------------------
-- Count non-zero, non-transparent sprites in OBJ RAM
-- ---------------------------------------------------------------------------
local function count_sprites()
    local count = 0
    for i = 0, 255 do
        local base = obj_base_addr + i * 8
        local code = mem:read_u16(base + 4)
        local attr  = mem:read_u16(base + 6)
        if (attr & 0xFF00) == 0xFF00 then break end
        if code ~= 0 then count = count + 1 end
    end
    return count
end

-- ---------------------------------------------------------------------------
-- Full OBJ RAM dump + GFX data capture
-- ---------------------------------------------------------------------------
local function do_capture()
    print(string.format("[f%d] === Capturing OBJ RAM at 0x%06X ===", frame, obj_base_addr))

    -- 1. Read flip_screen from VIDEOCONTROL
    local vc    = mem:read_u16(0x800122)
    local flip  = (vc & 0x8000) ~= 0

    -- 2. Read 1024 words of OBJ RAM
    local obj_ram = {}
    for i = 0, 1023 do
        obj_ram[i+1] = mem:read_u16(obj_base_addr + i * 2)
    end

    -- 3. Count and print sprites
    local sprite_count = 0
    print("Sprites found:")
    for i = 0, 255 do
        local x    = obj_ram[i*4+1]
        local y    = obj_ram[i*4+2]
        local code = obj_ram[i*4+3]
        local attr  = obj_ram[i*4+4]
        if (attr & 0xFF00) == 0xFF00 then
            print(string.format("  [%d] TERMINATOR", i))
            break
        end
        if code ~= 0 then
            local nx = (attr >> 8) & 0xF
            local ny = (attr >> 12) & 0xF
            print(string.format("  [%d] x=%d y=%d code=0x%04X attr=0x%04X nx=%d ny=%d",
                i, x & 0x1FF, y & 0x1FF, code, attr, nx, ny))
        end
        sprite_count = i + 1
    end

    -- 4. Collect unique tile codes
    local used_codes = {}
    for i = 0, sprite_count - 1 do
        local code = obj_ram[i*4+3]
        local attr  = obj_ram[i*4+4]
        local nx   = (attr >> 8) & 0xF
        local ny   = (attr >> 12) & 0xF
        local base_nib = code & 0xF
        for row = 0, ny do
            for col = 0, nx do
                local col_nib = (base_nib + col) & 0xF
                local tile_code = (code & 0xFFF0) + row * 0x10 + col_nib
                used_codes[tile_code] = true
            end
        end
    end

    local code_list = {}
    for c, _ in pairs(used_codes) do code_list[#code_list+1] = c end
    table.sort(code_list)
    print(string.format("%d unique tile codes", #code_list))

    -- 5. Read GFX region data for used codes
    local gfxreg = manager.machine.memory.regions[":gfx"]
    local gfx_data = nil

    if gfxreg then
        gfx_data = {}
        local ok_count = 0
        local ff_count = 0

        for _, code in ipairs(code_list) do
            local base_off = code * 128
            local tile = {}
            local all_ff = true
            for vsub = 0, 15 do
                local row = {}
                local row_off = base_off + vsub * 8
                -- Read 8 bytes (16 pixels packed as nibbles, 2 per byte)
                for b = 0, 7 do
                    local byte_val = gfxreg:read_u8(row_off + b)
                    if byte_val ~= 0xFF then all_ff = false end
                    -- low nibble = even pixel, high nibble = odd pixel
                    row[b*2+1] = byte_val & 0xF         -- pixel 2b
                    row[b*2+2] = (byte_val >> 4) & 0xF  -- pixel 2b+1
                end
                tile[vsub+1] = row
            end
            gfx_data[tostring(code)] = tile
            if all_ff then ff_count = ff_count + 1 else ok_count = ok_count + 1 end
        end
        print(string.format("GFX data: %d tiles with real data, %d all-transparent",
            ok_count, ff_count))
    end

    -- 6. Save files
    local obj_out = {
        frame        = frame,
        obj_base_reg = obj_base_addr / 0x100,
        obj_base_addr= obj_base_addr,
        flip_screen  = flip,
        sprite_count = sprite_count,
        obj_ram      = obj_ram,
    }

    local obj_path = OUTPUT_DIR .. string.format("v2_frame%05d_obj_ram.json", frame)
    local f1 = io.open(obj_path, "w")
    if f1 then
        f1:write(json_val(obj_out))
        f1:close()
        print("Saved: " .. obj_path)
    end

    if gfx_data then
        local gfx_path = OUTPUT_DIR .. string.format("v2_frame%05d_gfx.json", frame)
        local f2 = io.open(gfx_path, "w")
        if f2 then
            f2:write(json_val(gfx_data))
            f2:close()
            print("Saved: " .. gfx_path)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Frame hook
-- ---------------------------------------------------------------------------
emu.register_frame_done(function()
    frame = frame + 1
    if done then return end

    if frame % 500 == 0 then
        local sc = count_sprites()
        print(string.format("[f%d] OBJ RAM at 0x%06X: %d sprites with code≠0",
            frame, obj_base_addr, sc))
    end

    -- Check every 10 frames after frame 500
    if frame >= 500 and (frame % 10) == 0 then
        local sc = count_sprites()
        if sc > 0 then
            done = true
            print(string.format("[f%d] SPRITES! %d entries with code≠0", frame, sc))
            do_capture()
            manager.machine:exit()
            return
        end
    end

    -- Safety exit at frame 8000 regardless
    if frame >= 8000 then
        done = true
        print(string.format("[f%d] Timeout — capturing whatever is there", frame))
        do_capture()
        manager.machine:exit()
    end
end)

print("[DUMP_V2] OBJ RAM monitor started. OBJ base starts at 0x900000.")
print("[DUMP_V2] Will capture when sprites appear or at frame 8000.")
