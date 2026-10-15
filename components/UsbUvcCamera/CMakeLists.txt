idf_component_register(
    SRCS "UsbUvcCamera/UsbUvcCamera.cpp"
    INCLUDE_DIRS "UsbUvcCamera"
    REQUIRES usb usb_host_uvc esp32-camera ProjectConfig StateManager esp_psram
    PRIV_REQUIRES esp_timer
)
