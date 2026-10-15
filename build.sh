#!/usr/bin/env bash
# ============================================================================
#  cc_eye_tracker_vr - build the firmware
#
#  Reads user_board.nzk.config, builds for the XIAO ESP32S3 USB-camera board
#  profile, and writes a single flashable image to:
#
#      out/openiris_xiao_esp32s3_usb_cam_merged.bin
#
#  Usage:
#     ./build.sh                 build (default)
#     ./build.sh --config-only   only check/regenerate the config fragment
#
#  Requires ESP-IDF v5.4.2 once (idf.py on PATH, or at $IDF_PATH,
#  ~/esp/esp-idf, ~/esp-idf, /opt/esp-idf - see README.md).
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")"

BOARD_PROFILE="boards/seed_studio/xiao_esp32s3_usb_cam"
USER_CONFIG="boards/generated/user_config"
BUILD_DIR="build"
OUT_DIR="out"
OUT_BIN="openiris_xiao_esp32s3_usb_cam_merged.bin"

CONFIG_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --config-only) CONFIG_ONLY=1; shift ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

echo "============================================================"
echo " cc_eye_tracker_vr - firmware build"
echo "============================================================"
echo

# ---------------------------------------------------------------------------
# 1. Apply user_board.nzk.config
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
    echo "ERROR: idf.py was not found." >&2
    echo >&2
    echo "Install ESP-IDF v5.4.2, or open an ESP-IDF terminal first, e.g.:" >&2
    echo "    . \$HOME/esp/esp-idf/export.sh" >&2
    echo >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Configure and build
# ---------------------------------------------------------------------------
export SDKCONFIG_DEFAULTS="boards/sdkconfig.base_defaults;${BOARD_PROFILE};${USER_CONFIG}"

echo "[2/4] Configuring (regenerates sdkconfig from the board profile) ..."
rm -f sdkconfig sdkconfig.old

# idf.py set-target runs 'fullclean' first, which deletes the entire build
# directory. Skip it when the directory is already a configured esp32s3 tree:
# that keeps builds incremental and, more importantly, avoids shutil.rmtree on
# a network filesystem, where deletion is lazy and can race with the build that
# follows it.
NEED_SET_TARGET=1
if [ -f "$BUILD_DIR/CMakeCache.txt" ] && grep -q "^IDF_TARGET:STRING=esp32s3" "$BUILD_DIR/CMakeCache.txt"; then
    NEED_SET_TARGET=0
    echo "     reusing the configured build directory '$BUILD_DIR'"
fi

if [ "$NEED_SET_TARGET" -eq 1 ] && [ -d "$BUILD_DIR" ]; then
    stale="${BUILD_DIR}.stale.$(date +%s)"
    echo "     '$BUILD_DIR' is not a configured esp32s3 tree; moving it to '$stale'"
    mv "$BUILD_DIR" "$stale"
fi

if [ "$NEED_SET_TARGET" -eq 1 ]; then
    idf.py -B "$BUILD_DIR" set-target esp32s3 >/dev/null
fi

echo "[3/4] Building firmware (the first build takes several minutes) ..."
idf.py -B "$BUILD_DIR" build

# ---------------------------------------------------------------------------
# 4. Merge into one flashable image in out/
# ---------------------------------------------------------------------------
echo
echo "[4/4] Merging into a single flashable image ..."
mkdir -p "$OUT_DIR"
# idf.py merge-bin runs esptool *inside the build directory*, so a relative
# -o path would land in build/out/. Pass an absolute path.
idf.py -B "$BUILD_DIR" merge-bin -o "${PWD}/${OUT_DIR}/${OUT_BIN}"

echo
echo "============================================================"
echo " BUILD OK"
echo "============================================================"
echo " Single flashable file: ${OUT_DIR}/${OUT_BIN}"
echo "   flash at offset 0x0"
echo
echo " To flash now:   ./flash.sh"
echo " Or both at once: ./build_and_flash.sh"
echo
