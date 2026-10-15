#!/usr/bin/env bash
# ============================================================================
#  cc_eye_tracker_vr - build and then flash
#
#  Equivalent to:
#      ./build.sh && ./flash.sh [--port PORT]
#
#  Usage:
#     ./build_and_flash.sh
#     ./build_and_flash.sh --port /dev/ttyACM0
#
#  It pauses between the two steps so you can put the board into download
#  mode: hold BOOT, plug the USB-C cable in, release BOOT.
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")"

./build.sh

echo "============================================================"
echo " PUT THE BOARD IN DOWNLOAD MODE NOW"
echo "============================================================"
echo "   1. Hold down the BOOT button on the XIAO"
echo "   2. Plug the USB-C cable into the PC"
echo "   3. Release BOOT"
echo
echo " The camera and the OTG adapter must NOT be plugged in."
echo
read -r -p " Press Enter when the board is in download mode (Ctrl-C to stop) ... " _

./flash.sh "$@"
