# cc_eye_tracker_vr

Firmware for a **Seeed Studio XIAO ESP32S3** eye tracker that takes video from a **USB (UVC)
camera on the USB-C port** and streams it to the eye-tracking host **over Wi-Fi**.

This repository is built on [EyeTrackVR/OpenIris-ESPIDF](https://github.com/EyeTrackVR/OpenIris-ESPIDF)
(ESP-IDF, not Arduino/PlatformIO) with a new USB host camera backend.

**Start here: [`START_HERE.md`](START_HERE.md)** — flashing, power/wiring, first boot, Wi-Fi.
Verification status: [`VALIDATION.md`](VALIDATION.md).

---

## At a glance

| | |
|---|---|
| Board profile | `boards/seed_studio/xiao_esp32s3_usb_cam` |
| Camera input | USB Video Class (UVC) host on GPIO19/20 → the USB-C connector |
| Video output | MJPEG over HTTP (port 80), plus the REST API on port 81 |
| Console | UART0 — GPIO43 TX / GPIO44 RX, 115200 |
| Default streaming mode | Wi-Fi, so the tracker is reachable without any host command |
| Toolchain | ESP-IDF **v5.4.2**, target `esp32s3` |

---

## Repository layout

```
START_HERE.md                  user-facing setup guide (read this first)
VALIDATION.md                  what was actually built and verified, and how
user_board.nzk.config          the one file you edit: Wi-Fi, fallback AP, device name
build_and_flash.sh / .bat      build the firmware (and optionally flash it)
boards/seed_studio/
  xiao_esp32s3_usb_cam         the USB-camera board profile
  xiao_esp32s3                 the stock DVP-camera profile (kept for switching back)
components/
  UsbUvcCamera/                USB host + uvc_host wrapper, frames as camera_fb_t
  CameraManager/               picks the DVP sensor or the USB camera
  StreamServer/                MJPEG HTTP stream (Wi-Fi)
  UVCStream/                   USB-webcam output path (compiled out on this board)
  SerialManager/               serial command channel (deliberately inert on this board)
  ...
flash/                         PlatformIO project that only *flashes* the prebuilt image
docs/                          USB camera + flashing write-ups
tools/                         apply_user_config.py, board switcher, setup CLI
managed_components/            vendored esp32-camera, usb_host_uvc, tinyusb, mdns, ...
```

---

## Which code path is active

`CONFIG_CAMERA_INPUT_USB_UVC=y` (set in the board profile) switches the firmware to the USB
camera. Everything downstream is unchanged:

```
USB camera ─▶ usb_host_uvc ─▶ UsbUvcCamera (camera_fb_t)
                                      │
                         CameraManager::getFrame()
                                      │
                            StreamServer (port 80) ─▶ HTTP MJPEG ─▶ EyeTrackVR host
```

Because the ESP32-S3 has a single USB PHY, on this board:

* `CONFIG_GENERAL_INCLUDE_UVC_MODE` is forced off (Kconfig `depends on !CAMERA_INPUT_USB_UVC`),
  so the device can never be a USB webcam at the same time;
* the USB-Serial-JTAG console is disabled and the console moves to UART0;
* the firmware does **not** install the USB-Serial-JTAG driver at runtime, leaving the PHY
  entirely to the USB host controller;
* re-flashing always means: hold `BOOT`, replug USB-C, release `BOOT`.

---

## Wi-Fi behaviour

`CONFIG_START_IN_WIFI_MODE=y` is set in this board profile, so the tracker boots into Wi-Fi
streaming mode instead of waiting in `SETUP` for a host command that would have to arrive over
a serial port that no longer exists.

On boot it tries, in order: the Wi-Fi compiled in from `user_board.nzk.config` → networks
stored through the app/REST API → its own fallback access point (`EyeTrackVR` / `12345678`).
Then mDNS starts and the stream server starts on port 80.

Reachable at `http://<DEVICE_NAME>.local` (default `http://cc_eyetracker.local/`, or
`http://192.168.4.1/` when running as an access point).

---

## Configuration

### Compile-time — `user_board.nzk.config`

```
WIFI_SSID=          # your home network (blank = access point only)
WIFI_PASSWORD=
AP_SSID=EyeTrackVR  # fallback access point
AP_PASSWORD=12345678
DEVICE_NAME=cc_eyetracker
```

`build_and_flash.sh` / `.bat` convert this into `boards/generated/user_config` and append it
to `SDKCONFIG_DEFAULTS`. Validate without writing anything:

```bash
python tools/apply_user_config.py --check
```

### Run-time — REST API on port 81

Each command has its own endpoint; the JSON body is the command payload.

| Method | Endpoint | Purpose |
|---|---|---|
| `POST` | `/api/set/wifi/` | store a network: `{"name","ssid","password","channel","power"}` |
| `POST` | `/api/set/config/save/` | persist the current config |
| `POST` | `/api/set/wifi/connect/` | connect now |
| `PATCH` | `/api/update/device/mode/` | switch streaming mode (`uvc` / `wifi` / `setup`) |
| `GET` | `/api/get/who_am_i/` | board id and firmware version |
| `GET` | `/api/ping/` | liveness |
| `POST` | `/api/reboot/device/` | restart |

### Camera tuning — `menuconfig`

`OpenIris: USB Camera (UVC host) Configuration`: `CAMERA_UVC_VID`/`PID`,
`CAMERA_UVC_FORMAT_MJPEG`/`YUY2`, `CAMERA_UVC_WIDTH`/`HEIGHT`/`FPS`,
`CAMERA_UVC_BUFFER_COUNT`, `CAMERA_UVC_URB_COUNT`, `CAMERA_UVC_JPEG_QUALITY`.

The camera's advertised modes are logged over UART on every connect; request one that is
actually in that list or the driver falls back to the device default.

---

## LED status patterns

The on-board LED (GPIO21, `LED_DEBUG_ENABLE=y`) mirrors device state.

| State | Pattern | Meaning |
|---|---|---|
| idle | off | heartbeat window, nothing running |
| streaming | steady on | streaming active (Wi-Fi) |
| stopped | steady off | streaming intentionally stopped |
| camera error | 300/300, 300/700 | camera init/runtime failure |
| Wi-Fi connecting | 400/400 | associating / DHCP pending |
| Wi-Fi connected | 150/150 ×3, then 600 off | connected |
| Wi-Fi error | 200/100, 500/300 | auth timeout / no AP |

---

## Building

```bash
./build_and_flash.sh                       # build only
./build_and_flash.sh --flash /dev/ttyACM0  # build and flash
```

Requires ESP-IDF v5.4.2 (`idf.py` on `PATH`, or at `$IDF_PATH`, `~/esp/esp-idf`,
`~/esp-idf`, `/opt/esp-idf`). The script regenerates `sdkconfig` from the board profile,
builds, and merges everything into a single image flashable at offset `0x0`.

Manual equivalent:

```bash
export SDKCONFIG_DEFAULTS="boards/sdkconfig.base_defaults;boards/seed_studio/xiao_esp32s3_usb_cam;boards/generated/user_config"
rm -f sdkconfig sdkconfig.old
idf.py set-target esp32s3
idf.py build
```

> Do **not** run `rm -rf build` on a network filesystem and then start a build in the same
> directory — NFS deletes lazily and can wipe the new build tree underneath ninja. Delete
> while nothing is building, or build into a fresh directory with `idf.py -B <dir>`.

---

## Licence / credits

Based on [OpenIris](https://github.com/EyeTrackVR/OpenIris) and
[OpenIris-ESPIDF](https://github.com/EyeTrackVR/OpenIris-ESPIDF) by the EyeTrackVR project.
USB host camera backend added here. Bundled ESP-IDF components retain their own licences.
