#pragma once
#ifndef CAMERAMANAGER_HPP
#define CAMERAMANAGER_HPP

#include "driver/gpio.h"
#include "esp_camera.h"
#include "esp_log.h"
#include "esp_psram.h"
#include "sdkconfig.h"

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

#include <ProjectConfig.hpp>
#include <StateManager.hpp>

#if CONFIG_CAMERA_INPUT_USB_UVC
#include <UsbUvcCamera.hpp>
#endif

#define OV5640_XCLK_FREQ_HZ CONFIG_CAMERA_WIFI_XCLK_FREQ

class CameraManager
{
   private:
    sensor_t* camera_sensor;
    std::shared_ptr<ProjectConfig> projectConfig;
    QueueHandle_t eventQueue;
    camera_config_t config;
#if CONFIG_CAMERA_INPUT_USB_UVC
    std::shared_ptr<UsbUvcCamera> usbCamera;
#endif

   public:
    CameraManager(std::shared_ptr<ProjectConfig> projectConfig, QueueHandle_t eventQueue);
    int setCameraResolution(framesize_t frameSize);
    bool setupCamera();
    int setVFlip(int direction);
    int setHFlip(int direction);
    int setVieWindow(int offsetX, int offsetY, int outputX, int outputY);

    /**
     * Acquire the next frame from whichever camera backend is active
     * (on-board DVP sensor, or a USB UVC camera on the USB-C port).
     * Must be released with returnFrame().
     */
    camera_fb_t* getFrame();

    /** Release a frame previously obtained from getFrame(). */
    void returnFrame(camera_fb_t* fb);

   private:
    void loadConfigData();
    void setupCameraPinout();
    void setupCameraSensor();
#if CONFIG_CAMERA_INPUT_USB_UVC
    bool setupUsbCamera();
#endif
};

#endif  // CAMERAMANAGER_HPP