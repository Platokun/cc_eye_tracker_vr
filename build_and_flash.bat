@echo off
rem ============================================================================
rem  cc_eye_tracker_vr - build and then flash
rem
rem  Equivalent to:
rem      build.bat  &&  flash.bat
rem
rem  Usage:
rem     build_and_flash.bat
rem     build_and_flash.bat COM5
rem
rem  It pauses between the two steps so you can put the board into download
rem  mode: hold BOOT, plug the USB-C cable in, release BOOT.
rem ============================================================================
setlocal EnableDelayedExpansion
cd /d "%~dp0"
title cc_eye_tracker_vr - build and flash

rem  build.bat must not stop for a keypress in the middle of this.
set "NO_PAUSE=1"
call build.bat
if !ERRORLEVEL! NEQ 0 (
    echo.
    echo [X] Build failed - not flashing. See the messages above.
    echo.
    pause
    exit /b 1
)

echo ============================================================
echo  PUT THE BOARD IN DOWNLOAD MODE NOW
echo ============================================================
echo    1. Hold down the BOOT button on the XIAO
echo    2. Plug the USB-C cable into the PC
echo    3. Release BOOT
echo.
echo  The camera and the OTG adapter must NOT be plugged in.
echo.
pause

call flash.bat %*
set "RC=!ERRORLEVEL!"
exit /b !RC!
