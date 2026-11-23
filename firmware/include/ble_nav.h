#pragma once
#include <stdint.h>

namespace ble_nav {

// 初始化 BLE 外设并开始广播
void begin();

// 主循环调用：把收到的数据包解析进 g_nav，并定期更新状态特征值
void poll();

// 当前是否有手机连着
bool connected();

}  // namespace ble_nav
