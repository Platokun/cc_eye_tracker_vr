# Flashing OpenIris (XIAO ESP32S3, USB-camera build) from Windows

You need **one file**:

```
openiris_xiao_esp32s3_usb_cam_merged.bin
```

It is the bootloader + partition table + OTA data + application merged into one image,
so it is written at a single offset (`0x0`). Nothing else to download.

---

## Before you start

1. **Unplug the camera and the OTG adapter.** Flashing talks to the XIAO itself, so the
   USB-C port must go straight to the PC. It is the same single port the camera will use
   later — you swap the cable.
2. **Use a data-capable USB-C cable**, not a charge-only one.
3. Browser route needs **Chrome or Edge** (Firefox and Safari do not support WebSerial).

### Putting the XIAO into download mode

The running firmware does *not* expose a USB serial port (it owns the USB port as a camera
host), so it will never appear as a COM port while running. To flash, force the ROM
bootloader:

> **Hold the `BOOT` button → plug the USB-C cable into the PC → release `BOOT`.**
>
> If it doesn't appear: hold `BOOT`, tap `RESET`, then release `BOOT`.

---

## Route A — browser, nothing to install (easiest)

1. Open **Chrome or Edge** and go to <https://espressif.github.io/esptool-js/>
2. Leave baud at **921600**.
3. Click **Connect** and pick the COM port that appeared when you entered download mode.
   (If no port appears, Windows may need the *ESP32-S3 USB-Serial-JTAG* driver once; the
   browser flasher page links it. Windows 11 usually installs it automatically.)
4. Under **Program**, set:
   * **Flash Address** = `0x0`
   * **File** = choose `openiris_xiao_esp32s3_usb_cam_merged.bin`
5. Click **Program**, wait for 100%.
6. Click **Disconnect**, unplug, then see *After flashing* below.

---

## Route B — esptool command line

1. Install Python from <https://www.python.org/downloads/> and **tick "Add python.exe to PATH"**.
2. Open Command Prompt and run:

```bat
pip install esptool
```

3. Put the board in download mode (hold BOOT, plug in, release BOOT).
4. Find the port in Device Manager (e.g. `COM5`), then:

```bat
esptool.py --chip esp32s3 --port COM5 --baud 921600 write_flash 0x0 openiris_xiao_esp32s3_usb_cam_merged.bin
```

`cd` to the folder containing the `.bin` first, or give the full path.

---

## After flashing — power and camera

This is the step that trips people up. The XIAO has **one** USB-C port and the camera now
needs it, so **the board cannot be powered from that port any more**.

| Connection | Where |
|---|---|
| Camera | USB-C → **OTG adapter** → camera (USB-A) |
| Power | **5 V + GND into the `5V` and `GND` pins** |

A bare 3.7 V LiPo on the battery pads / VIN will **not** work: the camera needs 5 V, and on
the XIAO the `5V` pin is tied to the USB-C VBUS pin. Feed **5 V from a power bank or a 5 V
regulator** into the `5V` pin — that powers the board *and* back-feeds VBUS to the camera.

If you also want to plug a PC into the port while external 5 V is connected, put a Schottky
diode in the external 5 V feed (anode to your supply, cathode to the `5V` pin).

> Alternative: a **powered USB hub**. XIAO USB-C → hub upstream, camera → hub downstream.
> The hub's PSU back-feeds 5 V to the XIAO. Works only if the hub actually back-powers its
> upstream port — not all do.

---

## Configuring Wi-Fi

The serial setup CLI (`tools/setup_openiris.py`) is unusable over USB now, because the
USB port is the camera bus and the console moved to UART0 (GPIO43/44).

Instead, on first boot with no stored credentials the firmware raises its own access point:

* **SSID:** `EyeTrackVR`
* **Password:** `12345678`

Join that from a phone/laptop and configure the real Wi-Fi over the device's REST interface,
or connect the tracker to your normal network and find it via mDNS
(`openiristracker.local`).

---

## What you should see

Logs are on **UART0 (GPIO43 = TX, GPIO44 = RX, 115200)** — connect a 3.3 V USB-serial
adapter to see them. On a healthy boot with the camera attached:

```
I (xxx) [USB_CAM]: Starting USB camera host (USB-OTG on GPIO19/20)
I (xxx) [USB_CAM]: Camera advertises N mode(s):
I (xxx) [USB_CAM]:    [0] MJPEG 640x480 @ 30.0 fps (default)
I (xxx) [USB_CAM]: OpenIris will request: MJPEG 240x240 @ 60 fps
I (xxx) [USB_CAM]: Streaming started
```

If it sits at *"waiting for a UVC camera..."* forever, the camera is not getting 5 V on VBUS
— revisit the power table above.

---

## Re-flashing later

Same procedure every time: **hold `BOOT`, plug the USB-C into the PC, release `BOOT`**, then
flash. Unplug the camera first. The runtime firmware will never show up as a COM port.

---

## Tuning resolution / FPS

The default is `MJPEG 240x240 @ 60 fps`. If you want a different mode, edit
`CAMERA_UVC_WIDTH` / `HEIGHT` / `FPS` in `menuconfig` (or the board profile) and rebuild —
the supported list is printed in the log at every connect. See
[USB_CAMERA_HOST.md](USB_CAMERA_HOST.md) §3 for the Full-Speed USB bandwidth ceiling.
