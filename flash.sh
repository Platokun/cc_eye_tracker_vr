#!/usr/bin/env bash
# ============================================================================
#  cc_eye_tracker_vr - flash the firmware
#
#  Writes the prebuilt image to the board. Run ./build.sh first (or use
#  ./build_and_flash.sh to do both).
#
#  Usage:
#     ./flash.sh                       auto-detect the port
#     ./flash.sh --port /dev/ttyACM0
#     ./flash.sh --bin path/to/other.bin
#     ./flash.sh --baud 460800
#
#  BEFORE RUNNING - put the board in download mode:
#     1. unplug the USB-C cable (camera and OTG adapter unplugged)
#     2. hold the BOOT button
#     3. plug the USB-C cable into the PC
#     4. release BOOT
#
#  The running firmware never appears as a serial port, because the USB port
#  belongs to the camera. You have to do the BOOT dance every time.
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")"

OUT_BIN="out/openiris_xiao_esp32s3_usb_cam_merged.bin"
BAUD="921600"
PORT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT="${2:?--port needs a value}"; shift 2 ;;
        --bin)  OUT_BIN="${2:?--bin needs a value}"; shift 2 ;;
        --baud) BAUD="${2:?--baud needs a value}"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ ! -f "$OUT_BIN" ]; then
    echo "ERROR: firmware image not found: $OUT_BIN" >&2
    echo >&2
    echo "Build it first:   ./build.sh" >&2
    echo "Or both at once:  ./build_and_flash.sh" >&2
    echo >&2
    exit 1
fi

# --- find esptool -----------------------------------------------------------
# Keep the command as an array so this works the same for a script, a module
# and a standalone binary.
ESPTOOL=()
if command -v esptool.py >/dev/null 2>&1; then
    ESPTOOL=(esptool.py)
elif python3 -c "import esptool" >/dev/null 2>&1; then
    ESPTOOL=(python3 -m esptool)
else
    # PlatformIO bundles one; use it if PlatformIO has ever run on this machine.
    found=""
    for d in "$HOME/.platformio/packages"/tool-esptoolpy* "$HOME/.platformio/packages"/tool-esptool*; do
        [ -d "$d" ] || continue
        if [ -f "$d/esptool.py" ]; then found="$d/esptool.py"; break; fi
        if [ -x "$d/esptool" ]; then found="$d/esptool"; break; fi
    done
    if [ -n "$found" ]; then
        case "$found" in
            *.py) ESPTOOL=(python3 "$found") ;;
            *)    ESPTOOL=("$found") ;;
        esac
    else
        echo "ERROR: esptool not found." >&2
        echo >&2
        echo "Install it with:  python3 -m pip install esptool" >&2
        echo "Or let PlatformIO install it (open the flash/ folder in VS Code once)." >&2
        echo "Or flash from a browser, no install: https://espressif.github.io/esptool-js/" >&2
        echo >&2
        exit 1
    fi
fi

PORT_ARG=()
if [ -n "$PORT" ]; then
    PORT_ARG=(--port "$PORT")
fi

echo "============================================================"
echo " cc_eye_tracker_vr - flashing"
echo "============================================================"
echo " image : $OUT_BIN"
echo " offset: 0x0"
echo " port  : ${PORT:-auto-detect}"
echo
echo " If this fails, make sure the board is in download mode:"
echo "   hold BOOT, plug the USB-C cable in, release BOOT, then re-run."
echo

"${ESPTOOL[@]}" --chip esp32s3 "${PORT_ARG[@]}" --baud "$BAUD" \
    write_flash 0x0 "$OUT_BIN"

echo
echo "============================================================"
echo " FLASH OK"
echo "============================================================"
echo " Now: unplug from the PC, attach the OTG adapter + camera to the"
echo " XIAO's USB-C port, and feed 5 V (through a Schottky diode) into"
echo " the 5V pin. See the Power section of README.md."
echo
