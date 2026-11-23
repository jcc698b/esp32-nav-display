#pragma once
// ============================================================
//  硬件与行为配置
//  - 屏幕：2.8 寸 ST7789 240x320 SPI 屏（8 针模块）
//  - MCU ：ESP32-S3（任意带 BLE 的型号）
//  改接线只需要改这一页。
// ============================================================

// ---------- ST7789 接线 ----------------------------------------------------
// ESP32-S3 可用引脚很多，这里挑的是 9~14，避开了 USB(19/20)、
// Flash/PSRAM(26~37) 和启动绑带脚(0/3/45/46)。
#define TFT_SCLK 12   // SCK / CLK
#define TFT_MOSI 11   // SDA / MOSI / DIN
#define TFT_MISO (-1) // ST7789 只写不读，不接
#define TFT_DC   13   // DC / RS
#define TFT_CS   10   // CS  （模块没有 CS 时接 GND，并把这里设为 -1）
#define TFT_RST  14   // RES / RST
#define TFT_BL   9    // BLK / LED 背光，PWM 调光

// 面板分辨率（面板原生方向是竖屏 240x320）
#define TFT_WIDTH  240
#define TFT_HEIGHT 320

// 旋转：1 = 横屏 320x240（推荐，装车上看）
#define TFT_ROTATION 1
#define TFT_BRIGHTNESS 230

// 如果颜色发灰/反色，改这两个
#define TFT_INVERT_COLOR 1   // 多数 IPS 模块需要 true
#define TFT_RGB_ORDER_BGR 0  // 偏色（红蓝互换）时改成 1

// ---------- 按键 ----------------------------------------------------------
// 开发板自带的 BOOT 键。运行中长按 2 秒切换「演示模式」，方便没手机时试屏。
#define PIN_BTN 0

// ---------- 设备信息 ------------------------------------------------------
#define DEVICE_NAME "ESP32-Navi"
#define FW_VERSION  "1.0.0"

// ---------- 行为参数 ------------------------------------------------------
#define NAV_TIMEOUT_MS 8000   // 超过这么久没收到手机数据就标记为「数据超时」
#define UI_IDLE_FPS    2      // 空闲时刷新率
#define UI_NAV_FPS     8      // 导航时刷新率
#define BLE_MTU        247    // 协商 MTU，单包可到 244 字节

// ---------- 矢量地图 ------------------------------------------------------
// 手机一次发来的地图数据上限（约 6000 个点，4 字节/点）
#define MAP_BUF_SIZE 24576
#define MAP_FPS      8

