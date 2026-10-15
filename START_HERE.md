# cc_eye_tracker_vr

Custom **EyeTrackVR / OpenIris** firmware for a **Seeed Studio XIAO ESP32S3** that takes its
camera input from a **USB (UVC) eye-tracking camera plugged into the USB-C port** instead of
the built-in DVP camera, and streams the video to your PC **over Wi-Fi**.

Built on [OpenIris-ESPIDF](https://github.com/EyeTrackVR/OpenIris-ESPIDF) with a new USB
(UVC) host camera backend using Espressif's `usb_host_uvc` component.

> **Everything in this document was checked against the actual source and against a real
> build of this repository (ESP-IDF v5.4.2, `idf.py build`, 0 errors). Where a claim could
> only be checked on hardware, it is marked. See [`VALIDATION.md`](VALIDATION.md).**

---

## What you need

| | |
|---|---|
| Board | Seeed Studio **XIAO ESP32S3** |
| Camera | A **USB (UVC)** camera — *not* a DVP/ribbon camera |
| Adapter | USB-C (male) → USB-A (female) **OTG** adapter |
| Power | see below |

---

## Power: read this before you wire anything

The XIAO has **one USB-C port**, and the camera now needs it. So the camera is powered from
the XIAO's USB-C **VBUS** pin, and the XIAO is the USB **host** — something has to *supply*
5 V on that pin. The ESP32-S3 itself does not: it has no VBUS pin and no boost converter.

On the XIAO ESP32S3 the `5V` pin is **directly tied to the USB-C VBUS pin** — there is no
diode or switch in between. That gives you two facts you must design around:

1. **Feed 5 V into the `5V` pin** (GND into `GND`) and both the board and the camera get
   power. This is the supported way to run it.
2. **A bare 3.7 V LiPo on the `BAT` pads will not work.** The board has no boost converter,
   so with battery-only power there is **0 V on the `5V` pin** and the camera never powers
   up. The board itself boots fine — the camera just stays dark.

```
Camera ──▶ [ USB-C OTG adapter ] ──▶ XIAO USB-C
5 V source ──▶ Schottky diode ──▶ XIAO "5V" pin   (anode to source, cathode to 5V)
GND ────────────────────────────▶ XIAO "GND" pin
```

> ⚠️ **The series Schottky diode is required, not optional.** Seeed's own documentation says
> you must have a diode between your external supply and the `5V` pin (anode to your supply,
> cathode to the pin) — the board does not have one. It stops your supply from fighting USB
> VBUS if a cable is ever plugged in. Any 1 A+ Schottky (1N5819, SS34, …) will do. It drops
> roughly 0.3–0.5 V, so the camera sees ~4.5–4.7 V, which USB cameras normally tolerate.

**Battery options that work**

| Option | How |
|---|---|
| **USB power bank** | Easiest: 5 V out → diode → `5V` pin. Also gives you a clean 5 V rail. |
| **1S LiPo + 5 V boost module** | LiPo → 3.7 V→5 V boost (≥1 A, IP5306/FM5324GA-class modules are typical) → diode → `5V` pin. |
| **Self-powered USB hub** | XIAO USB-C → hub upstream, camera → hub downstream. The hub's own PSU supplies VBUS, so nothing is injected into the `5V` pin at all. Only works if the hub back-powers its upstream port — not all do. |

Budget **~1 A at 5 V**: the board takes ~0.15–0.35 A and the camera typically 100–500 mA.

> Do not also plug the USB-C into a PC while external 5 V is connected — with the single
> VBUS node the two supplies would fight (the diode above is what prevents this).


---

## Quick start

### 1. Flash the board

You need the single merged image:

```
openiris_xiao_esp32s3_usb_cam_merged.bin
```

It contains bootloader + partition table + OTA data + application, so it is written at
**offset `0x0`**.

**Put the board into download mode first:**

> **Hold `BOOT` → plug the USB-C cable into the PC → release `BOOT`.**
>
> Camera and OTG adapter **unplugged**. The running firmware never appears as a COM port,
> because the USB port belongs to the camera — this is expected, and `BOOT` is how you get
> back in every time.

Then pick whichever route you like:

**A. Windows, double-click** — run `flash.bat` and press Enter to auto-detect the port.
Works with PlatformIO's bundled esptool, or installs esptool via pip if needed.

**B. Browser, nothing to install** — <https://espressif.github.io/esptool-js/>
(Chrome/Edge only), address `0x0`, pick the `.bin`.

**C. PlatformIO / VS Code** — open the `flash/` folder (or the
`cc_eye_tracker_vr_vscode_flash.zip` kit), then
`Project Tasks → xiao_esp32s3_usb_cam → Custom → "Flash cc_eye_tracker_vr firmware"`.
This does **not** compile anything; PlatformIO is used only as an esptool runner. The first
run downloads the ESP32 platform packages (a few hundred MB, once).

**D. Command line**

```bat
esptool.py --chip esp32s3 --port COM5 --baud 921600 write_flash 0x0 openiris_xiao_esp32s3_usb_cam_merged.bin
```

### 2. Power it and plug in the camera

Unplug the board from the PC, connect the OTG adapter + camera to the USB-C port, and feed
5 V into `5V`/`GND` (see *Power* above).

### 3. It comes up on Wi-Fi by itself

The firmware boots straight into **Wi-Fi streaming mode** — there is no serial console to
configure it with (the USB port is the camera bus). On first boot, with no Wi-Fi stored:

* It creates its own access point: **SSID `EyeTrackVR`, password `12345678`**.
* Join that from a phone or laptop.
* It is then reachable at **<http://cc_eyetracker.local/>** (or `http://192.168.4.1/`).

Open that address in a browser and you get the **MJPEG stream** — that is your live camera
view. If you can see it, the USB camera input and the Wi-Fi path are both working.

### 4. Put it on your real Wi-Fi (optional)

Two ways:

* **Bake it in at build time (recommended).** Edit `user_board.nzk.config`, then rebuild
  (§ *Building from source*). The device joins your network automatically on every boot.
* **At runtime, over the network.** The firmware serves a REST API on **port 81**
  (`http://<device-ip>:81`):

  ```bash
  # store the network
  curl -X POST http://cc_eyetracker.local:81/api/set/wifi/ \
       -d '{"name":"main","ssid":"MyWifi","password":"secret","channel":0,"power":0}'
  # save it
  curl -X POST http://cc_eyetracker.local:81/api/set/config/save/
  # connect now
  curl -X POST http://cc_eyetracker.local:81/api/set/wifi/connect/
  ```

  The EyeTrackVR host application does the same thing through this API, so if you are using
  the app you do not need the `curl` commands.

---

## Building from source

You need **ESP-IDF v5.4.2** installed once.

**Windows** (from an ESP-IDF terminal):

```bat
build_and_flash.bat
```

**Linux / macOS:**

```bash
./build_and_flash.sh                       # build only
./build_and_flash.sh --flash /dev/ttyACM0  # build and flash
```

The script applies `user_board.nzk.config`, builds, and writes a merged
`openiris_xiao_esp32s3_usb_cam_merged.bin` you can flash at `0x0`.

`user_board.nzk.config` is the only file you need to edit:

```
WIFI_SSID=MyHomeWifi
WIFI_PASSWORD=MyWifiPassword
AP_SSID=EyeTrackVR
AP_PASSWORD=12345678
DEVICE_NAME=cc_eyetracker
```

Validate it without writing anything:

```bash
python tools/apply_user_config.py --check
```

---

## How the Wi-Fi behaves on boot

1. **`WIFI_SSID` is set?** Try it immediately (8 s timeout).
2. Otherwise try any network stored through the app/REST API.
3. If none of that works, raise the fallback access point (`AP_SSID` / `AP_PASSWORD`).

In every case the stream server starts on port 80 and mDNS comes up, so the device is always
reachable. `/` is the MJPEG stream; port 81 is the REST API.

---

## Watching the logs

The USB port is the camera bus, so the console is **UART0**: `GPIO43` = TX (`D6` pad),
`GPIO44` = RX (`D7` pad), **115200 baud**. A 3.3 V USB-serial adapter on those two pads shows
everything. The on-board LED (GPIO21) mirrors the state.

---

## What is different from stock OpenIris-ESPIDF

| File | Change |
|---|---|
| `components/UsbUvcCamera/` | **new** — USB host + UVC class driver, exposes frames as `camera_fb_t` |
| `components/CameraManager/` | selects between the DVP sensor and the USB camera (`getFrame()` / `returnFrame()`) |
| `components/StreamServer/`, `components/UVCStream/` | take frames from `cameraHandler->getFrame()` |
| `components/SerialManager/` | **never installs the USB-Serial-JTAG driver** when the USB camera owns the PHY |
| `boards/seed_studio/xiao_esp32s3_usb_cam` | **new** board profile: USB camera input, Wi-Fi streaming by default |
| `main/Kconfig.projbuild` | `START_IN_WIFI_MODE` added; `GENERAL_INCLUDE_UVC_MODE` unavailable when USB camera input is on |
| `tools/apply_user_config.py` | **new** — turns `user_board.nzk.config` into firmware settings |
| `flash/` | **new** — one-click PlatformIO/esptool flasher for the prebuilt image |
| `docs/USB_CAMERA_HOST.md` | full technical write-up |

### Why the USB port cannot do two jobs

The ESP32-S3 has **one USB PHY** shared by the USB-OTG and USB-Serial-JTAG controllers, on
GPIO19/20 — the same pins as the USB-C connector. Only one can be active. While the camera
owns the port as a USB **host**:

* the board cannot also be a USB **device** (no USB webcam output, no USB serial console),
* the console moves to **UART0** (`GPIO43` TX / `GPIO44` RX, 115200),
* **to flash again later you must hold `BOOT` and replug** — the running firmware will never
  show up as a COM port.

This is enforced in Kconfig, and the firmware additionally never installs the USB-Serial-JTAG
driver at runtime on this board, so the PHY is left entirely to the camera host.

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
`menuconfig` (or in the board profile) if you need to — the camera's supported modes are
printed in the UART log at every connect.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| "waiting for a UVC camera..." forever | camera not getting 5 V on VBUS — see *Power* |
| No log output at all | console is UART0 now, not USB serial — see *Watching the logs* |
| No `EyeTrackVR` Wi-Fi appears | board not booting / not powered; check the LED |
| Can't flash | hold `BOOT`, replug; unplug the camera first |
| `uvc_host_stream_open failed` | requested resolution/fps/format not advertised — read the logged mode list |
| Very low fps | uncompressed mode, or resolution too high |
| Config file errors | `python tools/apply_user_config.py --check` |
| PlatformIO "Nothing to build" | use the `flash_openiris` custom target, or the project's default target |

Full detail: [`docs/USB_CAMERA_HOST.md`](docs/USB_CAMERA_HOST.md) ·
[`docs/FLASHING_WINDOWS.md`](docs/FLASHING_WINDOWS.md)

---

## Licence / credits

Firmware based on [OpenIris](https://github.com/EyeTrackVR/OpenIris) by the EyeTrackVR
project. USB host camera backend added here. ESP-IDF components retain their own licences.
