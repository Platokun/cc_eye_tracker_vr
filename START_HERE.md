# cc_eye_tracker_vr

Custom **EyeTrackVR / OpenIris** firmware for the **Seeed Studio XIAO ESP32S3** that
uses a **USB eye-tracking camera on the USB-C port** instead of the built-in DVP camera.

Built on [OpenIris-ESPIDF](https://github.com/EyeTrackVR/OpenIris-ESPIDF) with a new
USB (UVC) host camera backend using Espressif's `usb_host_uvc` component.

---

## Quick start

### 1. Edit your settings

Open **`user_board.nzk.config`** and fill in your wifi:

```
WIFI_SSID=MyHomeWifi
WIFI_PASSWORD=MyWifiPassword

AP_SSID=EyeTrackVR
AP_PASSWORD=12345678

DEVICE_NAME=cc_eyetracker
```

* `WIFI_SSID` / `WIFI_PASSWORD` — your home router. The tracker joins it **automatically
  on boot**. This is the whole point of the file.
* `AP_SSID` / `AP_PASSWORD` — the fallback network the tracker creates *if* it can't join
  your wifi, so you can always get back in and fix things.
* `DEVICE_NAME` — the name it uses on the network and in the eye-tracking app.

Save the file. Nothing else to edit.

### 2. Build — and flash in the same step

**Windows**

```bat
build_and_flash.bat
```

At the end it asks `Flash it to the board now? (Y/N)`. Say **Y**, and when it tells you to,
hold `BOOT`, plug the USB-C cable into the PC, and release `BOOT`. That's it.

**Linux / macOS**

```bash
./build_and_flash.sh                    # build only
./build_and_flash.sh --flash /dev/ttyACM0   # build and flash
```

You need **ESP-IDF 5.4.x** installed once (see *Installing ESP-IDF* below). The first
build takes several minutes; after that it's fast.

The build also produces a standalone image you can flash any other way:

```
openiris_xiao_esp32s3_usb_cam_merged.bin
```

That single file is the complete firmware — flash it at offset **`0x0`**.

### 3. Alternative ways to flash the `.bin`

Put the board in download mode first:

> **Hold `BOOT` → plug the USB-C cable into the PC → release `BOOT`**

*(camera and OTG adapter unplugged — Windows should show a new COM port)*

Then either:

* **VS Code / PlatformIO** — open the `flash/` folder, then click
  `Project Tasks → xiao_esp32s3_usb_cam → Custom → "Flash cc_eye_tracker_vr firmware"`
* **Browser** — <https://espressif.github.io/esptool-js/> (Chrome/Edge), address `0x0`,
  pick the `.bin`
* **Command line** —
  `esptool.py --chip esp32s3 --port COM5 --baud 921600 write_flash 0x0 openiris_xiao_esp32s3_usb_cam_merged.bin`

---

## Hardware you need

| | |
|---|---|
| Board | Seeed XIAO ESP32S3 |
| Camera | USB (UVC) eye-tracking camera |
| Adapter | USB-C (male) → USB-A (female) **OTG** adapter |
| Power | **5 V** supply for the `5V` and `GND` pins |

### ⚠️ Power — this is the part that catches people out

The XIAO has **one USB-C port** and the camera now needs it, so **the board can no longer
be powered through that port**.

     Camera  ->  USB-C to USB-A OTG adapter  ->  camera
     Power   ->  5V and GND pins on the XIAO

The camera needs **5 V on VBUS**, and on the XIAO the `5V` pin is tied to the USB-C VBUS
pin. Feeding 5 V into the `5V` pin powers the board *and* the camera.

> **A 3.7 V battery will NOT work.** A bare LiPo gives ~3.7 V on VBUS, which is not enough
> for the camera. Use a USB power bank or a 5 V regulator.

If you also want to plug a PC into the port while external 5 V is connected, put a
Schottky diode in the 5 V feed (anode to your supply, cathode to the `5V` pin).

---

## How wifi behaves on boot

1. If you set `WIFI_SSID`, it tries that **first**, immediately.
2. If that fails, it tries wifi saved through the app.
3. If that fails too, it starts its own access point using `AP_SSID` / `AP_PASSWORD`.

Join the fallback AP from a phone or laptop, then configure the real network over the
device's REST interface.

Once on your network it is reachable at `http://<DEVICE_NAME>.local`
(default `cc_eyetracker.local`).

---

## Installing ESP-IDF (once)

You need ESP-IDF **5.4.x** to build.

**Windows, easiest route**

1. Install the **ESP-IDF** extension in VS Code.
2. Command Palette → `ESP-IDF: Configure ESP-IDF Extension` → **Express** install →
   version **v5.4.2**.
3. Open an **ESP-IDF Terminal** in VS Code and run `build_and_flash.bat`.

**Linux / macOS**

```bash
mkdir -p ~/esp && cd ~/esp
git clone -b v5.4.2 --recursive https://github.com/espressif/esp-idf.git
cd esp-idf && ./install.sh esp32s3
. ./export.sh
```

`build_and_flash.sh` also tries `~/esp/esp-idf`, `~/esp-idf` and `/opt/esp-idf`
automatically, and `$IDF_PATH` if it is set.

---

## What is different from stock OpenIris-ESPIDF

| File | Change |
|---|---|
| `components/UsbUvcCamera/` | **new** — USB host + UVC class driver, exposes frames as `camera_fb_t` |
| `components/CameraManager/` | selects between the DVP sensor and the USB camera |
| `components/StreamServer/`, `components/UVCStream/` | take frames from `cameraHandler->getFrame()` |
| `boards/seed_studio/xiao_esp32s3_usb_cam` | **new** board profile (USB camera input) |
| `main/Kconfig.projbuild` | `GENERAL_INCLUDE_UVC_MODE` unavailable when USB camera input is on |
| `tools/apply_user_config.py` | **new** — turns `user_board.nzk.config` into firmware settings |
| `flash/` | **new** — one-click PlatformIO flasher for the prebuilt image |
| `docs/USB_CAMERA_HOST.md` | full technical write-up |

### Why the USB port can't do double duty

The ESP32-S3 has **one USB PHY** shared by the USB-OTG and USB-Serial-JTAG controllers,
and only one can be active at a time. While the camera owns the port as a USB **host**:

* the board cannot also appear as a USB **device** (no USB webcam output, no USB serial)
* the serial console moves to **UART0** (`GPIO43` TX / `GPIO44` RX, 115200)
* **to flash again later you must always hold `BOOT` and replug** — the running firmware
  will never show up as a COM port

This is enforced in Kconfig, so those two modes cannot be selected together.

---

## Performance expectations

The ESP32-S3's USB controller is **USB 1.1 Full-Speed (12 Mbit/s)**, so roughly
**0.9 MB/s** of usable video. The camera's "120 fps" only happens at small resolutions.

| Mode | Achievable fps |
|---|---|
| 240×240 MJPEG | **60–120** ← default |
| 320×240 MJPEG | 30–60 |
| 640×480 MJPEG | 15–30 |
| uncompressed YUY2 | far too slow |

240×240 is EyeTrackVR's native size. Change `CAMERA_UVC_WIDTH` / `HEIGHT` / `FPS` in
`menuconfig` if needed — the camera's supported modes are printed in the log at every
connect.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| "waiting for a UVC camera..." forever | camera not getting 5 V on VBUS |
| No `[USB_CAM]` log output at all | console is UART0 now, not USB serial |
| `uvc_host_stream_open failed` | requested resolution/fps/format not advertised |
| Very low fps | uncompressed mode, or resolution too high |
| Can't flash | hold `BOOT`, replug; unplug the camera first |
| Config file errors | run `python tools/apply_user_config.py --check` |

Full detail: [`docs/USB_CAMERA_HOST.md`](docs/USB_CAMERA_HOST.md)

---

## Licence / credits

Firmware based on [OpenIris](https://github.com/EyeTrackVR/OpenIris) by the EyeTrackVR
project. USB host camera backend added here. ESP-IDF components retain their own licences.
