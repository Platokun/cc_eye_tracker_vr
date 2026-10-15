#pragma once
#ifndef USBUVCCAMERA_HPP
#define USBUVCCAMERA_HPP

#include <atomic>
#include <cstdint>

#include "esp_camera.h"
#include "esp_err.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "sdkconfig.h"
#include "usb/uvc_host.h"

/**
 * UsbUvcCamera
 *
 * Drives a USB Video Class (UVC) camera attached to the ESP32-S3 native USB port
 * (GPIO19/GPIO20 -- the USB-C connector on the Seeed XIAO ESP32S3) and exposes the
 * incoming frames through the same `camera_fb_t` container the rest of OpenIris
 * already consumes from esp32-camera.
 *
 * The ESP is the USB *host* here, so it supplies VBUS and enumerates the camera.
 * Frames are handed to the PC over Wi-Fi by StreamServer; the USB port is busy
 * being the camera bus and therefore cannot also be a USB-serial console.
 */
class UsbUvcCamera
{
   public:
    UsbUvcCamera();
    ~UsbUvcCamera();

    /** Install the USB host stack + UVC class driver and start looking for a camera. */
    bool start();

    /** Tear everything down (driver, USB host stack, buffers). */
    bool stop();

    /** True once a stream has been negotiated and is running. */
    bool isStreaming() const { return streaming_.load(); }

    /** True once a UVC device has been opened (may be streaming or just opened). */
    bool isConnected() const { return connected_.load(); }

    /**
     * Get the next captured frame.
     * Returns nullptr on timeout / no camera / not streaming.
     * The returned pointer must be released with returnFrame().
     */
    camera_fb_t* getFrame(uint32_t timeoutMs);

    /** Hand a frame previously obtained from getFrame() back to the driver. */
    void returnFrame(camera_fb_t* fb);

   private:
    struct FrameWrapper
    {
        camera_fb_t fb;             /* MUST stay first: released via reinterpret_cast */
        uvc_host_frame_t* uvcFrame; /* backing UVC buffer, nullptr if conversion happened */
        uint8_t* ownedJpeg;         /* JPEG we allocated during YUY2 -> JPEG conversion */
    };

    static bool frameCallback(const uvc_host_frame_t* frame, void* userCtx);
    static void streamEventCallback(const uvc_host_stream_event_data_t* event, void* userCtx);
    static void driverEventCallback(const uvc_host_driver_event_data_t* event, void* userCtx);
    static void usbLibTask(void* arg);
    static void streamTask(void* arg);

    void logAdvertisedFormats(uint8_t devAddr, uint8_t streamIndex, size_t count);
    bool openStream();
    void closeStream();
    uvc_host_stream_config_t buildStreamConfig() const;
    camera_fb_t* wrapFrame(uvc_host_frame_t* uvcFrame);

    QueueHandle_t frameQueue_ = nullptr;
    SemaphoreHandle_t lock_ = nullptr;
    TaskHandle_t streamTaskHandle_ = nullptr;
    uvc_host_stream_hdl_t streamHdl_ = nullptr;
    uvc_host_stream_config_t streamConfig_ = {};
    std::atomic<bool> connected_{false};
    std::atomic<bool> streaming_{false};
    std::atomic<bool> stopRequested_{false};
    bool driverInstalled_ = false;
    bool hostInstalled_ = false;
};

#endif  // USBUVCCAMERA_HPP
