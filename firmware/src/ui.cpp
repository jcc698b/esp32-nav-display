// ============================================================
//  320x240 横屏导航界面
//  布局：
//   ┌──────────────────────────────────────────┐
//   │ ● 导航中                        [电池]87%  │ 28
//   ├──────────┬───────────────────────────────┤
//   │          │  180 米                       │
//   │   箭头   │  人民大道                     │
//   │          │  然后 [图标] 右转 900 米       │
//   ├──────────┴───────────────────────────────┤
//   │ 到达 18:42 │ 剩余 12.4km │ 还需 32 分钟  │ 34
//   └──────────────────────────────────────────┘
// ============================================================
#include "ui.h"

#include <LovyanGFX.hpp>
#include <cmath>
#include <cstdio>
#include <cstring>

#include "config.h"
#include "display.h"
#include "maneuver.h"
#include "map_nav.h"
#include "nav_data.h"

namespace {

// ---------------- 颜色（RGB565）----------------
constexpr uint16_t rgb565(uint8_t r, uint8_t g, uint8_t b) {
  return (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}

constexpr uint16_t C_BG     = rgb565(9, 12, 17);
constexpr uint16_t C_PANEL  = rgb565(22, 27, 34);
constexpr uint16_t C_CARD   = rgb565(28, 34, 43);
constexpr uint16_t C_LINE   = rgb565(48, 56, 68);
constexpr uint16_t C_TEXT   = rgb565(230, 237, 243);
constexpr uint16_t C_DIM    = rgb565(139, 148, 158);
constexpr uint16_t C_ACCENT = rgb565(61, 220, 132);
constexpr uint16_t C_WARN   = rgb565(255, 176, 32);
constexpr uint16_t C_RED    = rgb565(255, 92, 92);
constexpr uint16_t C_BLUE   = rgb565(79, 168, 255);

constexpr int UI_W = 320;
constexpr int UI_H = 240;

// 字体
const lgfx::IFont* F_BIG  = &fonts::FreeSansBold24pt7b;
const lgfx::IFont* F_CN24 = &fonts::efontCN_24;
const lgfx::IFont* F_CN16 = &fonts::efontCN_16;
const lgfx::IFont* F_CN12 = &fonts::efontCN_12;

LGFX_Sprite s_canvas(&tft);
LovyanGFX*  s_g         = &tft;
bool        s_useCanvas = false;
bool        s_dirty     = true;
bool        s_demo      = false;

// ---------------- 文本小工具 ----------------
void drawStr(LovyanGFX& g, const char* s, int x, int y, const lgfx::IFont* font, uint16_t color,
             lgfx::textdatum_t datum = lgfx::textdatum_t::top_left) {
  g.setFont(font);
  g.setTextColor(color);
  g.setTextDatum(datum);
  g.drawString(s, x, y);
}

int u8len(uint8_t c) {
  if (c < 0x80) return 1;
  if ((c & 0xE0) == 0xC0) return 2;
  if ((c & 0xF0) == 0xE0) return 3;
  return 4;
}

// 按像素宽度截断，末尾加 ".."
String ellipsize(LovyanGFX& g, const String& s, int maxW) {
  g.setFont(F_CN16);
  if (g.textWidth(s.c_str()) <= maxW) return s;
  String out;
  size_t i = 0;
  while (i < s.length()) {
    int n = u8len((uint8_t)s[i]);
    if (i + n > s.length()) break;
    String cand = out + s.substring(i, i + n);
    String test = cand + "..";
    if (g.textWidth(test.c_str()) > maxW) break;
    out = cand;
    i += n;
  }
  return out + "..";
}

// 按宽度换行，最多 maxLines 行，最后一行自动截断
void drawWrapped(LovyanGFX& g, const String& s, int x, int y, int maxW, int lineH, int maxLines,
                 const lgfx::IFont* font, uint16_t color) {
  g.setFont(font);
  String line;
  int    drawn = 0;
  size_t i     = 0;

  while (i < s.length() && drawn < maxLines) {
    int    n  = u8len((uint8_t)s[i]);
    String ch = s.substring(i, i + n);

    if (line.length() && g.textWidth((line + ch).c_str()) > maxW) {
      if (drawn == maxLines - 1) {
        String rest = line + s.substring(i);
        String cut  = ellipsize(g, rest, maxW);
        drawStr(g, cut.c_str(), x, y + drawn * lineH, font, color);
        return;
      }
      drawStr(g, line.c_str(), x, y + drawn * lineH, font, color);
      drawn++;
      line = ch;
    } else {
      line += ch;
    }
    i += n;
  }

  if (line.length() && drawn < maxLines) {
    drawStr(g, line.c_str(), x, y + drawn * lineH, font, color);
  }
}

String fmtDistNum(int32_t m) {
  if (m < 0) return "--";
  if (m < 1000) return String(m);
  float km = m / 1000.0f;
  if (km < 10.0f) return String(km, 1);
  return String((int)(km + 0.5f));
}

const char* fmtDistUnit(int32_t m) {
  if (m < 0) return "";
  return m < 1000 ? "米" : "公里";
}

String fmtDistShort(int32_t m) {
  if (m < 0) return "--";
  if (m < 1000) return String(m) + "米";
  return String(m / 1000.0f, 1) + "公里";
}

String fmtDur(int32_t sec) {
  if (sec < 0) return "--";
  int32_t mins = sec / 60;
  if (mins < 1) return "1分钟";
  if (mins < 60) return String(mins) + "分钟";
  return String(mins / 60) + "小时" + String(mins % 60) + "分";
}

String fmtEta(const NavState& s) {
  if (s.eta[0]) return String(s.eta);
  return "--:--";
}

// ---------------- 小图标 ----------------
void drawBattery(LovyanGFX& g, int x, int y, int w, int h, int pct, uint16_t color) {
  g.drawRect(x, y, w, h, C_DIM);
  g.fillRect(x + w, y + h / 3, 2, h / 3, C_DIM);
  if (pct < 0) return;
  int fw = (w - 4) * pct / 100;
  if (fw < 1) fw = 1;
  g.fillRect(x + 2, y + 2, fw, h - 4, pct <= 20 ? C_RED : color);
}

void drawBleGlyph(LovyanGFX& g, int cx, int cy, int h, uint16_t color) {
  float s = h * 0.5f;
  auto  X = [&](float nx) { return cx + (int)lroundf(nx * s); };
  auto  Y = [&](float ny) { return cy + (int)lroundf(ny * s); };

  g.drawLine(cx, Y(-1), cx, Y(1), color);
  g.drawLine(X(0), Y(-1), X(0.62f), Y(-0.45f), color);
  g.drawLine(X(0.62f), Y(-0.45f), X(-0.25f), Y(0.25f), color);
  g.drawLine(X(0), Y(1), X(0.62f), Y(0.45f), color);
  g.drawLine(X(0.62f), Y(0.45f), X(-0.25f), Y(-0.25f), color);
}

void drawPhone(LovyanGFX& g, int cx, int cy, int h, uint16_t color) {
  int w = (int)(h * 0.58f);
  int x = cx - w / 2, y = cy - h / 2;
  g.drawRoundRect(x, y, w, h, 6, color);
  g.drawFastHLine(cx - 4, y + 3, 8, color);
  drawBleGlyph(g, cx, cy + 1, (int)(h * 0.38f), color);
}

// ---------------- 各区域 ----------------
void drawTopBar(LovyanGFX& g, const NavState& s) {
  g.fillRect(0, 0, UI_W, 28, C_PANEL);
  g.drawFastHLine(0, 28, UI_W, C_LINE);

  const char* label;
  uint16_t    color;
  if (s_demo) {
    label = "演示模式";
    color = C_BLUE;
  } else if (s.stale) {
    label = "数据超时";
    color = C_WARN;
  } else if (!s.connected) {
    label = "等待连接";
    color = C_DIM;
  } else if (s.arrived) {
    label = "已到达";
    color = C_ACCENT;
  } else if (s.navigating) {
    label = "导航中";
    color = C_ACCENT;
  } else {
    label = "已连接";
    color = C_ACCENT;
  }

  g.fillCircle(14, 14, 4, color);
  drawStr(g, label, 24, 14, F_CN16, color, lgfx::textdatum_t::middle_left);

  if (s.phoneBat <= 100) {
    char buf[8];
    snprintf(buf, sizeof(buf), "%d%%", s.phoneBat);
    g.setFont(F_CN16);
    int tw = (int)g.textWidth(buf);
    drawStr(g, buf, UI_W - 8, 14, F_CN16, C_DIM, lgfx::textdatum_t::middle_right);
    drawBattery(g, UI_W - 8 - tw - 30, 8, 22, 12, s.phoneBat, C_ACCENT);
  }
}

void drawArrowCard(LovyanGFX& g, const NavState& s) {
  const int x = 4, y = 32, w = 136, h = 170;
  g.fillRoundRect(x, y, w, h, 12, C_CARD);

  uint16_t c = C_ACCENT;
  if (s.maneuver == Maneuver::UTurn || s.maneuver == Maneuver::SharpLeft ||
      s.maneuver == Maneuver::SharpRight) {
    c = C_WARN;
  }
  if (s.stale) c = C_DIM;

  drawManeuverIcon(g, s.maneuver, x + w / 2, y + h / 2, 104, c);
}

void drawNavInfo(LovyanGFX& g, const NavState& s) {
  const int left  = 148;
  const int right = 316;

  // 距离
  String num  = fmtDistNum(s.distM);
  String unit = fmtDistUnit(s.distM);
  drawStr(g, num.c_str(), right, 34, F_BIG, s.stale ? C_DIM : C_ACCENT, lgfx::textdatum_t::top_right);
  drawStr(g, unit.c_str(), right, 68, F_CN16, C_DIM, lgfx::textdatum_t::top_right);

  // 道路 / 指令
  String road = s.road[0] ? String(s.road) : String(maneuverLabelZh(s.maneuver));
  if (!road.length()) road = "继续直行";
  drawWrapped(g, road, left, 92, 168, 21, 2, F_CN16, s.stale ? C_DIM : C_TEXT);

  // 下一步
  if (s.nextManeuver != Maneuver::None) {
    g.drawFastHLine(left, 140, 168, C_LINE);
    drawStr(g, "然后", left, 158, F_CN12, C_DIM, lgfx::textdatum_t::middle_left);
    drawManeuverIcon(g, s.nextManeuver, left + 36, 158, 24, s.stale ? C_DIM : C_TEXT);
    String nx = String(maneuverLabelZh(s.nextManeuver));
    if (s.nextDistM >= 0) nx += " " + fmtDistShort(s.nextDistM);
    nx = ellipsize(g, nx, 118);
    drawStr(g, nx.c_str(), left + 54, 158, F_CN16, s.stale ? C_DIM : C_TEXT,
            lgfx::textdatum_t::middle_left);
  }

  // 车速
  if (s.speedKmh >= 0) {
    char buf[16];
    snprintf(buf, sizeof(buf), "%d km/h", s.speedKmh);
    drawStr(g, buf, right, 188, F_CN12, C_DIM, lgfx::textdatum_t::bottom_right);
  }
}

void drawBottomBar(LovyanGFX& g, const NavState& s) {
  const int top = 206;
  g.fillRect(0, top, UI_W, UI_H - top, C_PANEL);
  g.drawFastHLine(0, top, UI_W, C_LINE);
  g.drawFastVLine(106, top + 4, 26, C_LINE);
  g.drawFastVLine(213, top + 4, 26, C_LINE);

  struct Cell {
    const char* label;
    String      value;
  } cells[3] = {
      {"到达", fmtEta(s)},
      {"剩余", s.remainM >= 0 ? fmtDistShort(s.remainM) : String("--")},
      {"还需", fmtDur(s.remainSec)},
  };

  for (int i = 0; i < 3; i++) {
    int cx = 53 + i * 107;
    drawStr(g, cells[i].label, cx, top + 2, F_CN12, C_DIM, lgfx::textdatum_t::top_center);
    drawStr(g, cells[i].value.c_str(), cx, top + 33, F_CN16, C_TEXT,
            lgfx::textdatum_t::bottom_center);
  }
}

void drawIdle(LovyanGFX& g, const NavState& s, uint32_t now) {
  drawPhone(g, 160, 92, 84, s.connected ? C_ACCENT : C_DIM);

  const char* title = s.connected ? "手机已连接" : "等待手机连接";
  drawStr(g, title, 160, 156, F_CN16, s.connected ? C_ACCENT : C_TEXT,
          lgfx::textdatum_t::middle_center);

  if (s.connected) {
    drawStr(g, "在手机 App 里点「开始导航」", 160, 178, F_CN12, C_DIM,
            lgfx::textdatum_t::middle_center);
  } else {
    static const char* dots[] = {"", ".", "..", "..."};
    String sub = String("打开 NavDisplay 连接 ") + DEVICE_NAME + dots[(now / 500) % 4];
    drawStr(g, sub.c_str(), 160, 178, F_CN12, C_DIM, lgfx::textdatum_t::middle_center);
  }
  drawStr(g, "长按 BOOT 键 2 秒：演示模式", 160, 199, F_CN12, C_LINE,
          lgfx::textdatum_t::middle_center);
}

void drawArrived(LovyanGFX& g, const NavState& s) {
  g.fillRoundRect(4, 32, 312, 170, 12, C_CARD);
  drawManeuverIcon(g, Maneuver::Arrive, 160, 82, 68, C_ACCENT);
  drawStr(g, "已到达目的地", 160, 140, F_CN24, C_ACCENT, lgfx::textdatum_t::middle_center);
  String sub = String("预计到达 ") + fmtEta(s);
  drawStr(g, sub.c_str(), 160, 174, F_CN16, C_DIM, lgfx::textdatum_t::middle_center);
}

// 地图模式左上角的转向提示卡
void drawMapChip(LovyanGFX& g, const NavState& s) {
  g.fillRoundRect(6, 32, 150, 56, 10, C_CARD);
  g.drawRoundRect(6, 32, 150, 56, 10, C_LINE);

  uint16_t c = s.stale ? C_DIM : C_ACCENT;
  drawManeuverIcon(g, s.maneuver, 32, 60, 40, c);

  String num = fmtDistNum(s.distM) + fmtDistUnit(s.distM);
  drawStr(g, num.c_str(), 148, 38, F_CN16, c, lgfx::textdatum_t::top_right);

  String road = s.road[0] ? String(s.road) : String(maneuverLabelZh(s.maneuver));
  road = ellipsize(g, road, 88);
  drawStr(g, road.c_str(), 58, 72, F_CN12, C_DIM, lgfx::textdatum_t::top_left);
}

void render(uint32_t now) {
  LovyanGFX& g = *s_g;
  g.fillScreen(C_BG);

  drawTopBar(g, g_nav);

  const bool mapMode = !s_demo && g_nav.navigating && mapnav::ready();

  if (g_nav.arrived) {
    drawArrived(g, g_nav);
  } else if (mapMode) {
    mapnav::render(g);
    drawMapChip(g, g_nav);
  } else if (g_nav.navigating || s_demo) {
    drawArrowCard(g, g_nav);
    drawNavInfo(g, g_nav);
  } else {
    drawIdle(g, g_nav, now);
  }

  drawBottomBar(g, g_nav);

  if (s_useCanvas) s_canvas.pushSprite(0, 0);
}

// ---------------- 演示模式 ----------------
struct DemoStep {
  Maneuver    m;
  Maneuver    next;
  const char* road;
  int         dist;
};

const DemoStep kDemo[] = {
    {Maneuver::Straight, Maneuver::Left, "沿 人民大道 直行", 320},
    {Maneuver::SlightLeft, Maneuver::Left, "前方路口稍向左", 160},
    {Maneuver::Left, Maneuver::Right, "左转进入 建设路", 120},
    {Maneuver::Right, Maneuver::UTurn, "右转进入 解放路", 90},
    {Maneuver::UTurn, Maneuver::Roundabout, "前方掉头", 60},
    {Maneuver::Roundabout, Maneuver::Arrive, "环岛 第 2 出口 驶出", 200},
    {Maneuver::Arrive, Maneuver::None, "到达目的地", 0},
};
constexpr int kDemoCount = sizeof(kDemo) / sizeof(kDemo[0]);

void demoUpdate(NavState& s, uint32_t now) {
  static uint32_t last = 0;
  static int      idx  = 0;
  static int      dist = kDemo[0].dist;
  static int32_t  rem  = 5400;
  static uint32_t tick = 0;
  static int      speed = 34;

  if (now - last < 200) return;
  last = now;
  tick++;

  if (tick % 5 == 0) {
    dist -= 18;
    rem -= 18;
    if (rem < 0) rem = 5400;
    if (dist <= 0) {
      idx  = (idx + 1) % kDemoCount;
      dist = kDemo[idx].dist;
    }
  }

  s.connected    = true;
  s.navigating   = (kDemo[idx].m != Maneuver::Arrive);
  s.arrived      = (kDemo[idx].m == Maneuver::Arrive);
  s.stale        = false;
  s.maneuver     = kDemo[idx].m;
  s.nextManeuver = kDemo[idx].next;
  s.distM        = dist;
  s.nextDistM    = 700;
  s.remainM      = rem;
  s.remainSec    = rem / 14;
  s.speedKmh     = speed + (int)((now / 3000) % 7) - 3;
  s.phoneBat     = 86;
  strlcpy(s.road, kDemo[idx].road, sizeof(s.road));

  int mins = (int)(now / 60000);
  int hh   = 18, mm = 42 + mins;
  hh += mm / 60;
  mm %= 60;
  snprintf(s.eta, sizeof(s.eta), "%02d:%02d", hh % 24, mm);

  s.lastRxMs = now;
  s.rxCount++;
}

}  // namespace

namespace ui {

void begin() {
  s_canvas.setColorDepth(16);
  s_canvas.setPsram(true);
  bool ok = (s_canvas.createSprite(UI_W, UI_H) != nullptr);
  if (!ok) {
    s_canvas.deleteSprite();
    s_canvas.setPsram(false);
    ok = (s_canvas.createSprite(UI_W, UI_H) != nullptr);
  }
  s_useCanvas = ok;
  s_g         = ok ? (LovyanGFX*)&s_canvas : (LovyanGFX*)&tft;
  Serial.printf("[ui] 画布: %s, 可用堆 %u\n", ok ? "Sprite" : "直画", (unsigned)ESP.getFreeHeap());
  s_dirty = true;

  // 开机画面
  tft.fillScreen(C_BG);
  drawBleGlyph(tft, 160, 96, 56, C_ACCENT);
  drawStr(tft, DEVICE_NAME, 160, 146, F_CN16, C_TEXT, lgfx::textdatum_t::middle_center);
  drawStr(tft, "固件 " FW_VERSION, 160, 170, F_CN12, C_DIM, lgfx::textdatum_t::middle_center);
}

void redraw() { s_dirty = true; }

void setDemo(bool on) {
  s_demo = on;
  if (!on) navReset(g_nav);
  s_dirty = true;
}

bool demo() { return s_demo; }

void tick(uint32_t now) {
  static uint32_t lastRender = 0;
  static uint32_t lastRx     = 0;
  static bool     demoInited = false;

  if (!s_demo) demoInited = false;

  if (s_demo) {
    if (!demoInited) {
      demoInited = true;
      navReset(g_nav);
    }
    demoUpdate(g_nav, now);
  } else if (mapnav::receiving()) {
    // 正在接收新地图：冻结画面，避免把半包数据画出来
    return;
  } else if (g_nav.navigating && g_nav.lastRxMs) {
    g_nav.stale = (now - g_nav.lastRxMs) > NAV_TIMEOUT_MS;
  } else {
    g_nav.stale = false;
  }

  const bool     navMode  = g_nav.navigating || g_nav.arrived || s_demo;
  const uint32_t interval = 1000 / (navMode ? UI_NAV_FPS : UI_IDLE_FPS);
  const bool     changed  = s_dirty || (g_nav.rxCount != lastRx);

  if (!changed && (now - lastRender) < interval) return;

  render(now);
  lastRender = now;
  lastRx     = g_nav.rxCount;
  s_dirty    = false;
}

}  // namespace ui
