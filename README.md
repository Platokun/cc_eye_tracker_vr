# cc_eye_tracker_vr

Firmware for a **Seeed Studio XIAO ESP32S3** eye tracker that takes its video from a
**USB (UVC) camera plugged into the USB-C port** instead of the built-in DVP camera, and
streams it to the eye-tracking host **over Wi-Fi**.

Built on [EyeTrackVR/OpenIris-ESPIDF](https://github.com/EyeTrackVR/OpenIris-ESPIDF) with a
USB host camera backend using Espressif's `usb_host_uvc` component.

* Deep technical write-up: [`docs/USB_CAMERA_HOST.md`](docs/USB_CAMERA_HOST.md)
* What was built and tested, and what wasn't: [`VALIDATION.md`](VALIDATION.md)

---

## Contents

1. [What you need](#1-what-you-need)
2. [Power — read this first](#2-power--read-this-first)
3. [Flash the firmware](#3-flash-the-firmware)
4. [First boot, Wi-Fi and watching the video](#4-first-boot-wi-fi-and-watching-the-video)
5. [Build it yourself](#5-build-it-yourself)
6. [Scripts](#6-scripts)
7. [Repository layout](#7-repository-layout)
8. [How it works](#8-how-it-works)
9. [Performance expectations](#9-performance-expectations)
10. [LED status patterns](#10-led-status-patterns)
11. [Troubleshooting](#11-troubleshooting)
12. [Licence](#12-licence)

---

## 1. What you need

| | |
|---|---|
| Board | Seeed Studio **XIAO ESP32S3** |
| Camera | A **USB (UVC)** camera — *not* a DVP/ribbon camera |
| Adapter | USB-C (male) → USB-A (female) **OTG** adapter |
| Power | a **5 V** supply — see below |
| To build firmware | ESP-IDF **v5.4.2** (not needed just to flash) |

---

## 2. Power — read this first

The XIAO has **one USB-C port**, and the camera now needs it. The camera is powered from that
port's **VBUS**, and the XIAO is the USB **host**, so something must *supply* 5 V on it.
The ESP32-S3 cannot: it has no VBUS pin and no boost converter.

On the XIAO ESP32S3 the `5V` pin is **wired directly to the USB-C VBUS pin** — no diode, no
switch. So:

* **Feed 5 V into the `5V` pin** (GND into `GND`) and both the board and the camera are
  powered. This is the supported way to run it.
* **A bare 3.7 V LiPo on the `BAT` pads will not work.** There is no boost converter, so on
  battery-only power there is **0 V on the `5V` pin** and the camera never powers up. The
  board itself boots fine — the camera just stays dark.

```
Camera ──▶ [ USB-C OTG adapter ] ──▶ XIAO USB-C
5 V source ──▶ Schottky diode ──▶ XIAO "5V" pin   (anode to source, cathode to 5V)
GND ────────────────────────────▶ XIAO "GND" pin
```

> ⚠️ **The series Schottky diode is required, not optional.** Seeed's own documentation says a
> diode must sit between your external supply and the `5V` pin (anode to your supply, cathode
> to the pin) — the board does not have one. It stops your supply from fighting USB VBUS if a
> cable is ever plugged in. Any 1 A+ Schottky (1N5819, SS34, …) works. It drops roughly
> 0.3–0.5 V, so the camera sees ~4.5–4.7 V, which USB cameras normally tolerate.

**Power options that work**

| Option | How |
|---|---|
| **USB power bank** | Easiest: 5 V out → diode → `5V` pin. |
| **1S LiPo + 5 V boost** | LiPo → 3.7 V→5 V boost (≥1 A; IP5306/FM5324GA-class modules are typical) → diode → `5V` pin. |
| **Self-powered USB hub** | XIAO USB-C → hub upstream, camera → hub downstream. The hub's own PSU supplies VBUS, so nothing is injected into the `5V` pin. Only works if the hub back-powers its upstream port — not all do. |

Budget **~1 A at 5 V**: the board takes roughly 0.15–0.35 A and the camera typically
100–500 mA.

---

## 3. Flash the firmware

You flash **one file**:

```
out/openiris_xiao_esp32s3_usb_cam_merged.bin
```

It contains bootloader + partition table + OTA data + application, so it is written at
**offset `0x0`**. Get it by:

* downloading the **`cc_eye_tracker_vr-firmware`** artifact from the latest CI run
  (Actions → *Build firmware*), or from the release page for a tag;
* taking it from the `cc_eye_tracker_vr_flash_kit_windows.zip` / `cc_eye_tracker_vr_vscode_flash.zip`
  kit; or
* running [`./build.sh`](#5-build-it-yourself) yourself.

### Put the board in download mode first

> **Hold `BOOT` → plug the USB-C cable into the PC → release `BOOT`.**
>
> Camera and OTG adapter **unplugged**.

The running firmware never appears as a COM port — the USB port belongs to the camera. This
is expected, and holding `BOOT` is how you get back in every time you reflash.

### Then pick any route

| Route | How |
|---|---|
| **Windows, double-click** | `flash.bat` — press Enter to auto-detect the port. Uses PlatformIO's esptool if present, otherwise installs esptool with pip. |
| **Linux / macOS** | `./flash.sh` (add `--port /dev/ttyACM0` if auto-detect picks wrong) |
| **Browser** | <https://espressif.github.io/esptool-js/> (Chrome/Edge only), address `0x0`, pick the `.bin`. Nothing to install. |
| **PlatformIO / VS Code** | Open the `flash/` folder, then `Project Tasks → xiao_esp32s3_usb_cam → Custom → "Flash cc_eye_tracker_vr firmware"`. Nothing is compiled; PlatformIO is only an esptool runner. |
| **Command line** | `esptool.py --chip esp32s3 --port COM5 --baud 921600 write_flash 0x0 out/openiris_xiao_esp32s3_usb_cam_merged.bin` |

To build **and** flash in one go, use `build_and_flash.sh` / `build_and_flash.bat`.

---

## 4. First boot, Wi-Fi and watching the video

The firmware boots straight into **Wi-Fi streaming mode** — there is no serial console to
configure it with, because the USB port is the camera bus.

On boot it tries, in order:

1. the Wi-Fi compiled in from `user_board.nzk.config`;
2. any network stored through the app / REST API;
3. otherwise it raises its own access point.

In every case the stream server starts on port 80 and mDNS comes up.

**With no Wi-Fi configured (the default in the shipped image):**

* the board creates **SSID `EyeTrackVR`, password `12345678`**;
* join that from a phone or laptop;
* open **<http://cc_eyetracker.local/>** (or `http://192.168.4.1/`).

That page **is** the live MJPEG stream. If you can see it, the USB camera input and the Wi-Fi
path are both working.

### Putting it on your own network

**Bake it in (recommended).** Edit `user_board.nzk.config` and rebuild:

```
WIFI_SSID=MyHomeWifi
WIFI_PASSWORD=MyWifiPassword
AP_SSID=EyeTrackVR
AP_PASSWORD=12345678
DEVICE_NAME=cc_eyetracker
```

Validate the file without writing anything:

```bash
python tools/apply_user_config.py --check
```

**At runtime.** The firmware serves a REST API on **port 81**:

```bash
curl -X POST http://cc_eyetracker.local:81/api/set/wifi/ \
     -d '{"name":"main","ssid":"MyWifi","password":"secret","channel":0,"power":0}'
curl -X POST http://cc_eyetracker.local:81/api/set/config/save/
curl -X POST http://cc_eyetracker.local:81/api/set/wifi/connect/
```

The EyeTrackVR host application uses the same API, so if you use the app you do not need
`curl`.

`DEVICE_NAME` sets the mDNS name, so the tracker answers at
`http://<DEVICE_NAME>.local` — `cc_eyetracker.local` by default.

### Watching the logs

The console is **UART0**: `GPIO43` = TX (`D6` pad), `GPIO44` = RX (`D7` pad), **115200 baud**.
A 3.3 V USB-serial adapter on those two pads shows the boot log, the camera's advertised modes
and any errors. The on-board LED mirrors the state too (see [§10](#10-led-status-patterns)).

---

## 5. Build it yourself

You need **ESP-IDF v5.4.2** installed once. The build scripts look for `idf.py` on `PATH` and
then in `$IDF_PATH`, `~/esp/esp-idf`, `~/esp-idf`, `/opt/esp-idf`, `C:\Espressif\frameworks\esp-idf-v5.4.2`.

**Linux / macOS**

```bash
./build.sh                # build only  -> out/openiris_xiao_esp32s3_usb_cam_merged.bin
./flash.sh                # flash what was built
./build_and_flash.sh      # both, with a pause to enter download mode
```

**Windows** — from an ESP-IDF terminal, or just double-click:

```bat
build.bat
flash.bat
build_and_flash.bat
```

The build regenerates `sdkconfig` from the board profile, builds, and merges everything into
the single image under `out/`. **The first build takes several minutes**; later ones are much
faster.

### Installing ESP-IDF (once)

**Windows, easiest route**

1. Install the **ESP-IDF** extension in VS Code.
2. Command Palette → `ESP-IDF: Configure ESP-IDF Extension` → **Express** install → version
   **v5.4.2**.
3. Open an **ESP-IDF Terminal** in VS Code and run `build.bat`.

**Linux / macOS**

```bash
mkdir -p ~/esp && cd ~/esp
git clone -b v5.4.2 --recursive https://github.com/espressif/esp-idf.git
cd esp-idf && ./install.sh esp32s3
. ./export.sh
```

### Manual build, without the scripts

```bash
python tools/apply_user_config.py
export SDKCONFIG_DEFAULTS="boards/sdkconfig.base_defaults;boards/seed_studio/xiao_esp32s3_usb_cam;boards/generated/user_config"
rm -f sdkconfig sdkconfig.old
idf.py set-target esp32s3
idf.py build
idf.py merge-bin -o out/openiris_xiao_esp32s3_usb_cam_merged.bin
```

> `boards/generated/user_config` is generated from `user_board.nzk.config` and is gitignored,
> so it must be regenerated on a fresh clone. Omit it from `SDKCONFIG_DEFAULTS` if you would
> rather configure Wi-Fi at runtime through the access point.

---

## 6. Scripts

All of them live in the repository root and work on both Windows (`.bat`) and
Linux/macOS (`.sh`).

| Script | What it does |
|---|---|
| `build.sh` / `build.bat` | Reads `user_board.nzk.config`, builds the firmware, writes `out/openiris_xiao_esp32s3_usb_cam_merged.bin`. `--config-only` just validates the config. |
| `flash.sh` / `flash.bat` | Writes the image in `out/` to the board at offset `0x0`. Safe to run repeatedly — this is how you reflash. |
| `build_and_flash.sh` / `build_and_flash.bat` | Runs build, then pauses so you can enter download mode, then runs flash. |

Useful options:

```bash
./build.sh --config-only              # validate user_board.nzk.config only
./flash.sh --port /dev/ttyACM0        # pick the serial port
./flash.sh --bin out/other.bin        # flash a different image
./flash.sh --baud 460800              # slower, if 921600 is unreliable
```

```bat
build.bat --config-only
flash.bat COM5
flash.bat --bin out\other.bin
```

`flash.sh` / `flash.bat` find esptool in this order: `esptool.py` on `PATH` → the `esptool`
Python module → PlatformIO's bundled copy → (Windows) install it with pip.

---

## 7. Repository layout

```
README.md                      this file - the only readme
VALIDATION.md                  what was built and tested, and how
VALIDATION-platformio.txt      raw output from the PlatformIO checks
user_board.nzk.config          the one file you edit: Wi-Fi, fallback AP, device name

build.sh / build.bat           build        -> out/
flash.sh / flash.bat           flash out/   (reflash any time)
build_and_flash.sh / .bat      both

out/                           build output (gitignored)

flash/                         PlatformIO project that only *flashes* the built image
docs/USB_CAMERA_HOST.md        deep technical write-up of the USB camera backend

boards/seed_studio/
  xiao_esp32s3_usb_cam         the USB-camera board profile  <- used by the build
  xiao_esp32s3                 stock DVP-camera profile (kept for switching back)
components/
  UsbUvcCamera/                USB host + uvc_host wrapper, frames as camera_fb_t
  CameraManager/               picks the DVP sensor or the USB camera
  StreamServer/                MJPEG HTTP stream over Wi-Fi
  UVCStream/                   USB-webcam output path (compiled out on this board)
  SerialManager/               serial command channel (inert on this board)
tools/                         apply_user_config.py, board switcher, setup CLI
managed_components/            vendored esp32-camera, usb_host_uvc, tinyusb, mdns, ...
.github/workflows/build.yml    prebuild on push, artifact + release
```

---

## 8. How it works

`CONFIG_CAMERA_INPUT_USB_UVC=y` (set in the board profile) switches the firmware from the DVP
camera to a USB UVC camera. Everything downstream is unchanged:

```
USB camera ─▶ usb_host_uvc ─▶ UsbUvcCamera (camera_fb_t)
                                      │
                         CameraManager::getFrame()
                                      │
                            StreamServer (port 80) ─▶ HTTP MJPEG
```

### Why the USB port cannot do two jobs

The ESP32-S3 has **one USB PHY** on GPIO19/GPIO20 — the same pins as the USB-C connector —
shared by the USB-OTG and USB-Serial-JTAG controllers. Only one can be active at a time.
While the camera owns the port as a USB **host**:

* the board cannot also be a USB **device** (no USB webcam output, no USB serial console);
* `CONFIG_GENERAL_INCLUDE_UVC_MODE` is unavailable by Kconfig rule, so the USB-device mode
  cannot even be selected;
* the console moves to **UART0** (`GPIO43` TX / `GPIO44` RX, 115200);
* the firmware **never installs the USB-Serial-JTAG driver**, leaving the PHY entirely to the
  camera host;
* **to flash again you must hold `BOOT` and replug.**

### Why it boots into Wi-Fi mode

`CONFIG_START_IN_WIFI_MODE=y` is set in this board profile. Without it the device would boot
into `SETUP` mode and wait for a "switch to Wi-Fi" command — which on this board could only
arrive over the serial console that does not exist. In Wi-Fi mode it joins the network (or
raises the fallback AP) and starts the stream server immediately.

### Camera tuning

`menuconfig` → *OpenIris: USB Camera (UVC host) Configuration*:
`CAMERA_UVC_VID`/`PID`, `CAMERA_UVC_FORMAT_MJPEG`/`YUY2`,
`CAMERA_UVC_WIDTH`/`HEIGHT`/`FPS`, `CAMERA_UVC_BUFFER_COUNT`, `CAMERA_UVC_URB_COUNT`,
`CAMERA_UVC_JPEG_QUALITY`.

The camera's advertised modes are printed in the UART log on every connect. Request one that
is actually in that list, otherwise the driver falls back to the device default and says so.

### Switching back to the on-board camera

Set `CONFIG_CAMERA_INPUT_USB_UVC=n` (or use the `seed_studio/xiao_esp32s3` board profile) and
re-enable `CONFIG_GENERAL_INCLUDE_UVC_MODE` if you want USB-webcam output again. The DVP pin
map is kept in the board profile.

---

## 9. Performance expectations

The ESP32-S3's USB controller is **USB 1.1 Full-Speed (12 Mbit/s)**, so roughly **0.9 MB/s**
of usable video. A camera's "120 fps" only happens at small resolutions.

| Mode | Achievable fps |
|---|---|
| 240×240 MJPEG | **60–120** ← default |
| 320×240 MJPEG | 30–60 |
| 640×480 MJPEG | 15–30 |
| uncompressed YUY2 | far too slow |

240×240 is EyeTrackVR's native size and is what this profile requests. Uncompressed modes are
effectively unusable over Full-Speed USB.

---

## 10. LED status patterns

The on-board LED (GPIO21) mirrors device state.

| State | Pattern | Meaning |
|---|---|---|
| idle | off | nothing running |
| streaming | steady on | streaming active over Wi-Fi |
| stopped | steady off | streaming intentionally stopped |
| camera error | 300/300, 300/700 | camera init/runtime failure |
| Wi-Fi connecting | 400/400 | associating / waiting for DHCP |
| Wi-Fi connected | 150/150 ×3, then 600 off | connected |
| Wi-Fi error | 200/100, 500/300 | auth timeout / no access point |

---

## 11. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "waiting for a UVC camera…" forever in the UART log | Camera is not getting 5 V on VBUS — see [§2](#2-power--read-this-first) |
| No log output at all | Console is UART0 now, not USB serial — see [§4](#watching-the-logs) |
| No `EyeTrackVR` Wi-Fi appears | Board not booting or not powered; check the LED |
| Video page doesn't load | Confirm you joined `EyeTrackVR`, then try `http://192.168.4.1/` |
| Can't flash / no COM port | Hold `BOOT`, replug; unplug the camera and OTG adapter first |
| `uvc_host_stream_open failed` | Requested resolution/fps/format is not advertised — read the logged mode list |
| Very low fps | Uncompressed YUY2 selected, or resolution too high |
| `user_board.nzk.config` errors | `python tools/apply_user_config.py --check` |
| PlatformIO says "Nothing to build" | Use the `flash_openiris` custom target (`pio run -t flash_openiris`) |
| PlatformIO "Project Configuration" takes ages on first run | It is downloading the ESP32 platform packages (several hundred MB, once) |

---

## 12. Licence

Firmware based on [OpenIris](https://github.com/EyeTrackVR/OpenIris) and
[OpenIris-ESPIDF](https://github.com/EyeTrackVR/OpenIris-ESPIDF) by the EyeTrackVR project.
The USB host camera backend is added here. Bundled ESP-IDF components retain their own
licences.
