"""生成 README 用的界面预览图（不依赖固件，纯设计稿）。

用法：
    python tools/render_mockup.py
输出：
    docs/preview.png
"""
from PIL import Image, ImageDraw, ImageFont
import os

S = 2  # 超采样倍数
W, H = 320, 240
BG = "#090c11"
PANEL = "#161b22"
CARD = "#1c222b"
LINE = "#303844"
TEXT = "#e6edf3"
DIM = "#8b949e"
ACCENT = "#3ddc84"
WARN = "#ffb020"
BLUE = "#4fa8ff"

FONT_DIR = "C:/Windows/Fonts"


def font(size, bold=False):
    name = "msyhbd.ttc" if bold else "msyh.ttc"
    return ImageFont.truetype(os.path.join(FONT_DIR, name), size * S)


F16 = font(16)
F12 = font(12)
F12B = font(12, True)
F16B = font(16, True)
F24B = font(24, True)
F34B = font(34, True)


def rect(d, x, y, w, h, fill, r=0):
    box = [x * S, y * S, (x + w) * S, (y + h) * S]
    if r:
        d.rounded_rectangle(box, radius=r * S, fill=fill)
    else:
        d.rectangle(box, fill=fill)


def text(d, s, x, y, f, color, anchor="la"):
    d.text((x * S, y * S), s, font=f, fill=color, anchor=anchor)


def dot(d, x, y, r, color):
    d.ellipse([(x - r) * S, (y - r) * S, (x + r) * S, (y + r) * S], fill=color)


def thick_line(d, pts, width, color):
    p = [(x * S, y * S) for x, y in pts]
    d.line(p, fill=color, width=int(width * S), joint="curve")
    r = width * S / 2
    for x, y in p:
        d.ellipse([x - r, y - r, x + r, y + r], fill=color)


def arrow_head(d, tip, ang, length, width, color):
    import math
    tx, ty = tip
    bx = tx - math.cos(ang) * length
    by = ty - math.sin(ang) * length
    px = -math.sin(ang) * width * 0.95
    py = math.cos(ang) * width * 0.95
    d.polygon([(tx * S, ty * S), ((bx + px) * S, (by + py) * S), ((bx - px) * S, (by - py) * S)], fill=color)


def maneuver(d, kind, cx, cy, size, color):
    import math
    h = size / 2
    w = max(3, size * 0.115)

    if kind == "left":
        pts = [(cx, cy + 0.85 * h), (cx, cy - 0.05 * h), (cx - 0.35 * h, cy - 0.05 * h)]
        thick_line(d, pts, w, color)
        arrow_head(d, (cx - 0.88 * h, cy - 0.05 * h), math.pi, h * 0.55, w, color)
    elif kind == "right":
        pts = [(cx, cy + 0.85 * h), (cx, cy - 0.05 * h), (cx + 0.35 * h, cy - 0.05 * h)]
        thick_line(d, pts, w, color)
        arrow_head(d, (cx + 0.88 * h, cy - 0.05 * h), 0, h * 0.55, w, color)
    elif kind == "straight":
        thick_line(d, [(cx, cy + 0.85 * h), (cx, cy - 0.30 * h)], w, color)
        arrow_head(d, (cx, cy - 0.90 * h), -math.pi / 2, h * 0.55, w, color)
    elif kind == "arrive":
        thick_line(d, [(cx - 0.28 * h, cy + 0.90 * h), (cx - 0.28 * h, cy - 0.86 * h)], w * 0.8, color)
        cell = 0.28 * h
        for row in range(3):
            for col in range(3):
                if (row + col) % 2:
                    continue
                x = cx - 0.24 * h + col * cell
                y = cy - 0.88 * h + row * 0.21 * h
                d.rectangle([x * S, y * S, (x + cell) * S, (y + 0.21 * h) * S], fill=color)


def battery(d, x, y, w, h, pct):
    d.rectangle([x * S, y * S, (x + w) * S, (y + h) * S], outline=DIM, width=S)
    d.rectangle([(x + w) * S, (y + h / 3) * S, (x + w + 2) * S, (y + 2 * h / 3) * S], fill=DIM)
    fw = max(1, (w - 4) * pct / 100)
    d.rectangle([(x + 2) * S, (y + 2) * S, (x + 2 + fw) * S, (y + h - 2) * S], fill=ACCENT)


def top_bar(d, state="导航中", color=ACCENT, pct=87):
    rect(d, 0, 0, W, 28, PANEL)
    d.line([0, 28 * S, W * S, 28 * S], fill=LINE, width=S)
    dot(d, 14, 14, 4, color)
    text(d, state, 24, 14, F16, color, anchor="lm")
    if pct >= 0:
        text(d, f"{pct}%", 312, 14, F16, DIM, anchor="rm")
        battery(d, 252, 8, 22, 12, pct)


def bottom_bar(d, eta, rem, dur):
    top = 206
    rect(d, 0, top, W, H - top, PANEL)
    d.line([0, top * S, W * S, top * S], fill=LINE, width=S)
    for x in (106, 213):
        d.line([x * S, (top + 4) * S, x * S, (top + 30) * S], fill=LINE, width=S)
    cells = [("到达", eta), ("剩余", rem), ("还需", dur)]
    for i, (label, value) in enumerate(cells):
        cx = 53 + i * 107
        text(d, label, cx, top + 2, F12, DIM, anchor="ma")
        text(d, value, cx, top + 30, F16B, TEXT, anchor="ms")


def screen_nav():
    img = Image.new("RGB", (W * S, H * S), BG)
    d = ImageDraw.Draw(img)
    top_bar(d)
    rect(d, 4, 32, 136, 170, CARD, r=12)
    maneuver(d, "left", 72, 117, 104, ACCENT)

    text(d, "180", 316, 34, F34B, ACCENT, anchor="ra")
    text(d, "米", 316, 68, F16, DIM, anchor="ra")
    text(d, "人民大道", 148, 92, F16, TEXT, anchor="la")

    d.line([148 * S, 140 * S, 316 * S, 140 * S], fill=LINE, width=S)
    text(d, "然后", 148, 158, F12, DIM, anchor="lm")
    maneuver(d, "right", 184, 158, 24, TEXT)
    text(d, "右转 900米", 202, 158, F16, TEXT, anchor="lm")

    text(d, "32 km/h", 316, 186, F12, DIM, anchor="rs")
    bottom_bar(d, "18:42", "12.4公里", "32分钟")
    return img


def screen_idle():
    img = Image.new("RGB", (W * S, H * S), BG)
    d = ImageDraw.Draw(img)
    top_bar(d, "等待连接", DIM, -1)

    # 手机轮廓 + 蓝牙
    cx, cy, hgt = 160, 92, 84
    wdt = hgt * 0.58
    d.rounded_rectangle([(cx - wdt / 2) * S, (cy - hgt / 2) * S, (cx + wdt / 2) * S, (cy + hgt / 2) * S],
                        radius=6 * S, outline=DIM, width=3 * S)
    d.rectangle([(cx - 4) * S, (cy - hgt / 2 + 3) * S, (cx + 4) * S, (cy - hgt / 2 + 5) * S], fill=DIM)
    s = hgt * 0.38 / 2
    for a, b in [
        ((cx, cy - s), (cx, cy + s)),
        ((cx, cy - s), (cx + 0.62 * s, cy - 0.45 * s)),
        ((cx + 0.62 * s, cy - 0.45 * s), (cx - 0.25 * s, cy + 0.25 * s)),
        ((cx, cy + s), (cx + 0.62 * s, cy + 0.45 * s)),
        ((cx + 0.62 * s, cy + 0.45 * s), (cx - 0.25 * s, cy - 0.25 * s)),
    ]:
        d.line([a[0] * S, a[1] * S, b[0] * S, b[1] * S], fill=DIM, width=2 * S)

    text(d, "等待手机连接", 160, 156, F16B, TEXT, anchor="mm")
    text(d, "打开 NavDisplay 连接 ESP32-Navi..", 160, 178, F12, DIM, anchor="mm")
    text(d, "长按 BOOT 键 2 秒：演示模式", 160, 199, F12, "#4b5563", anchor="mm")
    bottom_bar(d, "--:--", "--", "--")
    return img


def screen_map():
    """地图模式的示意图（真实固件是动态渲染，这里只表达布局）"""
    img = Image.new("RGB", (W * S, H * S), BG)
    d = ImageDraw.Draw(img)
    top_bar(d)

    # 地图底色
    d.rectangle([0, 28 * S, W * S, 206 * S], fill="#090d12")

    def road(pts, color="#2a323d", width=2):
        thick_line(d, pts, width, color)

    # 周边道路（示意）
    road([(-20, 60), (90, 95), (180, 80), (340, 120)], "#3a4553", 2)
    road([(40, 30), (70, 120), (55, 210)], "#262e38", 2)
    road([(120, 30), (150, 100), (140, 210)], "#262e38", 2)
    road([(220, 30), (210, 110), (250, 210)], "#3a4553", 2)
    road([(280, 30), (300, 110), (320, 210)], "#262e38", 2)
    road([(0, 150), (110, 160), (200, 150), (320, 170)], "#262e38", 2)
    road([(0, 185), (120, 190), (240, 182), (320, 195)], "#3a4553", 2)
    road([(180, 40), (200, 90), (190, 140)], "#262e38", 2)

    # 路线（粗绿线，带一点弯）
    route = [(150, 250), (152, 210), (148, 175), (150, 140), (140, 110), (120, 85), (95, 65)]
    thick_line(d, route, 7, "#0b3a22")
    thick_line(d, route, 5, ACCENT)

    # 下一个转向点
    dot(d, 120, 85, 7, WARN)
    dot(d, 120, 85, 3, BG)

    # 本车位置
    d.polygon([(160 * S, 132 * S), (151 * S, 156 * S), (169 * S, 156 * S)], fill=BG)
    d.polygon([(160 * S, 136 * S), (154 * S, 152 * S), (166 * S, 152 * S)], fill=TEXT)

    # 左上提示卡
    rect(d, 6, 32, 150, 56, CARD, r=10)
    d.rounded_rectangle([6 * S, 32 * S, 156 * S, 88 * S], radius=10 * S, outline=LINE, width=S)
    maneuver(d, "left", 32, 60, 40, ACCENT)
    text(d, "180米", 148, 38, F16B, ACCENT, anchor="ra")
    text(d, "人民大道", 58, 72, F12, DIM, anchor="la")

    bottom_bar(d, "18:42", "12.4公里", "32分钟")
    return img


def main():
    a = screen_nav()
    b = screen_idle()
    c = screen_map()

    pad = 36
    gap = 40
    width = pad * 2 + a.width * 3 + gap * 2
    out = Image.new("RGB", (width, pad * 2 + a.height + 34), "#05070a")
    out.paste(a, (pad, pad))
    out.paste(c, (pad + a.width + gap, pad))
    out.paste(b, (pad + (a.width + gap) * 2, pad))

    d = ImageDraw.Draw(out)
    label = ImageFont.truetype(os.path.join(FONT_DIR, "msyh.ttc"), 22)
    d.text((pad, pad + a.height + 8), "箭头模式", font=label, fill="#8b949e")
    d.text((pad + a.width + gap, pad + a.height + 8), "地图导航", font=label, fill="#8b949e")
    d.text((pad + (a.width + gap) * 2, pad + a.height + 8), "等待连接", font=label, fill="#8b949e")

    os.makedirs("docs", exist_ok=True)
    out.save("docs/preview.png")
    print("docs/preview.png", out.size)


if __name__ == "__main__":
    main()
