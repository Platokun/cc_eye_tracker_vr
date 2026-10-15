@echo off
rem ============================================================================
rem  cc_eye_tracker_vr - build the firmware
rem
rem  Reads user_board.nzk.config, builds for the XIAO ESP32S3 USB-camera board
rem  profile, and writes a single flashable image to:
rem
rem      out\openiris_xiao_esp32s3_usb_cam_merged.bin
rem
rem  Usage:
rem     build.bat                 build (default)
rem     build.bat --config-only   only check/regenerate the config fragment
rem
rem  Requires ESP-IDF v5.4.2 once. If it is not already loaded in this window
rem  the script looks in the usual places. Easiest: open an "ESP-IDF Terminal"
rem  in VS Code and run this file.
rem ============================================================================
setlocal EnableDelayedExpansion
cd /d "%~dp0"
title cc_eye_tracker_vr - build firmware

set "BOARD_PROFILE=boards/seed_studio/xiao_esp32s3_usb_cam"
set "USER_CONFIG=boards/generated/user_config"
set "BUILD_DIR=build"
set "OUT_DIR=out"
set "OUT_BIN=openiris_xiao_esp32s3_usb_cam_merged.bin"

set "CONFIG_ONLY=0"
if /i "%~1"=="--config-only" set "CONFIG_ONLY=1"

echo ============================================================
echo  cc_eye_tracker_vr - firmware build
echo ============================================================
echo.

rem ------------------------------------------------------------------
rem  1. Apply user_board.nzk.config
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
    if not defined NO_PAUSE pause
    exit /b 1
)

"%PYEXE%" tools\apply_user_config.py
if !ERRORLEVEL! NEQ 0 (
    echo.
    echo [X] user_board.nzk.config has a problem. Fix it and run this again.
    echo.
    if not defined NO_PAUSE pause
    exit /b 1
)
echo.

if "!CONFIG_ONLY!"=="1" (
    echo Config only - stopping here.
    if not defined NO_PAUSE pause
    exit /b 0
)

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
echo [2/4] Configuring - regenerates sdkconfig from the board profile.

set "SDKCONFIG_DEFAULTS=boards/sdkconfig.base_defaults;%BOARD_PROFILE%;%USER_CONFIG%"
if exist sdkconfig del /q sdkconfig
if exist sdkconfig.old del /q sdkconfig.old

rem  idf.py set-target runs 'fullclean' first, which deletes the whole build
rem  directory. Skip it when the directory is already a configured esp32s3 tree,
rem  so builds stay incremental.
set "NEED_SET_TARGET=1"
if not exist "%BUILD_DIR%\CMakeCache.txt" goto :check_stale_dir
findstr /b /c:"IDF_TARGET:STRING=esp32s3" "%BUILD_DIR%\CMakeCache.txt" >nul 2>&1
if !ERRORLEVEL! EQU 0 (
    set "NEED_SET_TARGET=0"
    echo      reusing the configured build directory "%BUILD_DIR%"
    goto :do_configure
)

:check_stale_dir
if not exist "%BUILD_DIR%" goto :do_configure
echo      "%BUILD_DIR%" is not a configured esp32s3 tree; moving it aside.
move /y "%BUILD_DIR%" "%BUILD_DIR%.stale.%RANDOM%" >nul

:do_configure
if "!NEED_SET_TARGET!"=="1" (
    idf.py -B "%BUILD_DIR%" set-target esp32s3
    if !ERRORLEVEL! NEQ 0 goto :build_failed
)

echo.
echo [3/4] Building firmware. The first build takes several minutes.
echo.
idf.py -B "%BUILD_DIR%" build
if !ERRORLEVEL! NEQ 0 goto :build_failed

echo.
echo [4/4] Merging into a single flashable image...
if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"
rem  idf.py merge-bin runs esptool *inside the build directory*, so a relative
rem  -o path would land in build\out\. Pass an absolute path.
idf.py -B "%BUILD_DIR%" merge-bin -o "%CD%\%OUT_DIR%\%OUT_BIN%"
if !ERRORLEVEL! NEQ 0 goto :build_failed

echo.
echo ============================================================
echo  BUILD OK
echo ============================================================
echo  Single flashable file:  %OUT_DIR%\%OUT_BIN%
echo    flash at offset 0x0
echo.
echo  To flash now:    flash.bat
echo  Or both at once: build_and_flash.bat
echo.
if not defined NO_PAUSE pause
exit /b 0

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
if not defined NO_PAUSE pause
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
echo   - No internet on the very first build. ESP-IDF needs to fetch
echo     espressif/usb_host_uvc once; it is vendored under
echo     managed_components, so this should not normally be needed.
echo.
if not defined NO_PAUSE pause
exit /b 1
