-- mame_capture.lua — Per-frame screenshot capture via MAME Lua scripting
--
-- Works with MAME 0.245+ (tested 0.257 on Windows)
-- Registers a frame callback and calls manager.machine.video:snapshot() each frame.
--
-- NOTE: Requires a real video renderer (not -video none). Use the AVI workflow
-- instead for headless/SSH operation — see capture_mame_frames.sh.
--
-- Environment variables (set before launching MAME):
--   MAME_CAPTURE_FRAMES : number of frames to capture (default 300)
--   MAME_CAPTURE_DIR    : output directory for frame_NNNN.png (default ".")
--
-- Launch example (with display available):
--   mame tdragon -rompath /path/to/roms -nothrottle -video d3d -window \
--     -sound none -autoboot_script mame_capture.lua

local MAX_FRAMES = tonumber(os.getenv("MAME_CAPTURE_FRAMES")) or 300
local OUT_DIR    = os.getenv("MAME_CAPTURE_DIR") or "."
local frame_count = 0

emu.register_frame_done(function()
    if frame_count >= MAX_FRAMES then
        manager.machine:exit()
        return
    end

    local path = string.format("%s/frame_%04d.png", OUT_DIR, frame_count)
    local ok, err = pcall(function()
        manager.machine.video:snapshot(path)
    end)

    if not ok then
        -- Fallback: snapshot without custom path (goes to MAME snapshot dir)
        pcall(function() manager.machine.video:snapshot() end)
    end

    frame_count = frame_count + 1

    if frame_count >= MAX_FRAMES then
        manager.machine:exit()
    end
end)

print(string.format("[mame_capture] Capturing %d frames to: %s", MAX_FRAMES, OUT_DIR))
