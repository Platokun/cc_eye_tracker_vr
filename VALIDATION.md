# Validation record

What was actually checked for this repository, how, and what could not be checked.

Nothing in this file is copied from another document — every line is the result of running
something or reading the source.

---

## Environment

| | |
|---|---|
| Host | Linux x86_64, workspace on an NFS mount |
| ESP-IDF | **v5.4.2** (`esp-idf/version.txt`) |
| Toolchain | `xtensa-esp-elf` `esp-14.2.0_20241119` |
| Python | 3.14.7 (ESP-IDF virtualenv) |
| CMake | 4.4.4 |
| esptool | 4.12.0 (bundled with the ESP-IDF env) |
| PlatformIO Core | 6.2.0 with `platform-espressif32` **7.1.3** |
| Hardware on hand | **none** — no XIAO ESP32S3, no USB camera, no serial adapter |

---

## 1. The firmware builds

Ran from a clean state with the repository's own board profile:

```bash
python tools/apply_user_config.py
export SDKCONFIG_DEFAULTS="boards/sdkconfig.base_defaults;boards/seed_studio/xiao_esp32s3_usb_cam;boards/generated/user_config"
idf.py -B /tmp/ccbuild2 set-target esp32s3
idf.py -B /tmp/ccbuild2 build
```

**Result:** `idf.py build` exit 0, **0 errors**, 1165/1165 targets.
App image `0x158d80` bytes, 29 % of the 0x1e0000 app partition free.
Merged image written: `openiris_xiao_esp32s3_usb_cam_merged.bin`, **1 412 480 bytes**.

Note: the build was done into `/tmp` rather than the repository directory on purpose — see
§6, *Build-system gotcha*.

## 2. The merged image is a real, flashable factory image

Parsed the produced file directly:

| Check | Result |
|---|---|
| Byte 0 | `0xE9` — ESP image magic, so the bootloader is at offset `0x0` ✅ |
| App descriptor at `0x10020` | magic `0xABCD5432` ✅ |
| `idf_ver` in descriptor | `v5.4.2` ✅ |
| Partition table at `0x8000` | `nvs`, `otadata`, `app0`@0x10000, `app1`@0x1f0000, `spiffs`, `coredump` ✅ |
| Contains `[USB_CAM]` | yes — the USB camera backend is in the image ✅ |
| Contains `xiao_esp32s3_usb_cam` | yes — the board profile was applied ✅ |
| Contains `cc_eyetracker` | yes — `DEVICE_NAME` from `user_board.nzk.config` reached the image ✅ |
| Contains `USB camera input active` | yes — the new serial-manager guard is in the image ✅ |

## 3. Effective configuration

Read back from the generated `sdkconfig`:

```
CONFIG_CAMERA_INPUT_USB_UVC=y          <- USB UVC camera is the active input
CONFIG_CAMERA_UVC_WIDTH=240
CONFIG_CAMERA_UVC_HEIGHT=240
CONFIG_CAMERA_UVC_FPS=60
CONFIG_START_IN_WIFI_MODE=y            <- added by this work
CONFIG_GENERAL_ADVERTISED_NAME="cc_eyetracker"
CONFIG_GENERAL_BOARD="xiao_esp32s3_usb_cam"
CONFIG_GENERAL_ENABLE_WIRELESS=y
CONFIG_ESP_CONSOLE_UART_DEFAULT=y / CONFIG_ESP_CONSOLE_UART_NUM=0
# CONFIG_GENERAL_INCLUDE_UVC_MODE is not set
# CONFIG_USJ_ENABLE_USB_SERIAL_JTAG is not set
```

(The build log additionally confirms the Kconfig `depends on !CAMERA_INPUT_USB_UVC` is what
removes `GENERAL_INCLUDE_UVC_MODE`.)

## 4. Code-level findings that were checked by reading the source

| Claim | Verdict | Evidence |
|---|---|---|
| USB camera frames reach the Wi-Fi stream | **true** | `StreamServer::stream()` calls `cameraHandler->getFrame()`; `CameraManager::getFrame()` returns `usbCamera->getFrame(1000)` when `CONFIG_CAMERA_INPUT_USB_UVC` |
| mDNS hostname / stream port / API port | **true** | `MDNSManager` publishes `stream_port=80`, `api_port=81`, hostname from `ProjectConfig` |
| Boot with no host command | **false before this work, true now** | `DeviceMode_t::load()` defaulted to `SETUP`, and `startWiFiMode()` only calls `startStreamServer()` when the mode is `WIFI`, so the stream server never started on first boot while the log claimed *"WiFi streaming will be enabled still"*. Added `START_IN_WIFI_MODE` and enabled it in this board profile. |
| Serial manager is safe to leave running while the USB host owns the PHY | **false before this work, fixed now** | `SerialManager_esp32s3.cpp` unconditionally installed the USB-Serial-JTAG driver on ESP32-S3. `usb_serial_jtag_driver_install()` calls `usb_serial_jtag_ll_phy_enable_pad(true)` / `usb_serial_jtag_ll_phy_set_defaults()` on the **shared** FSLS PHY, after the USB host stack had already claimed it. `CONFIG_USJ_ENABLE_USB_SERIAL_JTAG` only gates the peripheral *clock*, it does not stop the runtime install. Upstream OpenIris uninstalls this driver before handing the port to USB (`startWiredMode()`), which this board never did. Now the driver is never installed on this board, and the serial task is not started. |
| Wi-Fi password is not logged | **false before this work, fixed now** | `WiFiManager::SetCredentials()` logged the plaintext PSK with `ESP_LOGI`. Now logs `<set>`/`<empty>` |
| `tools/apply_user_config.py --check` writes nothing | **false before this work, fixed now** | It wrote `boards/generated/user_config` regardless of `--check`. Now it really does not write (verified: file absent after `--check`, exit 0) |

## 5. PlatformIO / VS Code flasher

PlatformIO Core 6.2.0 was installed and the shipped `platformio.ini` + `extra_scripts.py` were
run for real against `platform-espressif32` 7.1.3. This found three genuine defects, all fixed:

1. **`upload_port = auto` is not a PlatformIO value.** It is not a glob, so
   `AutodetectUploadPort()` treats it as an explicitly-requested port and esptool is handed
   `--port auto`. Removed; the port is left to auto-detection.
2. **No `framework` declared → the platform builder crashes.** espressif32 7.x runs
   `if "espidf" in env.get("PIOFRAMEWORK")`; `esp32-s3-devkitc-1` supports both arduino and
   espidf, so with no `framework` set `PIOFRAMEWORK` is `None` and PlatformIO dies with
   `TypeError: argument of type 'NoneType' is not a container or iterable`. Added
   `framework = arduino`.
3. **`build_src_filter = -<*>` with no `src/` makes a plain `pio run` fail** with
   *"Nothing to build"*. Added `targets = flash_openiris`.
4. **A failed flash was reported as `[SUCCESS]`.** `env.Execute()` returns esptool's exit
   status but does not fail the SCons build, so PlatformIO printed
   `======================== [SUCCESS] ...` immediately after
   `A fatal error occurred: Could not connect to an Espressif device`. Now the status is
   checked and `env.Exit(status)` is called, so a failed flash ends with `[FAILED]`.

Also hardened: `always_build=False` dropped (a flasher should always run); esptool discovery
now also handles the future `tool-esptool` standalone-binary layout in addition to
`tool-esptoolpy/esptool.py`; `--port` is omitted so esptool auto-detects.

**Verified result** (no hardware attached, so esptool is expected to stop at
"Found 0 serial ports" — that is the proof the plumbing is right):

| Run | Result |
|---|---|
| `pio run` (plain) | runs `flash_openiris`, **no "Nothing to build"** ✅ |
| `pio run --list-targets` | shows `xiao_esp32s3_usb_cam / Custom / flash_openiris` ✅ |
| `pio run -t flash_openiris` | invokes `tool-esptoolpy/esptool.py --chip esp32s3 --baud 921600 write_flash 0x0 "<image>"` ✅ |
| repository `flash/` project | resolves `../openiris_xiao_esp32s3_usb_cam_merged.bin` ✅ |
| flash with no board | reports **`[FAILED]`** and propagates the exit status ✅ |

It was also confirmed that a first run downloads the ESP32 toolchains, openocd, the Arduino
framework and esptool — several hundred MB — even though nothing is compiled. The shipped
READMEs state this; the earlier README claimed the opposite ("nothing extra is downloaded").

## 6. Build-system gotcha (not a repository defect, but it cost an hour)

The first build attempt failed inside `idf.py set-target` with
*"Directory '…/build' doesn't seem to be a CMake build directory. Refusing to automatically
delete files in this directory."* and the second with
*"ninja: warning: premature end of file; recovering"* followed by dozens of
*"opening dependency file …: No such file or directory"* errors.

Cause: this workspace is an **NFS mount**, and `rm -rf build` on NFS returns before the server
has finished deleting. The freshly-started build then had its files removed underneath it
(the giveaway was `.nfs*` silly-rename files held open in `build/log`). Both failures
disappeared completely once the build was done into a local directory with `idf.py -B <dir>`,
and the final build was clean. A clean local build was also produced earlier in the same
environment, so the toolchain itself is fine.

This is documented in `README.md` and `docs/USB_CAMERA_HOST.md` so it does not surprise
anyone else.

## 7. Raw PlatformIO run

See `VALIDATION-platformio.txt` next to this file for the unedited output of:

```
pio run                                 # plain, must not "Nothing to build"
pio run --list-targets                  # must show the Custom target
pio run -t flash_openiris               # must invoke esptool on the image
```

## 8. What could NOT be verified (no hardware)

These require a physical XIAO ESP32S3, a USB UVC camera and a 5 V supply:

* that a real camera enumerates and streams at 240×240 MJPEG;
* the actual achievable frame rate;
* that the shared-PHY change (§4) fixes or even affects camera enumeration on real silicon —
  the fix is correct by construction and removes a known conflict, but the before/after
  cannot be demonstrated here;
* that the Wi-Fi join / fallback AP / mDNS sequence behaves as the code reads;
* that the REST endpoints answer as expected over the air;
* the power arrangement (Schottky diode drop, boost module behaviour, current draw).

The power facts in the documentation come from the Seeed XIAO ESP32S3 schematic and wiki (see
`docs/USB_CAMERA_HOST.md` §2.2), not from measurement.

## 9. Deliverable checks

* `cc_eye_tracker_vr_flash_kit_windows.zip` and `cc_eye_tracker_vr_vscode_flash.zip` — rebuilt
  from the post-fix firmware and documentation. Both pass `unzip -t`, and the `.bin` inside
  each is byte-identical (`sha256 41f6dda2…e617`, 1 412 480 bytes) to the merged image built
  in §1 and to the copy in the repository root.
* The two earlier archives, `OpenIris_flash_kit_windows.zip` and
  `OpenIris_vscode_flash_project.zip`, contain the **pre-fix** firmware and the **incorrect**
  documentation. They pass `unzip -t` but are superseded; they are removed so there is only
  one firmware image in the workspace.
* `windows_flash/flash.bat` and the two `extra_scripts.py` copies build a command line that
  was executed for real (see §5) — the exact esptool invocation is in
  `VALIDATION-platformio.txt`.
* `python3 -m py_compile` passes on `extra_scripts.py` (both copies) and
  `tools/apply_user_config.py`.
* `tools/apply_user_config.py --check` was run and confirmed to write nothing (exit 0, no
  `boards/generated/user_config` created).
