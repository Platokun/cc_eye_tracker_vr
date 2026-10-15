/**
 * @file AdcSampler_esp32s3.cpp
 * @brief BSP Layer - ESP32-S3 specific ADC implementation
 *
 * ESP32-S3 ADC1 GPIO mapping:
 * - GPIO1  → ADC1_CH0
 * - GPIO2  → ADC1_CH1
 * - GPIO3  → ADC1_CH2
 * - GPIO4  → ADC1_CH3
 * - GPIO5  → ADC1_CH4
 * - GPIO6  → ADC1_CH5
 * - GPIO7  → ADC1_CH6
 * - GPIO8  → ADC1_CH7
 * - GPIO9  → ADC1_CH8
 * - GPIO10 → ADC1_CH9
 *
 * Note: ADC2 is not used to avoid conflicts with Wi-Fi.
 */

#include "AdcSampler.hpp"

#if defined(CONFIG_IDF_TARGET_ESP32S3)

bool AdcSampler::map_gpio_to_channel(int gpio, adc_unit_t& unit, adc_channel_t& channel)
{
    unit = ADC_UNIT_1;  // Only use ADC1 to avoid Wi-Fi conflict

    // ESP32-S3: ADC1 on GPIO1–10 → CH0–CH9
    if (gpio >= 1 && gpio <= 10)
    {
        channel = static_cast<adc_channel_t>(gpio - 1);
        return true;
    }

    channel = ADC_CHANNEL_0;
    return false;
}

bool AdcSampler::create_calibration(adc_cali_handle_t* handle)
{
    // ESP32-S3 uses curve fitting calibration
    adc_cali_curve_fitting_config_t cal_cfg = {
        .unit_id = unit_,
        .chan = channel_,
        .atten = atten_,
        .bitwidth = bitwidth_,
    };
    return adc_cali_create_scheme_curve_fitting(&cal_cfg, handle) == ESP_OK;
}

void AdcSampler::delete_calibration(adc_cali_handle_t handle)
{
    adc_cali_delete_scheme_curve_fitting(handle);
}

#endif  // CONFIG_IDF_TARGET_ESP32S3
