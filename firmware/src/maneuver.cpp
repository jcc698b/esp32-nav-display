#include "maneuver.h"

#include <cmath>

#ifndef M_PI
#define M_PI 3.14159265358979323846f
#endif

namespace {

void dot(LovyanGFX& g, float x, float y, float r, uint16_t c) {
  g.fillCircle((int32_t)lroundf(x), (int32_t)lroundf(y), (int32_t)lroundf(r), c);
}

// 用一串实心圆拼出一条粗线，端点天然是圆的
void seg(LovyanGFX& g, float x0, float y0, float x1, float y1, float w, uint16_t c) {
  float dx = x1 - x0, dy = y1 - y0;
  float len = sqrtf(dx * dx + dy * dy);
  int   steps = (int)(len / (w * 0.30f));
  if (steps < 1) steps = 1;
  float r = w * 0.5f;
  for (int i = 0; i <= steps; i++) {
    float t = (float)i / (float)steps;
    dot(g, x0 + dx * t, y0 + dy * t, r, c);
  }
}

void poly(LovyanGFX& g, const float* pts, int n, float w, uint16_t c) {
  for (int i = 0; i + 1 < n; i++) {
    seg(g, pts[i * 2], pts[i * 2 + 1], pts[(i + 1) * 2], pts[(i + 1) * 2 + 1], w, c);
  }
}

// 箭头：tip 是尖端，ang 是前进方向（弧度，0=向右，-PI/2=向上）
void head(LovyanGFX& g, float tipX, float tipY, float ang, float len, float w, uint16_t c) {
  float bx = tipX - cosf(ang) * len;
  float by = tipY - sinf(ang) * len;
  float px = -sinf(ang) * w * 0.95f;
  float py = cosf(ang) * w * 0.95f;
  g.fillTriangle((int32_t)lroundf(tipX), (int32_t)lroundf(tipY),
                 (int32_t)lroundf(bx + px), (int32_t)lroundf(by + py),
                 (int32_t)lroundf(bx - px), (int32_t)lroundf(by - py), c);
}

}  // namespace

void drawManeuverIcon(LovyanGFX& g, Maneuver m, int cx, int cy, int size, uint16_t color) {
  if (m == Maneuver::None) return;

  const float h = size * 0.5f;
  const float w = fmaxf(3.0f, size * 0.115f);
  const float ox = (float)cx, oy = (float)cy;

  // 局部坐标 -> 屏幕坐标
  auto X = [&](float x) { return ox + x * h; };
  auto Y = [&](float y) { return oy + y * h; };

  // 由归一化点集生成实际坐标
  auto buf = [&](const float* in, int n, float* out) {
    for (int i = 0; i < n; i++) {
      out[i * 2]     = X(in[i * 2]);
      out[i * 2 + 1] = Y(in[i * 2 + 1]);
    }
  };

  float p[16 * 2];

  switch (m) {
    case Maneuver::Straight: {
      static const float q[] = {0, 0.85f, 0, -0.30f};
      buf(q, 2, p);
      poly(g, p, 2, w, color);
      head(g, X(0), Y(-0.90f), -M_PI / 2, h * 0.55f, w, color);
    } break;

    case Maneuver::Depart: {
      static const float q[] = {0, 0.55f, 0, -0.35f};
      buf(q, 2, p);
      poly(g, p, 2, w, color);
      dot(g, X(0), Y(0.72f), w * 0.95f, color);
      head(g, X(0), Y(-0.85f), -M_PI / 2, h * 0.55f, w, color);
    } break;

    case Maneuver::Left: {
      static const float q[] = {0, 0.85f, 0, -0.05f, -0.35f, -0.05f};
      buf(q, 3, p);
      poly(g, p, 3, w, color);
      head(g, X(-0.88f), Y(-0.05f), M_PI, h * 0.55f, w, color);
    } break;

    case Maneuver::Right: {
      static const float q[] = {0, 0.85f, 0, -0.05f, 0.35f, -0.05f};
      buf(q, 3, p);
      poly(g, p, 3, w, color);
      head(g, X(0.88f), Y(-0.05f), 0, h * 0.55f, w, color);
    } break;

    case Maneuver::SlightLeft: {
      static const float q[] = {0.18f, 0.85f, -0.30f, -0.35f};
      buf(q, 2, p);
      poly(g, p, 2, w, color);
      head(g, X(-0.48f), Y(-0.72f), atan2f(-1.2f, -0.48f), h * 0.55f, w, color);
    } break;

    case Maneuver::SlightRight: {
      static const float q[] = {-0.18f, 0.85f, 0.30f, -0.35f};
      buf(q, 2, p);
      poly(g, p, 2, w, color);
      head(g, X(0.48f), Y(-0.72f), atan2f(-1.2f, 0.48f), h * 0.55f, w, color);
    } break;

    case Maneuver::SharpLeft: {
      static const float q[] = {0.05f, 0.85f, 0.05f, 0.02f, -0.35f, -0.48f};
      buf(q, 3, p);
      poly(g, p, 3, w, color);
      head(g, X(-0.55f), Y(-0.70f), atan2f(-0.5f, -0.4f), h * 0.55f, w, color);
    } break;

    case Maneuver::SharpRight: {
      static const float q[] = {-0.05f, 0.85f, -0.05f, 0.02f, 0.35f, -0.48f};
      buf(q, 3, p);
      poly(g, p, 3, w, color);
      head(g, X(0.55f), Y(-0.70f), atan2f(-0.5f, 0.4f), h * 0.55f, w, color);
    } break;

    case Maneuver::UTurn: {
      // 上去 -> 半圆掉头 -> 下来
      float pts[64 * 2];
      int   n = 0;
      auto  push = [&](float x, float y) {
        if (n < 64) {
          pts[n * 2]     = X(x);
          pts[n * 2 + 1] = Y(y);
          n++;
        }
      };
      push(0.34f, 0.88f);
      push(0.34f, -0.02f);
      // 三次贝塞尔画上面那个弯
      const float x0 = 0.34f, y0 = -0.02f;
      const float x1 = 0.34f, y1 = -0.86f;
      const float x2 = -0.30f, y2 = -0.86f;
      const float x3 = -0.30f, y3 = -0.02f;
      for (int i = 1; i <= 20; i++) {
        float t = (float)i / 20.0f, u = 1.0f - t;
        float bx = u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3;
        float by = u * u * u * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3;
        push(bx, by);
      }
      push(-0.30f, 0.30f);
      poly(g, pts, n, w, color);
      head(g, X(-0.30f), Y(0.62f), M_PI / 2, h * 0.55f, w, color);
    } break;

    case Maneuver::Roundabout: {
      const float r = h * 0.42f;
      float pts[80 * 2];
      int   n = 0;
      for (int i = 0; i <= 48; i++) {
        float a = -M_PI * 0.55f + (float)i / 48.0f * M_PI * 1.95f;
        pts[n * 2]     = ox + cosf(a) * r;
        pts[n * 2 + 1] = oy + sinf(a) * r;
        n++;
      }
      poly(g, pts, n, w * 0.9f, color);
      // 入口
      seg(g, ox, oy + h * 0.92f, ox, oy + r, w * 0.9f, color);
      // 出口箭头（左上，沿切线方向）
      head(g, ox + cosf(-M_PI * 0.62f) * r, oy + sinf(-M_PI * 0.62f) * r,
           -M_PI * 0.62f + M_PI / 2, h * 0.42f, w * 0.9f, color);
    } break;

    case Maneuver::Merge: {
      static const float q[] = {0.10f, 0.85f, 0.10f, -0.35f};
      buf(q, 2, p);
      poly(g, p, 2, w, color);
      seg(g, X(-0.92f), Y(0.30f), X(-0.02f), Y(-0.22f), w * 0.85f, color);
      head(g, X(0.10f), Y(-0.88f), -M_PI / 2, h * 0.55f, w, color);
    } break;

    case Maneuver::Fork: {
      static const float q[] = {0, 0.85f, 0, 0.08f};
      buf(q, 2, p);
      poly(g, p, 2, w * 0.9f, color);
      seg(g, X(0), Y(0.08f), X(0.52f), Y(-0.62f), w * 0.9f, color);
      head(g, X(0.58f), Y(-0.72f), atan2f(-0.7f, 0.52f), h * 0.5f, w * 0.9f, color);
      seg(g, X(0), Y(0.08f), X(-0.34f), Y(-0.72f), w * 0.9f, color);
      head(g, X(-0.36f), Y(-0.80f), atan2f(-0.8f, -0.34f), h * 0.5f, w * 0.9f, color);
    } break;

    case Maneuver::Ramp: {
      static const float q[] = {0.35f, 0.88f, 0.35f, 0.10f, 0.02f, -0.35f};
      buf(q, 3, p);
      poly(g, p, 3, w, color);
      head(g, X(0.02f), Y(-0.82f), atan2f(-0.45f, -0.33f), h * 0.55f, w, color);
    } break;

    case Maneuver::Arrive: {
      // 旗杆
      seg(g, X(-0.28f), Y(0.90f), X(-0.28f), Y(-0.86f), w * 0.8f, color);
      // 格纹旗
      const float fx0 = -0.24f, fy0 = -0.88f, cw = 0.28f, ch = 0.21f;
      for (int row = 0; row < 3; row++) {
        for (int col = 0; col < 3; col++) {
          if ((row + col) % 2) continue;
          int ax = (int)lroundf(X(fx0 + col * cw));
          int ay = (int)lroundf(Y(fy0 + row * ch));
          int bw = (int)lroundf(cw * h) + 1;
          int bh = (int)lroundf(ch * h) + 1;
          g.fillRect(ax, ay, bw, bh, color);
        }
      }
      g.drawRect((int)lroundf(X(fx0)), (int)lroundf(Y(fy0)),
                 (int)lroundf(cw * 3 * h), (int)lroundf(ch * 3 * h), color);
    } break;

    case Maneuver::None:
    default:
      break;
  }
}
