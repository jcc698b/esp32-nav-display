#include <Arduino.h>

#include "ble_nav.h"
#include "config.h"
#include "display.h"
#include "map_nav.h"
#include "nav_data.h"
#include "ui.h"

// BOOT 键长按 2 秒：切换演示模式
static void handleButton(uint32_t now) {
  static uint32_t downAt  = 0;
  static bool     fired   = false;

  bool pressed = (digitalRead(PIN_BTN) == LOW);

  if (!pressed) {
    downAt = 0;
    fired  = false;
    return;
  }
  if (downAt == 0) downAt = now ? now : 1;
  if (!fired && now - downAt >= 2000) {
    fired = true;
    ui::setDemo(!ui::demo());
    Serial.printf("[btn] 演示模式 = %s\n", ui::demo() ? "开" : "关");
  }
}

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println();
  Serial.println("========================================");
  Serial.println(" ESP32-S3 蓝牙导航副屏  " FW_VERSION);
  Serial.printf(" 芯片: %s  核心: %d  Flash: %uMB\n", ESP.getChipModel(), ESP.getChipCores(),
                (unsigned)(ESP.getFlashChipSize() / (1024 * 1024)));
  Serial.println("========================================");

  pinMode(PIN_BTN, INPUT_PULLUP);

  tft.init();
  tft.setRotation(TFT_ROTATION);
  tft.setBrightness(TFT_BRIGHTNESS);
  tft.fillScreen(0x0000);
  Serial.printf("[ui] 屏幕 %dx%d 旋转 %d\n", tft.width(), tft.height(), TFT_ROTATION);

  mapnav::begin();   // 先分配地图缓冲，再分配屏幕 Sprite，降低碎片风险
  ui::begin();
  ble_nav::begin();
  Serial.println("[sys] 就绪：手机打开 NavDisplay App 即可连接");
}

void loop() {
  uint32_t now = millis();
  ble_nav::poll();
  ui::tick(now);
  handleButton(now);
  delay(5);
}
