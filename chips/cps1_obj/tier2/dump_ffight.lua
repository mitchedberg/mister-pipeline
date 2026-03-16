-- =============================================================================
-- dump_ffight.lua  —  CPS1 Final Fight OBJ RAM + GFX tile dumper
-- =============================================================================
-- Usage:
--   mame ffight -rompath /path/to/roms -nothrottle \
--     -autoboot_script /path/to/dump_ffight.lua -autoboot_delay 0
--
-- Outputs (in OUTPUT_DIR):
--   frame<N>_obj_ram.json   -- OBJ RAM (1024 words), flip_screen, sprite_count
--   frame<N>_gfx.json       -- decoded tile pixel data for all codes in OBJ table
--
-- The GFX JSON format:
--   { "<code_dec>": [[vsub0_px0..px15], [vsub1_px0..px15], ...] }
-- Each vsub array has 16 nibbles (0-15), 0xF = transparent.
-- =============================================================================

local TARGET_FRAME = 200   -- Frame to capture. Final Fight title appears ~120 frames.
local OUTPUT_DIR   = "/Volumes/2TB_20260220/Projects/MiSTer_Pipeline/chips/cps1_obj/tier2/"

local frame_num    = 0
local done         = false

-- ---------------------------------------------------------------------------
-- Minimal JSON encoder
-- ---------------------------------------------------------------------------
local function json_val(v)
    local t = type(v)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        return string.format("%d", math.floor(v + 0.5))
    elseif t == "string" then
        return '"' .. v:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n') .. '"'
    elseif t == "table" then
        -- Detect integer-keyed array
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

local function write_file(path, content)
    local f = io.open(path, "w")
    if not f then
        print("[DUMP] ERROR: cannot write " .. path)
        return false
    end
    f:write(content)
    f:close()
    print("[DUMP] Written: " .. path)
    return true
end

-- ---------------------------------------------------------------------------
-- Dump OBJ RAM from CPU address space
-- ---------------------------------------------------------------------------
local function dump_obj_ram(mem)
    -- Read OBJ_BASE register: CPS-A base is 0x800100, offset 0x00 = OBJ_BASE
    local obj_base_reg  = mem:read_u16(0x800100)
    local obj_base_addr = obj_base_reg * 0x100  -- byte address in CPU space
    print(string.format("[DUMP] OBJ_BASE reg=0x%04X → CPU addr=0x%06X",
                        obj_base_reg, obj_base_addr))

    -- Read VIDEOCONTROL register: CPS-A offset 0x22 = 0x800100 + 0x22 = 0x800122
    local videoctl  = mem:read_u16(0x800122)
    local flip      = (videoctl & 0x8000) ~= 0
    print(string.format("[DUMP] VIDEOCONTROL=0x%04X, flip_screen=%s",
                        videoctl, tostring(flip)))

    -- Read 1024 words (0x800 bytes) of OBJ RAM
    local obj_ram = {}
    for i = 0, 1023 do
        obj_ram[i+1] = mem:read_u16(obj_base_addr + i * 2)
    end

    -- Find last valid sprite (stop at ATTR high byte == 0xFF)
    local sprite_count = 0
    for i = 0, 255 do
        local attr = obj_ram[i*4 + 4]   -- 1-indexed: entry i word+3
        if (attr & 0xFF00) == 0xFF00 then break end
        sprite_count = i + 1
    end
    print(string.format("[DUMP] Found %d valid sprite entries", sprite_count))

    return {
        frame         = frame_num,
        obj_base_reg  = obj_base_reg,
        obj_base_addr = obj_base_addr,
        flip_screen   = flip,
        sprite_count  = sprite_count,
        obj_ram       = obj_ram,
    }
end

-- ---------------------------------------------------------------------------
-- Collect all unique tile codes referenced by the sprite table
-- (including multi-tile block expansions)
-- ---------------------------------------------------------------------------
local function collect_tile_codes(obj_data)
    local codes = {}
    local obj_ram = obj_data.obj_ram

    for i = 0, obj_data.sprite_count - 1 do
        local base = i * 4
        local code = obj_ram[base + 3]   -- word +2 (1-indexed)
        local attr  = obj_ram[base + 4]  -- word +3
        local nx    = (attr >> 8)  & 0xF
        local ny    = (attr >> 12) & 0xF

        local base_nibble = code & 0xF
        for row = 0, ny do
            for col = 0, nx do
                local col_nibble = (base_nibble + col) & 0xF
                local tile_code  = (code & 0xFFF0) + row * 0x10 + col_nibble
                codes[tile_code] = true
            end
        end
    end

    local list = {}
    for c, _ in pairs(codes) do list[#list+1] = c end
    table.sort(list)
    print(string.format("[DUMP] %d unique tile codes in sprite table", #list))
    return list
end

-- ---------------------------------------------------------------------------
-- Dump decoded pixel data via MAME's GFX decoder
-- Returns table: { [code] = { [vsub+1] = {px0..px15} } }
-- ---------------------------------------------------------------------------
local function dump_gfx_pixels(tile_codes)
    local gfx = manager.machine.gfx
    if not gfx then
        print("[DUMP] ERROR: manager.machine.gfx is nil")
        return nil
    end

    -- Find the 16x16 sprite GFX element
    local sprite_elem     = nil
    local sprite_elem_idx = nil
    local max_elems       = 0

    for idx, elem in pairs(gfx) do
        local w = elem.width
        local h = elem.height
        local n = elem.elements
        print(string.format("[DUMP]   gfx[%s]: %dx%d tiles, %d elements, %d colors",
                            tostring(idx), w, h, n, elem.colors))
        if w == 16 and h == 16 and n > max_elems then
            sprite_elem     = elem
            sprite_elem_idx = idx
            max_elems       = n
        end
    end

    if not sprite_elem then
        print("[DUMP] WARNING: no 16x16 GFX element found — trying index 1")
        sprite_elem = gfx[1]
        sprite_elem_idx = 1
    end

    if not sprite_elem then
        print("[DUMP] ERROR: no GFX elements available")
        return nil
    end

    print(string.format("[DUMP] Using gfx[%s] for sprites (%d elements, %dx%d)",
                        tostring(sprite_elem_idx), sprite_elem.elements,
                        sprite_elem.width, sprite_elem.height))

    -- Read pixel data for each tile code
    local result = {}
    local ok_count = 0
    local fail_count = 0

    for _, code in ipairs(tile_codes) do
        if code < sprite_elem.elements then
            local tile = {}
            for vsub = 0, 15 do
                local row_pixels = {}
                for px = 0, 15 do
                    local ok, nibble = pcall(function()
                        return sprite_elem:pixel(code, px, vsub)
                    end)
                    row_pixels[px+1] = ok and math.floor(nibble + 0.5) or 0xF
                end
                tile[vsub+1] = row_pixels
            end
            result[tostring(code)] = tile
            ok_count = ok_count + 1
        else
            -- Code out of range — all transparent
            local tile = {}
            for vsub = 0, 15 do
                tile[vsub+1] = {0xF,0xF,0xF,0xF,0xF,0xF,0xF,0xF,
                                0xF,0xF,0xF,0xF,0xF,0xF,0xF,0xF}
            end
            result[tostring(code)] = tile
            fail_count = fail_count + 1
        end
    end

    print(string.format("[DUMP] GFX dump: %d tiles OK, %d out-of-range",
                        ok_count, fail_count))
    return result
end

-- ---------------------------------------------------------------------------
-- Frame hook
-- ---------------------------------------------------------------------------
emu.register_frame_done(function()
    frame_num = frame_num + 1
    if done then return end

    -- Progress indicator every 50 frames
    if frame_num % 50 == 0 then
        print(string.format("[DUMP] Frame %d / %d", frame_num, TARGET_FRAME))
    end

    if frame_num ~= TARGET_FRAME then return end

    print(string.format("[DUMP] === Capturing frame %d ===", frame_num))

    local cpu = manager.machine.devices[":maincpu"]
    if not cpu then
        print("[DUMP] ERROR: :maincpu device not found")
        done = true
        return
    end

    local mem = cpu.spaces["program"]
    if not mem then
        print("[DUMP] ERROR: program space not found")
        done = true
        return
    end

    -- 1. Dump OBJ RAM
    local obj_data = dump_obj_ram(mem)

    -- 2. Collect tile codes
    local tile_codes = collect_tile_codes(obj_data)

    -- 3. Dump GFX pixel data
    local gfx_data = dump_gfx_pixels(tile_codes)

    -- 4. Save OBJ RAM JSON
    local obj_path = OUTPUT_DIR .. string.format("frame%04d_obj_ram.json", frame_num)
    write_file(obj_path, json_val(obj_data))

    -- 5. Save GFX JSON
    if gfx_data then
        local gfx_path = OUTPUT_DIR .. string.format("frame%04d_gfx.json", frame_num)
        write_file(gfx_path, json_val(gfx_data))
    else
        print("[DUMP] WARNING: GFX data unavailable — ROM data will use procedural fallback")
    end

    done = true
    print("[DUMP] Capture complete. Exiting MAME.")
    manager.machine:exit()
end)

print(string.format("[DUMP] Script loaded. Capturing frame %d.", TARGET_FRAME))
