#pragma once
#include <LovyanGFX.hpp>
#include <stdint.h>

// ============================================================
//  矢量地图导航（手机发几何数据，ESP32 本地渲染并随车头旋转）
//
//  二进制包（写在同一个 NAV 特征值上，首字节区分）：
//   0x01 MAP_BEGIN : u32 total, u16 lines, i32 refLatE7, i32 refLonE7, u8 unitM
//   0x02 MAP_CHUNK : u32 offset, u16 len, bytes[len]
//   0x03 MAP_END   : u32 crc32
//   0x10 POS       : i32 latE7, i32 lonE7, u16 hdg10, u16 spd10,
//                    u16 distM, u8 turn, u8 flags,
//                    i32 turnLatE7, i32 turnLonE7
// ============================================================

namespace mapnav {

struct Pos {
  bool     valid   = false;
  int32_t  latE7   = 0;
  int32_t  lonE7   = 0;
  uint16_t hdg10   = 0;   // 航向，0.1 度
  uint16_t spd10   = 0;   // 车速，0.1 km/h
  uint16_t distM   = 0;   // 到下一个转向的距离
  uint8_t  turn    = 0;   // Maneuver 枚举值
  uint8_t  flags   = 0;
  int32_t  turnLatE7 = 0;
  int32_t  turnLonE7 = 0;
};

// 分配缓冲区（失败则地图模式不可用，不影响箭头界面）
void begin();

// 处理一帧二进制数据，返回 true 表示确实是地图/位置包
bool handle(const uint8_t* data, size_t len);

bool ready();          // 有一份校验通过的地图
bool receiving();      // 正在收新地图（此时暂停重绘，避免显示半包数据）
const Pos& pos();      // 最近一次位置

// 在 (0,28)-(320,212) 区域内绘制地图
void render(LovyanGFX& g);

// 切换导航/断开时调用
void reset();

// 传输进度 0~100（调试用）
int transferPercent();

}  // namespace mapnav
