#pragma once
#include <LovyanGFX.hpp>
#include "config.h"

// LovyanGFX 设备定义：ESP32-S3 + ST7789 (SPI)
class LGFX : public lgfx::LGFX_Device {
  lgfx::Panel_ST7789 _panel;
  lgfx::Bus_SPI      _bus;
  lgfx::Light_PWM    _light;

 public:
  LGFX();
};

extern LGFX tft;
