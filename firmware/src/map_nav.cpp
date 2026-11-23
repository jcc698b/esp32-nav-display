#include "map_nav.h"

#include <Arduino.h>
#include <cmath>
#include <cstring>
#include <esp_heap_caps.h>

#include "config.h"
#include "nav_data.h"

namespace {

constexpr int MAP_TOP = 28;      // 顶部状态栏下面
constexpr int MAP_BOTTOM = 206;  // 底部信息条上面
constexpr int MAP_W = 320;
constexpr int MAP_H = MAP_BOTTOM - MAP_TOP;
constexpr float SCALE = 1.15f;   // 像素/米：320px ≈ 278m

constexpr uint16_t rgb565(uint8_t r, uint8_t g, uint8_t b) {
  return (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}

constexpr uint16_t C_BG      = rgb565(9, 13, 18);
constexpr uint16_t C_MINOR   = rgb565(38, 46, 57);
constexpr uint16_t C_SECOND  = rgb565(52, 63, 77);
constexpr uint16_t C_PRIMARY = rgb565(70, 84, 102);
constexpr uint16_t C_ROUTE   = rgb565(61, 220, 132);
constexpr uint16_t C_ROUTE_E = rgb565(11, 58, 34);
constexpr uint16_t C_TURN    = rgb565(255, 176, 32);
constexpr uint16_t C_MARK    = rgb565(245, 248, 255);
constexpr uint16_t C_MARK_O  = rgb565(10, 14, 19);

uint8_t* s_buf   = nullptr;
size_t   s_cap   = MAP_BUF_SIZE;
uint32_t s_total = 0;
uint32_t s_recv  = 0;
uint16_t s_lines = 0;
int32_t  s_refLat = 0;
int32_t  s_refLon = 0;
uint8_t  s_unit   = 2;
bool     s_rx     = false;
bool     s_ready  = false;
uint32_t s_rxStartMs = 0;

mapnav::Pos s_pos;
uint32_t    s_lastPosMs = 0;

inline uint16_t rd16(const uint8_t* p) {
  uint16_t v;
  memcpy(&v, p, 2);
  return v;
}
inline uint32_t rd32(const uint8_t* p) {
  uint32_t v;
  memcpy(&v, p, 4);
  return v;
}
inline int16_t rdi16(const uint8_t* p) {
  int16_t v;
  memcpy(&v, p, 2);
  return v;
}
inline int32_t rdi32(const uint8_t* p) {
  int32_t v;
  memcpy(&v, p, 4);
  return v;
}

uint32_t crc32(const uint8_t* d, size_t n) {
  uint32_t c = 0xFFFFFFFFu;
  for (size_t i = 0; i < n; i++) {
    c ^= d[i];
    for (int k = 0; k < 8; k++) {
      c = (c & 1) ? (c >> 1) ^ 0xEDB88320u : (c >> 1);
    }
  }
  return c ^ 0xFFFFFFFFu;
}

// Liang-Barsky 裁剪
bool clipLine(float& x0, float& y0, float& x1, float& y1) {
  const float xmin = 0, xmax = MAP_W;
  const float ymin = MAP_TOP, ymax = MAP_BOTTOM;
  float dx = x1 - x0, dy = y1 - y0;
  float t0 = 0, t1 = 1;

  auto edge = [&](float p, float q) -> bool {
    if (fabsf(p) < 1e-6f) return q >= 0;
    float r = q / p;
    if (p < 0) {
      if (r > t1) return false;
      if (r > t0) t0 = r;
    } else {
      if (r < t0) return false;
      if (r < t1) t1 = r;
    }
    return true;
  };

  if (!edge(-dx, x0 - xmin)) return false;
  if (!edge(dx, xmax - x0)) return false;
  if (!edge(-dy, y0 - ymin)) return false;
  if (!edge(dy, ymax - y0)) return false;

  float nx0 = x0 + t0 * dx;
  float ny0 = y0 + t0 * dy;
  float nx1 = x0 + t1 * dx;
  float ny1 = y0 + t1 * dy;
  x0 = nx0; y0 = ny0; x1 = nx1; y1 = ny1;
  return true;
}

void thickLine(LovyanGFX& g, float x0, float y0, float x1, float y1, float w, uint16_t c) {
  float dx = x1 - x0, dy = y1 - y0;
  float len = sqrtf(dx * dx + dy * dy);
  if (len < 0.05f) return;
  float nx = -dy / len, ny = dx / len;
  int   half = (int)(w * 0.5f);
  for (int i = -half; i <= half; i++) {
    g.drawLine((int)lroundf(x0 + nx * i), (int)lroundf(y0 + ny * i),
               (int)lroundf(x1 + nx * i), (int)lroundf(y1 + ny * i), c);
  }
}

}  // namespace

namespace mapnav {

void begin() {
  s_buf = (uint8_t*)heap_caps_malloc(MAP_BUF_SIZE, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (!s_buf) s_buf = (uint8_t*)heap_caps_malloc(MAP_BUF_SIZE, MALLOC_CAP_8BIT);
  s_cap = s_buf ? MAP_BUF_SIZE : 0;
  Serial.printf("[map] 地图缓冲 %u 字节 %s，可用堆 %u\n", (unsigned)s_cap, s_buf ? "OK" : "失败",
                (unsigned)ESP.getFreeHeap());
}

void reset() {
  s_ready   = false;
  s_rx      = false;
  s_recv    = 0;
  s_total   = 0;
  s_lines   = 0;
  s_pos     = Pos();
  s_lastPosMs = 0;
}

bool ready() { return s_ready; }
bool receiving() {
  // 传输超时保护：半包卡住时恢复界面，避免一直冻结
  if (s_rx && millis() - s_rxStartMs > 6000) {
    s_rx = false;
    s_ready = false;
    Serial.println("[map] 传输超时，丢弃");
  }
  return s_rx;
}
const Pos& pos() { return s_pos; }
int transferPercent() {
  if (!s_rx || s_total == 0) return 0;
  int p = (int)(s_recv * 100u / s_total);
  return p > 100 ? 100 : p;
}

bool handle(const uint8_t* d, size_t n) {
  if (!s_buf || n == 0) return false;
  const uint8_t type = d[0];

  if (type == 0x01) {  // MAP_BEGIN
    if (n < 16) return true;
    uint32_t total = rd32(d + 1);
    uint16_t lines = rd16(d + 5);
    int32_t  rlat  = rdi32(d + 7);
    int32_t  rlon  = rdi32(d + 11);
    uint8_t  unit  = d[15];
    if (total == 0 || total > s_cap || lines == 0 || unit == 0) {
      Serial.printf("[map] 包非法 total=%u lines=%u\n", total, lines);
      s_rx = false;
      return true;
    }
    s_total = total;
    s_lines = lines;
    s_refLat = rlat;
    s_refLon = rlon;
    s_unit = unit;
    s_recv = 0;
    s_rx = true;
    s_rxStartMs = millis();
    Serial.printf("[map] 开始接收 %u 字节, %u 条线\n", total, lines);
    return true;
  }

  if (type == 0x02) {  // MAP_CHUNK
    if (!s_rx || n < 7) return true;
    uint32_t off = rd32(d + 1);
    uint16_t len = rd16(d + 5);
    if (off + len > s_total || 7u + len > n) return true;
    memcpy(s_buf + off, d + 7, len);
    s_recv += len;
    return true;
  }

  if (type == 0x03) {  // MAP_END
    if (!s_rx || n < 5) return true;
    uint32_t crc = rd32(d + 1);
    bool ok = (s_recv >= s_total) && (crc32(s_buf, s_total) == crc);
    if (ok) {
      s_ready = true;
      Serial.printf("[map] 地图就绪: %u 字节\n", s_total);
    } else {
      s_ready = false;   // 数据已被这次传输覆盖，旧图不能再用
      Serial.printf("[map] 校验失败 recv=%u total=%u\n", s_recv, s_total);
    }
    s_rx = false;
    return true;
  }

  if (type == 0x10) {  // POS
    if (n < 25) return true;
    s_pos.latE7     = rdi32(d + 1);
    s_pos.lonE7     = rdi32(d + 5);
    s_pos.hdg10     = rd16(d + 9);
    s_pos.spd10     = rd16(d + 11);
    s_pos.distM     = rd16(d + 13);
    s_pos.turn      = d[15];
    s_pos.flags     = d[16];
    s_pos.turnLatE7 = rdi32(d + 17);
    s_pos.turnLonE7 = rdi32(d + 21);
    s_pos.valid     = true;
    s_lastPosMs     = millis();
    return true;
  }

  return false;
}

void render(LovyanGFX& g) {
  g.fillRect(0, MAP_TOP, MAP_W, MAP_H, C_BG);
  if (!s_ready || s_total < 2) return;

  const bool hasPos = s_pos.valid && (millis() - s_lastPosMs < 6000);

  // 参考点（路线起点），所有点都是相对它的偏移
  const float refLat = s_refLat / 1e7f;
  const float refLon = s_refLon / 1e7f;
  const float mPerDegLat = 110540.0f;
  const float mPerDegLon = 111320.0f * cosf(refLat * (float)M_PI / 180.0f);

  float camX = 0, camY = 0;
  float heading = 0;

  if (hasPos) {
    camX = (s_pos.lonE7 / 1e7f - refLon) * mPerDegLon;
    camY = (s_pos.latE7 / 1e7f - refLat) * mPerDegLat;
    heading = (s_pos.hdg10 / 10.0f) * (float)M_PI / 180.0f;
  }

  const float sinH = sinf(heading);
  const float cosH = cosf(heading);
  const float unit = s_unit;

  auto project = [&](int16_t px, int16_t py, float& sx, float& sy) {
    float ex = px * unit - camX;
    float ny = py * unit - camY;
    sx = MAP_W * 0.5f + (ex * cosH - ny * sinH) * SCALE;
    sy = 148.0f - (ex * sinH + ny * cosH) * SCALE;
  };

  const uint8_t* p   = s_buf;
  const uint8_t* end = s_buf + s_total;
  if (s_buf + 2 > end) return;
  uint16_t lines = rd16(p);
  p += 2;
  if (lines > s_lines) lines = s_lines;

  // 两遍：先画普通道路，再画路线，保证路线在最上层
  for (int pass = 0; pass < 2; pass++) {
    p = s_buf + 2;
    for (uint16_t i = 0; i < lines && p + 3 <= end; i++) {
      uint8_t  kind = *p++;
      uint16_t cnt  = rd16(p);
      p += 2;
      if (p + (size_t)cnt * 4 > end) return;

      const bool isRoute = (kind == 3);
      if ((pass == 0) != isRoute) {  // pass0 只画普通道路
        p += (size_t)cnt * 4;
        continue;
      }

      float prevX = 0, prevY = 0;
      bool  hasPrev = false;

      for (uint16_t k = 0; k < cnt; k++) {
        int16_t wx = rdi16(p);
        int16_t wy = rdi16(p + 2);
        p += 4;

        float sx, sy;
        project(wx, wy, sx, sy);

        if (hasPrev) {
          float x0 = prevX, y0 = prevY, x1 = sx, y1 = sy;
          if (clipLine(x0, y0, x1, y1)) {
            if (isRoute) {
              thickLine(g, x0, y0, x1, y1, 5.5f, C_ROUTE);
            } else if (kind == 2) {
              g.drawLine((int)lroundf(x0), (int)lroundf(y0), (int)lroundf(x1),
                         (int)lroundf(y1), C_PRIMARY);
            } else if (kind == 1) {
              g.drawLine((int)lroundf(x0), (int)lroundf(y0), (int)lroundf(x1),
                         (int)lroundf(y1), C_SECOND);
            } else {
              g.drawLine((int)lroundf(x0), (int)lroundf(y0), (int)lroundf(x1),
                         (int)lroundf(y1), C_MINOR);
            }
          }
        }
        prevX = sx;
        prevY = sy;
        hasPrev = true;
      }
    }
  }

  // 下一个转向点
  if (hasPos && s_pos.turn != 0 && s_pos.distM < 3000) {
    float ex = (s_pos.turnLonE7 / 1e7f - refLon) * mPerDegLon - camX;
    float ny = (s_pos.turnLatE7 / 1e7f - refLat) * mPerDegLat - camY;
    float sx = MAP_W * 0.5f + (ex * cosH - ny * sinH) * SCALE;
    float sy = 148.0f - (ex * sinH + ny * cosH) * SCALE;
    if (sx > 4 && sx < MAP_W - 4 && sy > MAP_TOP + 4 && sy < MAP_BOTTOM - 4) {
      g.fillCircle((int)sx, (int)sy, 7, C_TURN);
      g.fillCircle((int)sx, (int)sy, 3, C_BG);
    }
  }

  // 本车位置（地图随车头旋转，所以永远朝上）
  const int cx = MAP_W / 2, cy = 148;
  g.fillTriangle(cx, cy - 12, cx - 9, cy + 9, cx + 9, cy + 9, C_MARK_O);
  g.fillTriangle(cx, cy - 8, cx - 6, cy + 6, cx + 6, cy + 6, C_MARK);
}

}  // namespace mapnav
