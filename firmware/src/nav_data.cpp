#include "nav_data.h"

#include <ArduinoJson.h>
#include <cstring>

NavState g_nav;

struct ManeuverName {
  Maneuver    m;
  const char* key;   // 协议里的写法
  const char* zh;    // 中文名（调试 / 兜底显示）
};

static const ManeuverName kManeuvers[] = {
    {Maneuver::None,        "none",         ""},
    {Maneuver::Depart,      "depart",       "出发"},
    {Maneuver::Straight,    "straight",     "直行"},
    {Maneuver::SlightLeft,  "slight-left",  "稍向左"},
    {Maneuver::Left,        "left",         "左转"},
    {Maneuver::SharpLeft,   "sharp-left",   "急左转"},
    {Maneuver::SlightRight, "slight-right", "稍向右"},
    {Maneuver::Right,       "right",        "右转"},
    {Maneuver::SharpRight,  "sharp-right",  "急右转"},
    {Maneuver::UTurn,       "uturn",        "掉头"},
    {Maneuver::Roundabout,  "roundabout",   "环岛"},
    {Maneuver::Merge,       "merge",        "汇入"},
    {Maneuver::Fork,        "fork",         "岔路"},
    {Maneuver::Ramp,        "ramp",         "匝道"},
    {Maneuver::Arrive,      "arrive",       "到达"},
};

Maneuver maneuverFromString(const char* s) {
  if (!s || !*s) return Maneuver::None;
  for (const auto& it : kManeuvers) {
    if (strcmp(s, it.key) == 0) return it.m;
  }
  // 兼容几个常见别名
  if (strcmp(s, "u-turn") == 0 || strcmp(s, "uturn-left") == 0) return Maneuver::UTurn;
  if (strcmp(s, "slight_left") == 0) return Maneuver::SlightLeft;
  if (strcmp(s, "slight_right") == 0) return Maneuver::SlightRight;
  if (strcmp(s, "arrive-left") == 0 || strcmp(s, "arrive-right") == 0) return Maneuver::Arrive;
  return Maneuver::None;
}

const char* maneuverToString(Maneuver m) {
  for (const auto& it : kManeuvers) {
    if (it.m == m) return it.key;
  }
  return "none";
}

const char* maneuverLabelZh(Maneuver m) {
  for (const auto& it : kManeuvers) {
    if (it.m == m) return it.zh;
  }
  return "";
}

void navReset(NavState& s) {
  s.navigating   = false;
  s.arrived      = false;
  s.stale        = false;
  s.maneuver     = Maneuver::None;
  s.nextManeuver = Maneuver::None;
  s.distM        = -1;
  s.nextDistM    = -1;
  s.remainM      = -1;
  s.remainSec    = -1;
  s.speedKmh     = -1;
  s.phoneBat     = 255;
  s.road[0]      = 0;
  s.eta[0]       = 0;
}

static void copyStr(char* dst, size_t cap, const char* src) {
  if (!src) {
    dst[0] = 0;
    return;
  }
  strlcpy(dst, src, cap);
}

bool navParseJson(const char* json, size_t len, NavState& s) {
  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, json, len);
  if (err) {
    Serial.printf("[nav] JSON 解析失败: %s\n", err.c_str());
    return false;
  }

  // 协议版本，缺省按 1 处理
  int v = doc["v"] | 1;
  if (v != 1) {
    Serial.printf("[nav] 未知协议版本 %d\n", v);
    return false;
  }

  const char* st = doc["st"] | "idle";
  s.arrived    = (strcmp(st, "arr") == 0);
  s.navigating = (strcmp(st, "nav") == 0);
  if (!s.navigating) {
    s.maneuver     = Maneuver::None;
    s.nextManeuver = Maneuver::None;
    s.distM        = -1;
    s.nextDistM    = -1;
    s.remainM      = -1;
    s.remainSec    = -1;
    s.speedKmh     = -1;
    s.road[0]      = 0;
    s.eta[0]       = 0;
  }

  s.maneuver     = maneuverFromString(doc["mn"] | "");
  s.nextManeuver = maneuverFromString(doc["nx"] | "");
  s.distM        = doc["d"]   | -1;
  s.nextDistM    = doc["nd"]  | -1;
  s.remainM      = doc["rem"] | -1;
  s.remainSec    = doc["rt"]  | -1;
  s.speedKmh     = doc["spd"] | -1;
  s.phoneBat     = doc["bat"] | 255;

  copyStr(s.road, sizeof(s.road), doc["rd"] | "");
  copyStr(s.eta, sizeof(s.eta), doc["eta"] | "");

  s.stale   = false;
  s.lastRxMs = millis();
  s.rxCount++;
  return true;
}
