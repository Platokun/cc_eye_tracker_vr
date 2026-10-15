#!/usr/bin/env bash
# ============================================================================
#  cc_eye_tracker_vr - build the firmware using user_board.nzk.config
#
#  Usage:
#     ./build_and_flash.sh                 build only
#     ./build_and_flash.sh --flash PORT    build then flash (e.g. /dev/ttyACM0)
#     ./build_and_flash.sh --config-only   just check/write the config
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")"

BOARD_PROFILE="boards/seed_studio/xiao_esp32s3_usb_cam"
OUT_BIN="openiris_xiao_esp32s3_usb_cam_merged.bin"

DO_FLASH=0
PORT=""
CONFIG_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --flash) DO_FLASH=1; PORT="${2:-}"; shift 2 || true ;;
        --config-only) CONFIG_ONLY=1; shift ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
done

echo "============================================================"
echo " cc_eye_tracker_vr - firmware build"
echo "============================================================"
echo

# ---------------------------------------------------------------------------
# 1. Apply her settings
# ---------------------------------------------------------------------------
echo "[1/4] Reading user_board.nzk.config ..."
python3 tools/apply_user_config.py
echo

if [ "$CONFIG_ONLY" -eq 1 ]; then
    echo "Config only - stopping here."
    exit 0
fi

# ---------------------------------------------------------------------------
# 2. Make sure the ESP-IDF environment is available
# ---------------------------------------------------------------------------
if ! command -v idf.py >/dev/null 2>&1; then
    for candidate in "${IDF_PATH:-}" "$HOME/esp/esp-idf" "$HOME/esp-idf" "/opt/esp-idf"; do
        if [ -n "$candidate" ] && [ -f "$candidate/export.sh" ]; then
            echo "Using ESP-IDF at $candidate"
            # shellcheck disable=SC1090
            . "$candidate/export.sh" >/dev/null
            break
        fi
    done
fi

if ! command -v idf.py >/dev/null 2>&1; then
    echo "ERROR: idf.py was not found."
    echo
    echo "Install ESP-IDF 5.4.x, or open an 'ESP-IDF' terminal first, e.g.:"
    echo "    . \$HOME/esp/esp-idf/export.sh"
    echo
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Configure and build
# ---------------------------------------------------------------------------
export SDKCONFIG_DEFAULTS="boards/sdkconfig.base_defaults;${BOARD_PROFILE};boards/generated/user_config"

echo "[2/4] Configuring (this regenerates sdkconfig from the board profile) ..."
rm -f sdkconfig sdkconfig.old
idf.py set-target esp32s3 >/dev/null

echo "[3/4] Building firmware (first build takes several minutes) ..."
idf.py build

# ---------------------------------------------------------------------------
# 4. Merge into one flashable image
# ---------------------------------------------------------------------------
echo
echo "[4/4] Merging into a single flashable image ..."
ESPTOOL="esptool.py"
command -v "$ESPTOOL" >/dev/null 2>&1 || ESPTOOL="python3 -m esptool"
( cd build && $ESPTOOL --chip esp32s3 merge_bin -o "../${OUT_BIN}" @flash_args )

echo
echo "============================================================"
echo " BUILD OK"
echo "============================================================"
echo " Single flashable file: ${OUT_BIN}"
echo "   flash at offset 0x0"
echo

if [ "$DO_FLASH" -eq 1 ]; then
    echo "Flashing to ${PORT:-auto-detected port} ..."
    if [ -n "$PORT" ]; then
        idf.py -p "$PORT" flash
    else
        idf.py flash
    fi
    echo "Flash complete."
else
    echo " To flash now:  ./build_and_flash.sh --flash /dev/ttyACM0"
    echo " Or in VS Code: PlatformIO -> flash.bat / custom target"
fi
