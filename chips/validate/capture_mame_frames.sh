#!/bin/bash
# capture_mame_frames.sh — Capture MAME reference frames for pixel-accurate validation
#
# Uses GPU PC (192.168.0.149) which has MAME 0.257 installed.
# ROMs are sourced from rpmini's Game Drive collection.
# Pipeline: rpmini ROM -> local /tmp -> GPU PC -> MAME AVI -> ffmpeg PNGs -> rsync back
#
# Usage:
#   ./capture_mame_frames.sh <game> [frames] [fps_divisor]
#
# Arguments:
#   game         MAME game name (e.g., tdragon, batsugun, gunbird)
#   frames       Number of frames to capture (default: 300)
#   fps_divisor  Capture every Nth frame via ffmpeg -r (default: 1 = all frames)
#
# Output:
#   chips/validate/results/<game>/mame_ref/frame_NNNN.png  (0-indexed)
#
# Examples:
#   ./capture_mame_frames.sh tdragon 300
#   ./capture_mame_frames.sh batsugun 600 2

set -euo pipefail

GAME="${1:?Usage: $0 <game> [frames] [fps_divisor]}"
FRAMES="${2:-300}"
FPS_DIV="${3:-1}"

MAME_EXE="C:\\Users\\mitch\\OneDrive\\Desktop\\Archive\\Mame XML\\mame.exe"
FFMPEG_EXE="C:\\Users\\mitch\\AppData\\Local\\ffmpegio\\ffmpeg-downloader\\ffmpeg\\bin\\ffmpeg.exe"
ROM_SRC_HOST="rp@RPs-Mac-mini.local"
ROM_SRC_KEY="$HOME/.ssh/id_imac"
ROM_SRC_DIR="/Volumes/Game Drive/MAME 0 245 ROMs (merged)"
GPU_HOST="mitch@192.168.0.149"
GPU_KEY="$HOME/.ssh/id_rsa_gpu"

LOCAL_OUT="chips/validate/results/${GAME}/mame_ref"
GPU_ROM_DIR="C:\\mame_roms"
GPU_WORK_DIR="C:\\mame_capture_${GAME}"

# Resolve script directory to support running from any cwd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_OUT="${SCRIPT_DIR}/results/${GAME}/mame_ref"

echo "=== MAME Frame Capture: ${GAME} ==="
echo "  Frames:   ${FRAMES}"
echo "  Output:   ${LOCAL_OUT}"

mkdir -p "${LOCAL_OUT}"

# ── Step 1: Ensure ROMs are on GPU PC ─────────────────────────────────────────
echo ""
echo "[1/4] Syncing ROMs to GPU PC..."

# Helper/BIOS ROMs required by certain games (space-separated if multiple)
# batsugun, gunbird: no extra BIOS needed (Toaplan/Psikyo self-contained)
# Note: MAME 0.245 ROMs with MAME 0.257 may show "NO GOOD DUMP KNOWN" warnings
# for some games (e.g., gunbird) — these are checksum mismatches, game still runs.
declare -A BIOS_DEPS
BIOS_DEPS[tdragon]="nmk004"
BIOS_DEPS[tdragon2]="nmk004"
BIOS_DEPS[denjinmk]="nmk004"
BIOS_DEPS[twineagl]="nmk004"
BIOS_DEPS[twineag2]="nmk004"

ROMS_TO_COPY=("${GAME}")
if [[ -n "${BIOS_DEPS[$GAME]+_}" ]]; then
    ROMS_TO_COPY+=("${BIOS_DEPS[$GAME]}")
fi

for rom in "${ROMS_TO_COPY[@]}"; do
    rom_zip="${rom}.zip"
    local_tmp="/tmp/mame_rom_${rom}.zip"

    # Check if already on GPU
    already=$(ssh -i "${GPU_KEY}" -o IdentitiesOnly=yes "${GPU_HOST}" \
        "powershell -Command \"Test-Path '${GPU_ROM_DIR}\\${rom_zip}'\"" 2>/dev/null || echo "False")
    if [[ "$already" == "True" ]]; then
        echo "  ROM already on GPU: ${rom_zip}"
        continue
    fi

    echo "  Copying ROM: ${rom_zip}"
    # Copy from rpmini -> local /tmp
    scp -i "${ROM_SRC_KEY}" -o IdentitiesOnly=yes \
        "${ROM_SRC_HOST}:${ROM_SRC_DIR}/${rom_zip}" "${local_tmp}" 2>/dev/null
    # Copy local /tmp -> GPU
    scp -i "${GPU_KEY}" -o IdentitiesOnly=yes \
        "${local_tmp}" "${GPU_HOST}:C:/mame_roms/${rom_zip}" 2>/dev/null
    rm -f "${local_tmp}"
    echo "  ROM uploaded: ${rom_zip}"
done

# ── Step 2: Run MAME with AVI capture ─────────────────────────────────────────
echo ""
echo "[2/4] Running MAME (AVI capture)..."

# Calculate seconds to run: MAME tdragon runs at ~56.18 fps
# Use -bench N where N = seconds; add 5 seconds buffer for boot time
SECONDS_TO_RUN=$(( (FRAMES / 56) + 10 ))
AVI_PATH="C:\\mame_capture_${GAME}.avi"

ssh -i "${GPU_KEY}" -o IdentitiesOnly=yes "${GPU_HOST}" \
    "powershell -Command \"& '${MAME_EXE}' ${GAME} -rompath '${GPU_ROM_DIR}' -nothrottle -video none -sound none -aviwrite '${AVI_PATH}' -bench ${SECONDS_TO_RUN} 2>&1\"" \
    2>&1 | grep -v "^$" || true

echo "  MAME run complete."

# ── Step 3: Extract frames with ffmpeg ────────────────────────────────────────
echo ""
echo "[3/4] Extracting ${FRAMES} frames with ffmpeg..."

GPU_PNG_DIR="C:\\mame_frames_${GAME}"

# Create output dir on GPU
ssh -i "${GPU_KEY}" -o IdentitiesOnly=yes "${GPU_HOST}" \
    "powershell -Command \"New-Item -ItemType Directory -Force -Path '${GPU_PNG_DIR}' | Out-Null\"" 2>/dev/null

# Extract exactly FRAMES frames, 0-indexed (ffmpeg is 1-indexed; we renumber)
# -vframes N: extract N frames
# frame_%04d.png starts at frame_0001.png in ffmpeg — we fix numbering below
ssh -i "${GPU_KEY}" -o IdentitiesOnly=yes "${GPU_HOST}" \
    "powershell -Command \"& '${FFMPEG_EXE}' -y -i '${AVI_PATH}' -frames:v ${FRAMES} '${GPU_PNG_DIR}\\frame_%04d.png' 2>&1 | Select-String 'frame='\"" \
    2>&1 || true

# Renumber ffmpeg's 1-indexed frames to 0-indexed
# Write a PowerShell script with the path hardcoded to avoid SSH quoting issues
echo "  Renumbering frames to 0-indexed..."
local_ps_script="/tmp/mame_renumber_${GAME}.ps1"

# GPU_PNG_DIR uses bash backslashes; PowerShell needs forward slashes or escaped backslashes
GPU_PNG_DIR_PS="${GPU_PNG_DIR//\\/\\\\}"

cat > "${local_ps_script}" << PSEOF
\$dir = "${GPU_PNG_DIR_PS}"
\$files = Get-ChildItem \$dir -Filter 'frame_????.png' | Sort-Object Name
\$i = 0
foreach (\$f in \$files) {
    \$newname = "frame_{0:D4}.png" -f \$i
    if (\$f.Name -ne \$newname) {
        Rename-Item \$f.FullName (Join-Path \$f.DirectoryName \$newname)
    }
    \$i++
}
Write-Host "Renumbered \$i frames (0-indexed)"
PSEOF

scp -i "${GPU_KEY}" -o IdentitiesOnly=yes \
    "${local_ps_script}" "${GPU_HOST}:C:/mame_renumber.ps1" 2>/dev/null

ssh -i "${GPU_KEY}" -o IdentitiesOnly=yes "${GPU_HOST}" \
    "powershell -ExecutionPolicy Bypass -File C:\\mame_renumber.ps1" 2>&1

# ── Step 4: Copy frames back to local machine ──────────────────────────────────
echo ""
echo "[4/4] Copying frames to ${LOCAL_OUT}..."

# Use scp with wildcard (Windows scp from OpenSSH handles this)
scp -i "${GPU_KEY}" -o IdentitiesOnly=yes \
    "${GPU_HOST}:C:/mame_frames_${GAME}/frame_*.png" "${LOCAL_OUT}/" 2>&1

FRAME_COUNT=$(ls "${LOCAL_OUT}"/frame_*.png 2>/dev/null | wc -l | tr -d ' ')
echo ""
echo "=== Done: ${FRAME_COUNT} frames captured to ${LOCAL_OUT} ==="

# ── Cleanup remote AVI (large file) ───────────────────────────────────────────
ssh -i "${GPU_KEY}" -o IdentitiesOnly=yes "${GPU_HOST}" \
    "powershell -Command \"Remove-Item -Force '${AVI_PATH}' -ErrorAction SilentlyContinue\"" 2>/dev/null || true
echo "  Cleaned up AVI on GPU."
