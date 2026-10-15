# Using a USB (UVC) camera as the OpenIris camera input — Seeed XIAO ESP32S3

This document describes the `seed_studio/xiao_esp32s3_usb_cam` board profile, which makes
OpenIris-ESPIDF take its video from a **USB Video Class (UVC) camera plugged into the
XIAO's USB-C port**, instead of the on-board DVP camera (OV2640 / OV5640 / GC0308).

It replaces the "built-in camera" backend; the rest of the firmware (eye-tracking frame
streaming over Wi-Fi, LED/IR control, REST/serial commands, mDNS) is unchanged.

---

## 1. What changes vs. the stock build

| | Stock DVP build | This USB-UVC build |
|---|---|---|
| Camera bus | 14 GPIOs (DVP parallel + SCCB) | USB-OTG on GPIO19/GPIO20 (USB-C) |
| ESP role on USB | USB **device** (optional UVC webcam out) | USB **host** (camera in) |
| Frame source | `esp_camera_fb_get()` | `usb_host_uvc` → same `camera_fb_t` |
| Frames reach PC via | Wi-Fi (`StreamServer`) or USB-UVC | Wi-Fi (`StreamServer`) |
| Console | USB-Serial-JTAG | UART0 (GPIO43 TX / GPIO44 RX) |

The camera frames are handed to the PC over **Wi-Fi**, exactly as in the normal build.
The USB port is busy being the camera bus, so it can no longer also be the PC link.

This profile also sets `CONFIG_START_IN_WIFI_MODE=y` (see §5), so the tracker boots straight
into Wi-Fi streaming mode — it joins the configured network (or raises its fallback AP) and
starts the stream server on port 80 without waiting for a command. On the stock profiles the
default mode is `SETUP`, which is only useful when a serial or USB console exists to send the
"switch to Wi-Fi" command through; on this board that console does not exist.

---

## 2. Wiring — read this before powering anything

### 2.1 USB data lines

The XIAO ESP32S3 routes the ESP32-S3 native USB pins straight to the USB-C connector:

| ESP32-S3 | XIAO USB-C |
|---|---|
| GPIO20 | D+ |
| GPIO19 | D− |

Nothing to wire for data: an **OTG / USB-C adapter** goes into the XIAO's USB-C port and
the camera plugs into that adapter. No hub is required for a single Full-Speed camera,
but see the bandwidth section.

### 2.2 Power — this is the part that usually bites

A USB camera needs **5 V on VBUS**, and something has to *supply* it, because in host mode the
XIAO is the host. The ESP32-S3 provides no VBUS: the chip has no VBUS pin and no boost
converter, so VBUS is entirely a board-level responsibility.

On the XIAO ESP32S3 the `5V` pin is **tied directly to the USB-C VBUS pin** — the schematic
has no diode, load switch or ideal-diode between them. The only relevant part is D2, a 1 A
Schottky, which sits *after* the VBUS node feeding the 3V3 buck. Two consequences:

* Feeding **5 V into the `5V` pin** back-feeds VBUS, powers the camera, and powers the board
  through D2 → the 3V3 buck. ✅ This is the documented input mode.
* The board has **no boost converter** (the only regulator is a 3V3 buck). With battery-only
  power Seeed states plainly: *"When you use battery power, there will be no voltage on the
  5V pin."* So a **3.7 V LiPo on the `BAT` pads gives 0 V on VBUS and the camera never powers
  up.** ❌ The board boots; the camera stays dark.

So the power arrangement must be one of:

1. **5 V supply + series Schottky into the `5V` pin** (power bank, or a LiPo + 3.7 V→5 V boost
   module ≥1 A such as an IP5306/FM5324GA-class board) — powers the board *and* the camera; or
2. **A self-powered USB hub** between the XIAO's USB-C and the camera, which supplies VBUS
   itself (only if the hub back-powers its upstream port); or
3. **Camera self-powered** from its own 5 V supply (VBUS only needs to be present, not
   sourced by the XIAO).

> ⚠️ **The series Schottky diode is required, not optional.** Seeed's documentation states you
> must have a diode between your external supply and the `5V` pin — *anode to your supply,
> cathode to the `5V` pin* — precisely because the board has none. It also stops your supply
> from fighting USB VBUS if a cable is plugged in. It costs ~0.3–0.5 V, so the camera sees
> ~4.5–4.7 V; USB cameras normally tolerate that.

Budget **~1 A at 5 V**: the board draws ~0.15–0.35 A (the USB-Serial-JTAG path is off, Wi-Fi is
on) and the camera typically 100–500 mA, more at high frame rates.


### 2.3 Flashing and the serial console

The ESP32-S3 has **one USB PHY** shared between the USB-OTG controller and the
USB-Serial-JTAG controller, and only one may be active at a time
([Espressif docs](https://docs.espressif.com/projects/esp-usb/en/latest/esp32s3/usb_device.html)).
Because this build gives the PHY to USB-OTG (host mode), this profile disables
`CONFIG_USJ_ENABLE_USB_SERIAL_JTAG` and moves the console to **UART0**
(GPIO43 = TX, GPIO44 = RX, 115200 baud) — those are the `D6`/`D7` pads on the XIAO.

> **That Kconfig option only gates the USB-Serial-JTAG *clock* at startup; it does not stop
> the application from installing the USB-Serial-JTAG driver later.** The stock
> `SerialManager` installs that driver unconditionally on ESP32-S3, which would reconfigure
> the shared FSLS PHY (`USB_SERIAL_JTAG.conf0.usb_pad_enable`) underneath the already-running
> USB host stack. This profile therefore also makes the serial command channel inert when
> `CONFIG_CAMERA_INPUT_USB_UVC` is set: `SerialManager::setup()` does not install the driver,
> and `openiris_main.cpp` does not start the serial task at all. Commands are served over the
> Wi-Fi REST API (port 81) instead. There is no USB serial console on this build anyway.

Consequences:

* **Logs** appear on UART0, not on the USB-C port. Connect a 3.3 V USB-serial adapter to
  GPIO43/44 if you want to watch them.
* **To re-flash**: the ROM bootloader still brings up USB-Serial-JTAG on its own, so
  **hold `BOOT` and replug the USB-C cable** (or hold BOOT, tap RESET, release BOOT) to
  enter download mode, then `idf.py flash`. Unplug the camera while flashing.

---

## 3. Bandwidth reality check (important)

The ESP32-S3's USB-OTG controller is **USB 1.1 Full-Speed (12 Mbit/s)**, not High-Speed.
Usable isochronous video payload is roughly **0.9 MB/s** after protocol overhead.

That is the hard ceiling, regardless of what the camera's datasheet claims:

| Mode | Bytes/frame (MJPEG, approx) | Achievable fps |
|---|---|---|
| 240×240 | 5–10 KB | **60–120** ✅ |
| 320×240 | 10–20 KB | 30–60 |
| 640×480 | 25–60 KB | 15–30 |
| 640×480 uncompressed YUY2 (600 KB) | 600 KB | **~1.5** ❌ |

A "120 fps" camera usually achieves that at a small resolution and/or with a compressed
format. Ask for a **small MJPEG mode** (240×240 is EyeTrackVR's default and is what this
profile is set to) and you can genuinely reach high frame rates.

Uncompressed modes are effectively unusable over Full-Speed USB: 240×240 YUY2 is 115 KB
per frame, i.e. ~8 fps at best, plus CPU time to JPEG-encode it on the ESP32.

**Practical guidance:** leave the camera in MJPEG and pick the smallest resolution that
still covers the eye.

---

## 4. Build

The profile lives at `boards/seed_studio/xiao_esp32s3_usb_cam` mirroring the existing
`xiao_esp32s3` file. Two ways to build:

### 4.1 With the repo's board switcher

```bash
uv run ./tools/switchBoardType.py --list
uv run ./tools/switchBoardType.py --board seed_studio/xiao_esp32s3_usb_cam --diff
uv run ./tools/switchBoardType.py --board seed_studio/xiao_esp32s3_usb_cam
idf.py build
idf.py -p /dev/ttyACM0 flash monitor
```

### 4.2 Directly with IDF, without the helper tool

```bash
export SDKCONFIG_DEFAULTS="boards/sdkconfig.base_defaults;boards/seed_studio/xiao_esp32s3_usb_cam;boards/generated/user_config"
python tools/apply_user_config.py           # writes boards/generated/user_config
rm -f sdkconfig
idf.py set-target esp32s3
idf.py build
idf.py -p <PORT> flash
```

`boards/generated/user_config` is the file `tools/apply_user_config.py` generates from
`user_board.nzk.config` (Wi-Fi credentials, fallback AP, device name) and is gitignored, so it
must be regenerated on a fresh clone. Omit it from `SDKCONFIG_DEFAULTS` if you intend to
configure Wi-Fi at runtime through the access point instead.

> If you build on a network filesystem, do not `rm -rf build` while anything is building —
> NFS removes files lazily and will eat the new build tree. Build into a fresh directory with
> `idf.py -B /tmp/ccbuild set-target esp32s3 && idf.py -B /tmp/ccbuild build` instead.

`idf.py` fetches `espressif/usb_host_uvc` (declared in `main/idf_component.yml`)
automatically. The minimum version is 2.6.0; it targets ESP32-S3 with both
isochronous and bulk streaming.

---

## 5. Configuration

All options are under `OpenIris: USB Camera (UVC host) Configuration` in `menuconfig`,
plus the two general streaming-mode options:

| Option | Default | Meaning |
|---|---|---|
| `START_IN_WIFI_MODE` | `y` in this profile | Boot straight into Wi-Fi streaming (no host command needed) |
| `START_IN_UVC_MODE` | `n` | Boot into USB-webcam mode; takes precedence over the above |
| `CAMERA_INPUT_USB_UVC` | `y` in this profile | Use the USB camera instead of DVP |
| `CAMERA_UVC_VID` / `PID` | `0x0` (any) | Bind to a specific camera model |
| `CAMERA_UVC_FORMAT_MJPEG` / `..._YUY2` | MJPEG | Requested UVC payload format |
| `CAMERA_UVC_WIDTH` / `HEIGHT` | 240×240 | Must be a mode the camera advertises |
| `CAMERA_UVC_FPS` | 60 | Requested frame interval |
| `CAMERA_UVC_BUFFER_COUNT` | 3 | Frame buffers, allocated in PSRAM |
| `CAMERA_UVC_URB_COUNT` | 4 | USB Request Blocks per stream |
| `CAMERA_UVC_JPEG_QUALITY` | 12 | Quality for YUY2→JPEG conversion only |

At every connect the driver **logs the full list of modes the camera advertises**, e.g.:

```
I (1234) [USB_CAM]: Camera advertises 6 mode(s):
I (1234) [USB_CAM]:    [0] MJPEG 640x480 @ 30.0 fps (default)
I (1237) [USB_CAM]:    [1] MJPEG 320x240 @ 60.0 fps (default)
I (1240) [USB_CAM]:    [2] YUY2 240x240 @ 30.0 fps (default)
...
```

Set `CAMERA_UVC_WIDTH`/`HEIGHT`/`FPS` to a line that actually exists. If the requested
combination is not advertised, the driver falls back to the device default mode and logs
the negotiated result.

---

## 6. Switching back to the on-board camera

Set `CONFIG_CAMERA_INPUT_USB_UVC=n` (or just select the stock
`seed_studio/xiao_esp32s3` board profile) and re-enable
`CONFIG_GENERAL_INCLUDE_UVC_MODE` if you want USB-webcam output again. The DVP pin map
for the XIAO ESP32S3 Sense is kept in the profile file.

If your camera module is in fact a **GC0308 DVP sensor** (not a USB camera), it cannot be
used through the USB-C port — DVP needs the 14 camera GPIOs. `esp32-camera` does support
GC0308 (`CONFIG_GC0308_SUPPORT`), so in that case you would wire it to the DVP pins
instead and stay on the stock DVP profile.

---

## 7. Troubleshooting

| Symptom | Likely cause |
|---|---|
| No `[USB_CAM]` logs at all | Console is on UART0 now; connect GPIO43/44 |
| "waiting for a UVC camera..." forever | Camera has no power — VBUS is not 5 V (see §2.2) |
| Device not detected on the bus | Wrong adapter (charge-only), or D+/D− swapped |
| `uvc_host_stream_open failed` | Requested resolution/fps/format not advertised — read the logged mode list |
| Frame buffer overflow warnings | Requested frame larger than negotiated `dwMaxVideoFrameSize`; lower resolution |
| Very low fps | Uncompressed YUY2 mode selected, or 640×480 — use small MJPEG (§3) |
| Can't flash | Hold `BOOT` and replug; USB-Serial-JTAG is off at runtime |
| Wi-Fi stream stutters | USB isochronous traffic and Wi-Fi share CPU/PHY; lower resolution or fps |

---

## 8. Implementation notes

* `components/UsbUvcCamera/` — USB host + UVC class driver wrapper. Installs
  `usb_host_install()`, runs the USB library event task, installs `uvc_host_install()`,
  opens the stream on connect, and exposes frames as `camera_fb_t`.
* MJPEG frames are passed through **zero-copy**; the `camera_fb_t` wrapper carries the
  original `uvc_host_frame_t*` so it can be returned to the driver.
* `components/CameraManager/` — now a backend switch: `getFrame()` / `returnFrame()`
  dispatch to either `esp_camera` (DVP) or `UsbUvcCamera`.
* `components/StreamServer/` and `components/UVCStream/` — call
  `cameraHandler->getFrame()` instead of `esp_camera_fb_get()`.
* `GENERAL_INCLUDE_UVC_MODE` is Kconfig-`depends on !CAMERA_INPUT_USB_UVC`, so the
  USB-device and USB-host configurations cannot be selected together.
