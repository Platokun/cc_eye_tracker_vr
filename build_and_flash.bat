@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0"
title cc_eye_tracker_vr - build firmware

set "BOARD_PROFILE=boards/seed_studio/xiao_esp32s3_usb_cam"
set "OUT_BIN=openiris_xiao_esp32s3_usb_cam_merged.bin"

echo ============================================================
echo  cc_eye_tracker_vr - firmware build
echo ============================================================
echo.

rem ------------------------------------------------------------------
rem  1. Apply her settings from user_board.nzk.config
rem ------------------------------------------------------------------
echo [1/4] Reading user_board.nzk.config ...

set "PYEXE="
where python >nul 2>&1 && set "PYEXE=python"
if not defined PYEXE (
    if exist "%USERPROFILE%\.platformio\penv\Scripts\python.exe" set "PYEXE=%USERPROFILE%\.platformio\penv\Scripts\python.exe"
)
if not defined PYEXE (
    echo [X] No Python found. Install ESP-IDF first - it brings its own Python.
    echo.
    pause
    exit /b 1
)

"%PYEXE%" tools\apply_user_config.py
if !ERRORLEVEL! NEQ 0 (
    echo.
    echo [X] user_board.nzk.config has a problem. Fix it and run this again.
    echo.
    pause
    exit /b 1
)
echo.

rem ------------------------------------------------------------------
rem  2. Make sure the ESP-IDF environment is loaded
rem ------------------------------------------------------------------
where idf.py >nul 2>&1
if !ERRORLEVEL! EQU 0 goto :idf_ready

echo ESP-IDF is not loaded in this window, looking for it...
set "IDF_DIR="

if defined IDF_PATH if exist "!IDF_PATH!\export.bat" set "IDF_DIR=!IDF_PATH!"
if not defined IDF_DIR if exist "%USERPROFILE%\esp\esp-idf\export.bat" set "IDF_DIR=%USERPROFILE%\esp\esp-idf"
if not defined IDF_DIR if exist "%USERPROFILE%\esp-idf\export.bat" set "IDF_DIR=%USERPROFILE%\esp-idf"
if not defined IDF_DIR if exist "C:\Espressif\frameworks\esp-idf-v5.4.2\export.bat" set "IDF_DIR=C:\Espressif\frameworks\esp-idf-v5.4.2"
if not defined IDF_DIR if exist "C:\esp\esp-idf\export.bat" set "IDF_DIR=C:\esp\esp-idf"

if not defined IDF_DIR goto :no_idf

echo Using ESP-IDF at !IDF_DIR!
call "!IDF_DIR!\export.bat" >nul 2>&1

where idf.py >nul 2>&1
if !ERRORLEVEL! NEQ 0 goto :no_idf

:idf_ready
echo [2/4] Configuring - this regenerates sdkconfig from the board profile.

set "SDKCONFIG_DEFAULTS=boards/sdkconfig.base_defaults;%BOARD_PROFILE%;boards/generated/user_config"
if exist sdkconfig del /q sdkconfig
if exist sdkconfig.old del /q sdkconfig.old

idf.py set-target esp32s3
if !ERRORLEVEL! NEQ 0 goto :build_failed

echo.
echo [3/4] Building firmware. The first build takes several minutes.
echo.
idf.py build
if !ERRORLEVEL! NEQ 0 goto :build_failed

echo.
echo [4/4] Merging into a single flashable image...
pushd build
esptool.py --chip esp32s3 merge_bin -o "..\%OUT_BIN%" @flash_args
set "MERGE_RC=!ERRORLEVEL!"
popd
if not "!MERGE_RC!"=="0" goto :build_failed

echo.
echo ============================================================
echo  BUILD OK
echo ============================================================
echo  Single flashable file:  %OUT_BIN%
echo.
set "DOFLASH="
set /p DOFLASH=Flash it to the board now? (Y/N): 
if /i not "!DOFLASH!"=="Y" goto :no_flash

echo.
echo ============================================================
echo  PUT THE BOARD IN DOWNLOAD MODE NOW
echo ============================================================
echo    1. Hold down the BOOT button on the XIAO
echo    2. Plug the USB-C cable into this PC
echo    3. Release BOOT
echo.
echo  The camera and OTG adapter must NOT be plugged in.
echo.
pause
echo.
echo Flashing... do not unplug the board.
echo.
esptool.py --chip esp32s3 --baud 921600 write_flash 0x0 "%OUT_BIN%"
if !ERRORLEVEL! NEQ 0 goto :flash_failed

echo.
echo ============================================================
echo  [OK] Done - firmware built and flashed.
echo ============================================================
echo.
echo  Next:
echo   1. Unplug the board from the PC.
echo   2. Plug the OTG adapter and the camera into the XIAO.
echo   3. Feed 5V into the 5V and GND pins. NOT a 3.7V battery.
echo   4. It will join the wifi you set in user_board.nzk.config.
echo.
pause
exit /b 0

:no_flash
echo.
echo  Not flashing. The image is ready at:
echo     %OUT_BIN%
echo.
echo  Flash later with:
echo     esptool.py --chip esp32s3 --port COM5 --baud 921600 write_flash 0x0 %OUT_BIN%
echo  or open the flash\ folder in VS Code and click the custom target.
echo.
pause
exit /b 0

rem ------------------------------------------------------------------
:flash_failed
echo.
echo ============================================================
echo  [X] Flashing failed - see the messages above.
echo ============================================================
echo.
echo  Check:
echo   - Did you hold BOOT while plugging the cable in?
echo   - Is the camera / OTG adapter unplugged?
echo   - Try another USB cable - it must carry data, not only power.
echo   - Close any serial monitor holding the port open.
echo.
pause
exit /b 1

rem ------------------------------------------------------------------
:no_idf
echo.
echo [X] Could not find ESP-IDF on this PC.
echo.
echo  Install the ESP-IDF extension in VS Code once:
echo    1. Extensions -^> search "ESP-IDF" -^> Install
echo    2. Open the Command Palette, run "ESP-IDF: Configure ESP-IDF Extension"
echo    3. Choose Express install, version v5.4.2
echo.
echo  Then open an "ESP-IDF Terminal" in VS Code and run this file again.
echo.
pause
exit /b 1

rem ------------------------------------------------------------------
:build_failed
echo.
echo ============================================================
echo  [X] Build failed - see the messages above.
echo ============================================================
echo.
echo  Common causes:
echo   - ESP-IDF version is not 5.4.x
echo   - No internet on the very first build, ESP-IDF needs to
echo     download espressif/usb_host_uvc once. It is already
echo     included in managed_components, so this should not happen.
echo.
pause
exit /b 1
