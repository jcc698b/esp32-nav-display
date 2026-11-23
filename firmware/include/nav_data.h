#pragma once
#include <Arduino.h>
#include <stdint.h>

// 转向动作类型（和 iOS 端约定的字符串一一对应）
enum class Maneuver : uint8_t {
  None = 0,
  Depart,
  Straight,
  SlightLeft,
  Left,
  SharpLeft,
  SlightRight,
  Right,
  SharpRight,
  UTurn,
  Roundabout,
  Merge,
  Fork,
  Ramp,
  Arrive,
};

// 整块屏幕的「当前状态」——BLE 收到什么就更新什么
struct NavState {
  bool connected  = false;   // BLE 是否连着
  bool navigating = false;   // 手机是否正在导航
  bool arrived    = false;   // 已到达
  bool stale      = false;   // 数据超时

  Maneuver maneuver     = Maneuver::None;
  Maneuver nextManeuver = Maneuver::None;

  int32_t distM     = -1;    // 到本动作的距离（米）
  int32_t nextDistM = -1;    // 到下一个动作的距离（米）
  int32_t remainM   = -1;    // 剩余总里程（米）
  int32_t remainSec = -1;    // 剩余时间（秒）
  int16_t speedKmh  = -1;    // 当前车速
  uint8_t phoneBat  = 255;   // 手机电量 0-100，255 表示未知

  char road[64] = {0};       // 道路名 / 指令
  char eta[8]   = {0};       // 预计到达时刻，手机本地时间 "18:42"

  uint32_t lastRxMs = 0;     // 最后一次收到数据的 millis()
  uint32_t rxCount  = 0;     // 收到的包数，用来判断刷新
};

// 全局唯一状态
extern NavState g_nav;

// 字符串 <-> 枚举
Maneuver    maneuverFromString(const char* s);
const char* maneuverToString(Maneuver m);
const char* maneuverLabelZh(Maneuver m);

// 解析手机下发的 JSON，成功返回 true
bool navParseJson(const char* json, size_t len, NavState& s);

// 清空（保留连接状态）
void navReset(NavState& s);
