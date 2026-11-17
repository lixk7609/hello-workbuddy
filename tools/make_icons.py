# -*- coding: utf-8 -*-
# 生成 L跑步 / L冬跑 商店图标（360x360）与 launcher 图标（40x40）
# 家族风格：深蓝底 + 白色粗体 L + 各自标识物（秒表 / 雪花）
from PIL import Image, ImageDraw, ImageFont
import math, os

BASE = os.path.dirname(os.path.abspath(__file__))
NAVY_TOP = (16, 34, 64)
NAVY_BOT = (8, 20, 40)
WHITE = (245, 248, 252)

def find_font():
    for p in [r"C:\Windows\Fonts\arialbd.ttf", r"C:\Windows\Fonts\segoeuib.ttf",
              r"C:\Windows\Fonts\calibrib.ttf", r"C:\Windows\Fonts\arial.ttf"]:
        if os.path.exists(p):
            return p
    return None

def bg(size):
    img = Image.new("RGB", (size, size), NAVY_TOP)
    d = ImageDraw.Draw(img)
    # 垂直渐变
    for y in range(size):
        t = y / size
        c = tuple(int(NAVY_TOP[i] + (NAVY_BOT[i] - NAVY_TOP[i]) * t) for i in range(3))
        d.line([(0, y), (size, y)], fill=c)
    return img, d

def draw_L(d, size, font_path):
    f = ImageFont.truetype(font_path, int(size * 0.60))
    bbox = d.textbbox((0, 0), "L", font=f)
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    x = size * 0.5 - w / 2 - bbox[0]
    y = size * 0.315 - h / 2 - bbox[1]
    d.text((x, y), "L", font=f, fill=WHITE)

def draw_stopwatch(d, cx, cy, r, col=(232, 130, 30)):
    ring_w = max(3, int(r * 0.20))
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=col, width=ring_w)
    # 顶部按钮与柄
    bw = int(r * 0.36)
    d.rectangle([cx - bw // 2, cy - r - int(r * 0.30), cx + bw // 2, cy - r], fill=col)
    # 指针：指向 10 点钟方向
    ang = math.radians(215)
    hx, hy = cx + r * 0.62 * math.cos(ang), cy + r * 0.62 * math.sin(ang)
    d.line([(cx, cy), (hx, hy)], fill=col, width=max(3, int(r * 0.16)))
    # 中心点
    cr = max(2, int(r * 0.10))
    d.ellipse([cx - cr, cy - cr, cx + cr, cy + cr], fill=col)

def draw_snowflake(d, cx, cy, r, col=(140, 200, 240)):
    lw = max(3, int(r * 0.11))
    bl = r * 0.42          # 分支长度
    bp = 0.55              # 分支起点比例
    for i in range(6):
        ang = math.radians(i * 60)
        ex, ey = cx + r * math.cos(ang), cy + r * math.sin(ang)
        d.line([(cx, cy), (ex, ey)], fill=col, width=lw)
        # 每根主枝两侧的分叉
        for sign in (1, -1):
            bang = ang + sign * math.radians(40)
            mx, my = cx + r * bp * math.cos(ang), cy + r * bp * math.sin(ang)
            bx, by = mx + bl * math.cos(bang), my + bl * math.sin(bang)
            d.line([(mx, my), (bx, by)], fill=col, width=max(2, lw - 1))
    cr = max(2, int(r * 0.12))
    d.ellipse([cx - cr, cy - cr, cx + cr, cy + cr], fill=col)

def make(kind, size):
    fp = find_font()
    img, d = bg(size)
    draw_L(d, size, fp)
    if kind == "run":
        draw_stopwatch(d, int(size * 0.62), int(size * 0.72), int(size * 0.17))
    else:
        draw_snowflake(d, int(size * 0.62), int(size * 0.72), int(size * 0.20))
    return img

os.makedirs(os.path.join(BASE, "out"), exist_ok=True)
for kind, name in [("run", "LRunTime"), ("winter", "LWinterRun")]:
    icon360 = make(kind, 360)
    icon360.save(os.path.join(BASE, "out", f"{name}-icon-360.png"))
    icon40 = make(kind, 160).resize((40, 40), Image.LANCZOS)
    icon40.save(os.path.join(BASE, "out", f"{name}-launcher-40.png"))
print("done")
