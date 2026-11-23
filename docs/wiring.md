# 接线（ST7789 2.8 寸 240x320 SPI 屏）

## 屏幕引脚

市面上 2.8 寸 ST7789 模块的丝印不太统一，常见的是 8 针：

| 模块丝印 | 含义 | ESP32-S3（本项目默认） |
| --- | --- | --- |
| VCC | 电源 3.3V | 3V3 |
| GND | 地 | GND |
| SCL / SCK / CLK | SPI 时钟 | GPIO12 |
| SDA / MOSI / DIN | SPI 数据 | GPIO11 |
| RES / RST | 复位 | GPIO14 |
| DC / RS | 数据/命令选择 | GPIO13 |
| CS | 片选 | GPIO10 |
| BLK / LED / BL | 背光 | GPIO9 |

MISO 不用接（ST7789 只写不读）。

> 丝印顺序各厂不同，**认名字不要认位置**。有的板子多一个 `TP_*`（触摸）引脚，本项目不用触摸。

## 改引脚

全部集中在 [`firmware/include/config.h`](../firmware/include/config.h)：

```cpp
#define TFT_SCLK 12
#define TFT_MOSI 11
#define TFT_DC   13
#define TFT_CS   10
#define TFT_RST  14
#define TFT_BL   9
```

注意避开：

- GPIO19 / GPIO20：USB（用 USB 供电/串口时会冲突）
- GPIO26 ~ GPIO37：Flash / PSRAM
- GPIO0 / 3 / 45 / 46：启动绑带脚
- 输入专用脚：GPIO46 等

ESP32-S3 的 SPI 可以走 GPIO 矩阵，上面这组不是硬件固定脚，随便换到其它空闲脚也行。

## 电源

- 屏幕逻辑 3.3V，背光 LED 通常串了限流电阻，直接 3.3V 即可。
- 2.8 寸屏背光电流约 60~120mA，加上 ESP32-S3（WiFi 关闭、BLE 开）约 80~120mA，**USB 供电够用**，但不要用劣质线。
- 屏和板子务必共地，否则会花屏/闪屏。

## 接线检查顺序

1. 只接 VCC/GND/BLK，通电应该看到**白屏**（背光亮）。看不到就先查背光和供电。
2. 接上 SCL/SDA/DC/RES/CS，烧固件。
3. 如果白屏但无图像：查 DC、CS、RST 三根线，和 `config.h` 是否一致。
4. 图像花/闪：把 `display.cpp` 里 `freq_write` 从 40MHz 降到 20MHz 试试，杜邦线越长越要降。

## 可选：加一个外壳

2.8 寸屏的四个安装孔一般是 2.5mm 或 3mm，用 M2.5 铜柱固定到车台/支架即可。屏幕背面别贴金属，SPI 排线远离车上的 12V 线束，减少干扰。
