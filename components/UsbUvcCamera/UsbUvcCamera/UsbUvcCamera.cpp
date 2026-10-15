#include "UsbUvcCamera.hpp"

#include <cstring>
#include <sys/time.h>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "img_converters.h"
#include "usb/usb_host.h"

static const char* USB_CAM_TAG = "[USB_CAM]";

// Only defined by Kconfig when YUY2 is selected; keep the MJPEG build compiling.
#ifndef CONFIG_CAMERA_UVC_JPEG_QUALITY
#define CONFIG_CAMERA_UVC_JPEG_QUALITY 12
#endif

#define UVC_INTERVAL_TO_FPS(interval) (((interval) != 0) ? 10000000.0f / ((float)(interval)) : 0.0f)

/** Name of the format this build was configured to request. */
static const char* requestedFormatName()
{
#ifdef CONFIG_CAMERA_UVC_FORMAT_YUY2
    return "YUY2";
#else
    return "MJPEG";
#endif
}

static const char* uvcFormatName(enum uvc_host_stream_format format)
{
    switch (format)
    {
        case UVC_VS_FORMAT_MJPEG:
            return "MJPEG";
        case UVC_VS_FORMAT_YUY2:
            return "YUY2";
        case UVC_VS_FORMAT_H264:
            return "H264";
        case UVC_VS_FORMAT_H265:
            return "H265";
        case UVC_VS_FORMAT_NV12:
            return "NV12";
        default:
            return "DEFAULT";
    }
}

UsbUvcCamera::UsbUvcCamera()
{
    frameQueue_ = xQueueCreate(CONFIG_CAMERA_UVC_BUFFER_COUNT, sizeof(uvc_host_frame_t*));
    lock_ = xSemaphoreCreateMutex();
}

UsbUvcCamera::~UsbUvcCamera()
{
    stop();
    if (frameQueue_)
    {
        vQueueDelete(frameQueue_);
        frameQueue_ = nullptr;
    }
    if (lock_)
    {
        vSemaphoreDelete(lock_);
        lock_ = nullptr;
    }
}

/* ------------------------------------------------------------------ */
/* USB plumbing                                                        */
/* ------------------------------------------------------------------ */

void UsbUvcCamera::usbLibTask(void* arg)
{
    (void)arg;
    while (true)
    {
        uint32_t eventFlags = 0;
        usb_host_lib_handle_events(portMAX_DELAY, &eventFlags);
        if (eventFlags & USB_HOST_LIB_EVENT_FLAGS_NO_CLIENTS)
        {
            usb_host_device_free_all();
        }
    }
}

void UsbUvcCamera::driverEventCallback(const uvc_host_driver_event_data_t* event, void* userCtx)
{
    auto* self = static_cast<UsbUvcCamera*>(userCtx);
    if (event->type != UVC_HOST_DRIVER_EVENT_DEVICE_CONNECTED)
    {
        return;
    }

    ESP_LOGI(USB_CAM_TAG, "UVC device connected (addr=%u, stream index=%u)", event->device_connected.dev_addr, event->device_connected.uvc_stream_index);
    self->logAdvertisedFormats(event->device_connected.dev_addr, event->device_connected.uvc_stream_index, event->device_connected.frame_info_num);

    if (self->streamTaskHandle_ == nullptr)
    {
        xTaskCreatePinnedToCore(streamTask, "uvc_stream", 6 * 1024, self, 6, &self->streamTaskHandle_, tskNO_AFFINITY);
    }
    else
    {
        // A reconnect: nudge the stream task so it re-opens.
        self->connected_.store(true);
    }
}

void UsbUvcCamera::logAdvertisedFormats(uint8_t devAddr, uint8_t streamIndex, size_t count)
{
    if (count == 0)
    {
        ESP_LOGW(USB_CAM_TAG, "Camera reported no video formats");
        return;
    }

    auto* list = static_cast<uvc_host_frame_info_t*>(calloc(count, sizeof(uvc_host_frame_info_t)));
    if (list == nullptr)
    {
        return;
    }

    if (uvc_host_get_frame_list(devAddr, streamIndex, (uvc_host_frame_info_t(*)[])list, &count) == ESP_OK)
    {
        ESP_LOGI(USB_CAM_TAG, "Camera advertises %u mode(s):", (unsigned)count);
        for (size_t i = 0; i < count; i++)
        {
            ESP_LOGI(USB_CAM_TAG, "   [%u] %s %ux%u @ %.1f fps (default)", (unsigned)i, uvcFormatName(list[i].format), list[i].h_res, list[i].v_res,
                     UVC_INTERVAL_TO_FPS(list[i].default_interval));
        }
    }
    free(list);

    ESP_LOGI(USB_CAM_TAG, "OpenIris will request: %s %dx%d @ %d fps", requestedFormatName(), CONFIG_CAMERA_UVC_WIDTH, CONFIG_CAMERA_UVC_HEIGHT,
             CONFIG_CAMERA_UVC_FPS);
}

uvc_host_stream_config_t UsbUvcCamera::buildStreamConfig() const
{
    uvc_host_stream_config_t cfg = {};
    cfg.event_cb = streamEventCallback;
    cfg.frame_cb = frameCallback;
    cfg.user_ctx = const_cast<UsbUvcCamera*>(this);

    cfg.usb.dev_addr = 0;  // any
    cfg.usb.vid = (uint16_t)CONFIG_CAMERA_UVC_VID;
    cfg.usb.pid = (uint16_t)CONFIG_CAMERA_UVC_PID;
    cfg.usb.uvc_stream_index = 0;

    cfg.vs_format.h_res = CONFIG_CAMERA_UVC_WIDTH;
    cfg.vs_format.v_res = CONFIG_CAMERA_UVC_HEIGHT;
    cfg.vs_format.fps = (float)CONFIG_CAMERA_UVC_FPS;
#ifdef CONFIG_CAMERA_UVC_FORMAT_YUY2
    cfg.vs_format.format = UVC_VS_FORMAT_YUY2;
#else
    cfg.vs_format.format = UVC_VS_FORMAT_MJPEG;
#endif

    cfg.advanced.number_of_frame_buffers = CONFIG_CAMERA_UVC_BUFFER_COUNT;
    cfg.advanced.frame_size = 0;  // take dwMaxVideoFrameSize from negotiation
#ifdef CONFIG_SPIRAM
    cfg.advanced.frame_heap_caps = MALLOC_CAP_SPIRAM;
#else
    cfg.advanced.frame_heap_caps = MALLOC_CAP_DEFAULT;
#endif
    cfg.advanced.number_of_urbs = CONFIG_CAMERA_UVC_URB_COUNT;
    cfg.advanced.urb_size = 0;  // driver default (4x MPS)
    cfg.advanced.user_frame_buffers = nullptr;
    return cfg;
}

bool UsbUvcCamera::frameCallback(const uvc_host_frame_t* frame, void* userCtx)
{
    auto* self = static_cast<UsbUvcCamera*>(userCtx);
    auto* mutableFrame = const_cast<uvc_host_frame_t*>(frame);

    if (xQueueSend(self->frameQueue_, &mutableFrame, 0) != pdPASS)
    {
        // Host is not keeping up; drop and let the driver reclaim immediately.
        return true;
    }
    // We keep ownership until returnFrame() -> uvc_host_frame_return().
    return false;
}

void UsbUvcCamera::streamEventCallback(const uvc_host_stream_event_data_t* event, void* userCtx)
{
    auto* self = static_cast<UsbUvcCamera*>(userCtx);
    switch (event->type)
    {
        case UVC_HOST_TRANSFER_ERROR:
            ESP_LOGE(USB_CAM_TAG, "USB transfer error: %s", esp_err_to_name(event->transfer_error.error));
            break;
        case UVC_HOST_DEVICE_DISCONNECTED:
            ESP_LOGW(USB_CAM_TAG, "Camera disconnected");
            self->streaming_.store(false);
            self->connected_.store(false);
            self->closeStream();
            break;
        case UVC_HOST_FRAME_BUFFER_OVERFLOW:
            ESP_LOGW(USB_CAM_TAG, "Frame buffer overflow: frame larger than negotiated dwMaxVideoFrameSize");
            break;
        case UVC_HOST_FRAME_BUFFER_UNDERFLOW:
            ESP_LOGW(USB_CAM_TAG, "Frame buffer underflow: no free buffer, dropping a frame");
            break;
#ifdef UVC_HOST_SUSPEND_RESUME_API_SUPPORTED
        case UVC_HOST_DEVICE_SUSPENDED:
            ESP_LOGI(USB_CAM_TAG, "Camera suspended");
            break;
        case UVC_HOST_DEVICE_RESUMED:
            ESP_LOGI(USB_CAM_TAG, "Camera resumed");
            break;
#endif
        default:
            break;
    }
}

bool UsbUvcCamera::openStream()
{
    xSemaphoreTake(lock_, portMAX_DELAY);
    const bool alreadyOpen = (streamHdl_ != nullptr);
    xSemaphoreGive(lock_);
    if (alreadyOpen)
    {
        return true;
    }

    streamConfig_ = buildStreamConfig();
    uvc_host_stream_hdl_t hdl = nullptr;

    ESP_LOGI(USB_CAM_TAG, "Opening %s %dx%d @ %d fps ...", requestedFormatName(), CONFIG_CAMERA_UVC_WIDTH, CONFIG_CAMERA_UVC_HEIGHT,
             CONFIG_CAMERA_UVC_FPS);

    esp_err_t err = uvc_host_stream_open(&streamConfig_, pdMS_TO_TICKS(5000), &hdl);
    if (err != ESP_OK)
    {
        ESP_LOGW(USB_CAM_TAG, "uvc_host_stream_open failed: %s", esp_err_to_name(err));
        return false;
    }

    xSemaphoreTake(lock_, portMAX_DELAY);
    streamHdl_ = hdl;
    xSemaphoreGive(lock_);

    err = uvc_host_stream_start(hdl);
    if (err != ESP_OK)
    {
        ESP_LOGE(USB_CAM_TAG, "uvc_host_stream_start failed: %s", esp_err_to_name(err));
        closeStream();
        return false;
    }

    connected_.store(true);
    streaming_.store(true);
    ESP_LOGI(USB_CAM_TAG, "Streaming started");
    return true;
}

void UsbUvcCamera::closeStream()
{
    xSemaphoreTake(lock_, portMAX_DELAY);
    uvc_host_stream_hdl_t hdl = streamHdl_;
    streamHdl_ = nullptr;
    xSemaphoreGive(lock_);

    streaming_.store(false);

    if (hdl == nullptr)
    {
        return;
    }

    // Give any frames the consumer never picked up back to the driver, otherwise
    // its frame buffers leak and the stream cannot be re-opened.
    uvc_host_frame_t* queued = nullptr;
    while (frameQueue_ != nullptr && xQueueReceive(frameQueue_, &queued, 0) == pdPASS)
    {
        if (queued != nullptr)
        {
            uvc_host_frame_return(hdl, queued);
        }
    }

    uvc_host_stream_stop(hdl);
    uvc_host_stream_close(hdl);
}

void UsbUvcCamera::streamTask(void* arg)
{
    auto* self = static_cast<UsbUvcCamera*>(arg);

    while (!self->stopRequested_.load())
    {
        if (!self->openStream())
        {
            vTaskDelay(pdMS_TO_TICKS(1000));
        }
        else
        {
            // The driver pushes frames through frameCallback(); all we do here is
            // supervise the stream and re-open it after a disconnect.
            while (self->connected_.load() && !self->stopRequested_.load())
            {
                vTaskDelay(pdMS_TO_TICKS(500));
            }
            self->closeStream();
        }
    }

    self->streamTaskHandle_ = nullptr;
    vTaskDelete(nullptr);
}

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */

bool UsbUvcCamera::start()
{
    ESP_LOGI(USB_CAM_TAG, "Starting USB camera host (USB-OTG on GPIO19/20)");
    ESP_LOGW(USB_CAM_TAG,
             "USB-Serial-JTAG is unavailable while the USB host is active. "
             "Hold BOOT and replug the cable to re-enter download mode for flashing.");

    const usb_host_config_t hostConfig = {
        .skip_phy_setup = false,
        .intr_flags = ESP_INTR_FLAG_LOWMED,
    };
    esp_err_t err = usb_host_install(&hostConfig);
    if (err != ESP_OK)
    {
        ESP_LOGE(USB_CAM_TAG, "usb_host_install failed: %s", esp_err_to_name(err));
        return false;
    }
    hostInstalled_ = true;

    if (xTaskCreatePinnedToCore(usbLibTask, "usb_lib", 4 * 1024, nullptr, 15, nullptr, tskNO_AFFINITY) != pdPASS)
    {
        ESP_LOGE(USB_CAM_TAG, "Failed to create USB library task");
        return false;
    }

    const uvc_host_driver_config_t driverConfig = {
        .driver_task_stack_size = 4 * 1024,
        .driver_task_priority = 16,
        .xCoreID = tskNO_AFFINITY,
        .create_background_task = true,
        .event_cb = driverEventCallback,
        .user_ctx = this,
    };
    err = uvc_host_install(&driverConfig);
    if (err != ESP_OK)
    {
        ESP_LOGE(USB_CAM_TAG, "uvc_host_install failed: %s", esp_err_to_name(err));
        return false;
    }
    driverInstalled_ = true;

    ESP_LOGI(USB_CAM_TAG, "USB host ready, waiting for a UVC camera on the USB-C port...");
    return true;
}

bool UsbUvcCamera::stop()
{
    stopRequested_.store(true);
    closeStream();

    if (driverInstalled_)
    {
        uvc_host_uninstall();
        driverInstalled_ = false;
    }
    if (hostInstalled_)
    {
        usb_host_uninstall();
        hostInstalled_ = false;
    }
    return true;
}

camera_fb_t* UsbUvcCamera::wrapFrame(uvc_host_frame_t* uvcFrame)
{
    auto* wrapper = static_cast<FrameWrapper*>(heap_caps_calloc(1, sizeof(FrameWrapper), MALLOC_CAP_DEFAULT));
    if (wrapper == nullptr)
    {
        return nullptr;
    }

    wrapper->fb.width = uvcFrame->vs_format.h_res;
    wrapper->fb.height = uvcFrame->vs_format.v_res;
    wrapper->fb.timestamp.tv_sec = (time_t)(esp_timer_get_time() / 1000000);
    wrapper->fb.timestamp.tv_usec = (suseconds_t)(esp_timer_get_time() % 1000000);

    if (uvcFrame->vs_format.format == UVC_VS_FORMAT_MJPEG)
    {
        // Already JPEG -- hand it straight through, zero copy.
        wrapper->fb.buf = uvcFrame->data;
        wrapper->fb.len = uvcFrame->data_len;
        wrapper->fb.format = PIXFORMAT_JPEG;
        wrapper->uvcFrame = uvcFrame;
        return &wrapper->fb;
    }

    if (uvcFrame->vs_format.format == UVC_VS_FORMAT_YUY2)
    {
        uint8_t* jpeg = nullptr;
        size_t jpegLen = 0;
        if (fmt2jpg(uvcFrame->data, uvcFrame->data_len, (uint16_t)uvcFrame->vs_format.h_res, (uint16_t)uvcFrame->vs_format.v_res, PIXFORMAT_YUV422,
                    CONFIG_CAMERA_UVC_JPEG_QUALITY, &jpeg, &jpegLen))
        {
            wrapper->fb.buf = jpeg;
            wrapper->fb.len = jpegLen;
            wrapper->fb.format = PIXFORMAT_JPEG;
            wrapper->ownedJpeg = jpeg;
            wrapper->uvcFrame = uvcFrame;
            return &wrapper->fb;
        }
        ESP_LOGW(USB_CAM_TAG, "YUY2 -> JPEG conversion failed, dropping frame");
    }
    else
    {
        ESP_LOGW(USB_CAM_TAG, "Unsupported UVC format %s, dropping frame", uvcFormatName(uvcFrame->vs_format.format));
    }

    // Nothing usable: give the buffer straight back and report no frame.
    xSemaphoreTake(lock_, portMAX_DELAY);
    uvc_host_stream_hdl_t hdl = streamHdl_;
    xSemaphoreGive(lock_);
    if (hdl != nullptr)
    {
        uvc_host_frame_return(hdl, uvcFrame);
    }
    heap_caps_free(wrapper);
    return nullptr;
}

camera_fb_t* UsbUvcCamera::getFrame(uint32_t timeoutMs)
{
    if (frameQueue_ == nullptr)
    {
        return nullptr;
    }

    uvc_host_frame_t* uvcFrame = nullptr;
    const TickType_t ticks = (timeoutMs == 0) ? 0 : pdMS_TO_TICKS(timeoutMs);
    if (xQueueReceive(frameQueue_, &uvcFrame, ticks) != pdPASS || uvcFrame == nullptr)
    {
        return nullptr;
    }
    return wrapFrame(uvcFrame);
}

void UsbUvcCamera::returnFrame(camera_fb_t* fb)
{
    if (fb == nullptr)
    {
        return;
    }

    auto* wrapper = reinterpret_cast<FrameWrapper*>(fb);

    if (wrapper->ownedJpeg != nullptr)
    {
        free(wrapper->ownedJpeg);
        wrapper->ownedJpeg = nullptr;
    }

    if (wrapper->uvcFrame != nullptr)
    {
        xSemaphoreTake(lock_, portMAX_DELAY);
        uvc_host_stream_hdl_t hdl = streamHdl_;
        xSemaphoreGive(lock_);

        // If the stream was torn down while this frame was in flight, the driver has
        // already reclaimed its buffers -- do not hand it back through a dead handle.
        if (hdl != nullptr)
        {
            uvc_host_frame_return(hdl, wrapper->uvcFrame);
        }
        wrapper->uvcFrame = nullptr;
    }

    heap_caps_free(wrapper);
}
