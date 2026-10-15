@echo off
rem ============================================================================
rem  cc_eye_tracker_vr - flash the firmware
rem
rem  Writes the prebuilt image to the board. Run build.bat first, or use
rem  build_and_flash.bat to do both.
rem
rem  Usage:
rem     flash.bat                  auto-detect the port
rem     flash.bat COM5             use a specific port
rem     flash.bat --bin other.bin
rem     flash.bat --baud 460800
rem
rem  BEFORE RUNNING - put the board in download mode:
rem     1. unplug the USB-C cable (camera and OTG adapter unplugged)
rem     2. hold the BOOT button
rem     3. plug the USB-C cable into the PC
rem     4. release BOOT
rem
rem  The running firmware never appears as a serial port, because the USB port
rem  belongs to the camera. You have to do the BOOT dance every time.
rem ============================================================================
setlocal EnableDelayedExpansion
cd /d "%~dp0"
title cc_eye_tracker_vr - flash firmware

set "BIN=out\openiris_xiao_esp32s3_usb_cam_merged.bin"
set "BAUD=921600"
set "PORT="

:parse
if "%~1"=="" goto :parsed
if /i "%~1"=="--port" (
    set "PORT=%~2"
    shift & shift & goto :parse
)
if /i "%~1"=="--bin" (
    set "BIN=%~2"
    shift & shift & goto :parse
)
if /i "%~1"=="--baud" (
    set "BAUD=%~2"
    shift & shift & goto :parse
)
if /i "%~1"=="-h" goto :usage
if /i "%~1"=="--help" goto :usage
rem  Bare argument: treat it as the COM port.
set "PORT=%~1"
shift & goto :parse

:parsed
if not exist "%BIN%" (
    echo [X] Firmware image not found: %BIN%
    echo.
    echo     Build it first:   build.bat
    echo     Or both at once:  build_and_flash.bat
    echo.
    pause
    exit /b 1
)

rem ==================================================================
rem  Find a Python interpreter, then esptool
rem ==================================================================
set "PYEXE="
if exist "%USERPROFILE%\.platformio\penv\Scripts\python.exe" (
    set "PYEXE=%USERPROFILE%\.platformio\penv\Scripts\python.exe"
) else (
    where python >nul 2>&1
    if !ERRORLEVEL! EQU 0 set "PYEXE=python"
)

set "ESPTOOL="
for /d %%D in ("%USERPROFILE%\.platformio\packages\tool-esptoolpy*" "%USERPROFILE%\.platformio\packages\tool-esptool*") do (
    if not defined ESPTOOL if exist "%%~fD\esptool.py" set "ESPTOOL=%%~fD\esptool.py"
    if not defined ESPTOOL if exist "%%~fD\esptool.exe" set "ESPTOOL=%%~fD\esptool.exe"
    if not defined ESPTOOL if exist "%%~fD\esptool" set "ESPTOOL=%%~fD\esptool"
)

set "ESPPREFIX="
if defined ESPTOOL (
    echo Found esptool: !ESPTOOL!
    if /i "!ESPTOOL:~-3!"==".py" (
        if not defined PYEXE goto :no_python
        set "ESPPREFIX="!PYEXE!" "!ESPTOOL!""
    ) else (
        set "ESPPREFIX="!ESPTOOL!""
    )
) else (
    if not defined PYEXE goto :no_python
    "!PYEXE!" -c "import esptool" >nul 2>&1
    if !ERRORLEVEL! NEQ 0 (
        echo esptool not found. Installing it now, please wait...
        "!PYEXE!" -m pip install --quiet --disable-pip-version-check esptool
    )
    "!PYEXE!" -c "import esptool" >nul 2>&1
    if !ERRORLEVEL! NEQ 0 goto :no_esptool
    set "ESPPREFIX="!PYEXE!" -m esptool"
)

set "PORTARG="
if not "!PORT!"=="" set "PORTARG=--port !PORT!"
if "!PORT!"=="" echo Port: auto-detect
if not "!PORT!"=="" echo Port: !PORT!

echo.
echo ============================================================
echo  cc_eye_tracker_vr - flashing
echo ============================================================
echo  image : %BIN%
echo  offset: 0x0
echo.
echo  If this fails, make sure the board is in download mode:
echo    hold BOOT, plug the USB-C cable in, release BOOT, then re-run.
echo.

%ESPPREFIX% --chip esp32s3 %PORTARG% --baud %BAUD% write_flash 0x0 "%BIN%"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" goto :fail

echo ============================================================
echo  [OK] FLASH OK
echo ============================================================
echo.
echo  Now: unplug from the PC, attach the OTG adapter + camera to the
echo  XIAO's USB-C port, and feed 5V (through a Schottky diode) into
echo  the 5V pin. See the Power section of README.md.
echo.
pause
exit /b 0

rem ------------------------------------------------------------------
:fail
echo ============================================================
echo  [X] Flashing failed - error code %RC%
echo ============================================================
echo.
echo  Check:
echo   - Did you hold BOOT while plugging the cable in?
echo   - Is the COM port correct? See Device Manager, Ports.
echo   - Is the camera / OTG adapter unplugged?
echo   - Try another USB cable; it must be a data cable.
echo   - Close any serial monitor holding the port open.
echo.
pause
exit /b 1

rem ------------------------------------------------------------------
:no_python
echo [X] No Python found.
echo.
echo     Easiest fix: install the PlatformIO or ESP-IDF extension in
echo     VS Code and let it finish installing, then run this file again.
echo.
echo     Or install Python from https://www.python.org/downloads/
echo     and tick "Add python.exe to PATH".
echo.
pause
exit /b 1

rem ------------------------------------------------------------------
:no_esptool
echo [X] Could not install esptool automatically.
echo.
echo     Fix it by hand. Open a terminal and run:
echo         "!PYEXE!" -m pip install esptool
echo.
echo     Or skip this script entirely and use the browser flasher,
echo     which needs no install:
echo         https://espressif.github.io/esptool-js/
echo.
echo     Or open the flash\ folder in VS Code (PlatformIO) and click
echo     "Flash cc_eye_tracker_vr firmware".
echo.
pause
exit /b 1

rem ------------------------------------------------------------------
:usage
echo Usage:
echo    flash.bat                  auto-detect the port
echo    flash.bat COM5             use a specific port
echo    flash.bat --port COM5
echo    flash.bat --bin other.bin
echo    flash.bat --baud 460800
exit /b 0
