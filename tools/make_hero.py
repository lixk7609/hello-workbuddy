# -*- coding: utf-8 -*-
# 生成商店 Hero Image（1440x720 宣传横幅）：L跑步 / L冬跑
from PIL import Image, ImageDraw, ImageFont
import math, os

BASE = os.path.dirname(os.path.abspath(__file__))
NAVY_TOP = (16, 34, 64)
NAVY_BOT = (8, 20, 40)
WHITE = (245, 248, 252)
ORANGE = (232, 130, 30)
SKYBLUE = (140, 200, 240)
W, H = 1440, 720

def font(name, size):
    for cand in [rf"C:\Windows\Fonts\{name}.ttf", r"C:\Windows\Fonts\arialbd.ttf"]:
        if os.path.exists(cand):
            return ImageFont.truetype(cand, size)
    return ImageFont.load_default()

def bg():
    img = Image.new("RGB", (W, H), NAVY_TOP)
    d = ImageDraw.Draw(img)
    for y in range(H):
        t = y / H
        c = tuple(int(NAVY_TOP[i] + (NAVY_BOT[i] - NAVY_TOP[i]) * t) for i in range(3))
        d.line([(0, y), (W, y)], fill=c)
    return img, d

def draw_L(d, cx, cy, fsize):
    f = font("arialbd", fsize)
    bbox = d.textbbox((0, 0), "L", font=f)
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    d.text((cx - w / 2 - bbox[0], cy - h / 2 - bbox[1]), "L", font=f, fill=WHITE)
    return h

def stopwatch(d, cx, cy, r, col):
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=col, width=int(r * 0.20))
    bw = int(r * 0.36)
    d.rectangle([cx - bw // 2, cy - r - int(r * 0.30), cx + bw // 2, cy - r], fill=col)
    ang = math.radians(215)
    d.line([(cx, cy), (cx + r * 0.62 * math.cos(ang), cy + r * 0.62 * math.sin(ang))],
           fill=col, width=int(r * 0.16))
    cr = int(r * 0.10)
    d.ellipse([cx - cr, cy - cr, cx + cr, cy + cr], fill=col)

def snowflake(d, cx, cy, r, col):
    lw = int(r * 0.11)
    bl, bp = r * 0.42, 0.55
    for i in range(6):
        ang = math.radians(i * 60)
        ex, ey = cx + r * math.cos(ang), cy + r * math.sin(ang)
        d.line([(cx, cy), (ex, ey)], fill=col, width=lw)
        for sign in (1, -1):
            bang = ang + sign * math.radians(40)
            mx, my = cx + r * bp * math.cos(ang), cy + r * bp * math.sin(ang)
            d.line([(mx, my), (mx + bl * math.cos(bang), my + bl * math.sin(bang))],
                   fill=col, width=max(2, lw - 1))
    cr = int(r * 0.12)
    d.ellipse([cx - cr, cy - cr, cx + cr, cy + cr], fill=col)

def make(kind, title, tagline, out):
    img, d = bg()
    # 左侧大 L + 标识物
    draw_L(d, 330, 300, 340)
    if kind == "run":
        stopwatch(d, 430, 520, 88, ORANGE)
    else:
        snowflake(d, 430, 520, 95, SKYBLUE)
    # 右侧标题 + 副标题
    f1 = font("arialbd", 96)
    f2 = font("arial", 40)
    bbox = d.textbbox((0, 0), title, font=f1)
    d.text((700, 250), title, font=f1, fill=WHITE)
    d.text((704, 400), tagline, font=f2, fill=(200, 214, 230))
    # 底部装饰线
    d.line([(700, 360), (1360, 360)], fill=(232, 130, 30) if kind == "run" else SKYBLUE, width=6)
    img.save(os.path.join(BASE, "out", out), quality=95)

make("run", "L Running", "Time & heart rate at a glance", "LRunTime-hero-1440x720.png")
make("winter", "L WinterRun", "Glove-friendly auto start/stop", "LWinterRun-hero-1440x720.png")
print("hero done")
