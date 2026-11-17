# -*- coding: utf-8 -*-
# 商店图片：Cover Image (500x500) + Screen Images (280x280 圆形屏)
# L跑步 3 张截图（不同心率区间），L冬跑 4 张截图（四个状态）
from PIL import Image, ImageDraw, ImageFont
import math, os

BASE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(BASE, "out")
NAVY_TOP = (16, 34, 64)
NAVY_BOT = (8, 20, 40)
WHITE = (245, 248, 252)
BLACK = (10, 10, 10)

def font(path_names, size):
    for n in path_names:
        p = os.path.join(r"C:\Windows\Fonts", n)
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                pass
    return ImageFont.load_default()

F_NUM  = lambda s: font(["arialbd.ttf"], s)                       # 数值粗体
F_CN   = lambda s: font(["simhei.ttf", "msyhbd.ttc", "msyh.ttc"], s)  # 中文标签
F_EN   = lambda s: font(["segoeuib.ttf", "arialbd.ttf"], s)

# 与真机一致的区间色：<=116 灰 / <=135 蓝 / <=150 绿 / <=169 橙 / 否则红
def zone_color(hr):
    if hr <= 116: return (110, 110, 110)
    if hr <= 135: return (0, 90, 220)
    if hr <= 150: return (0, 150, 70)
    if hr <= 169: return (255, 140, 0)
    return (220, 30, 30)

def draw_heart(d, cx, cy, s, color):
    r = int(s * 0.5)
    top = int(cy - s * 0.25)
    d.ellipse([cx - r - r, top - r, cx - r + r, top + r], fill=color)
    d.ellipse([cx + r - r, top - r, cx + r + r, top + r], fill=color)
    d.polygon([(cx - int(s * 0.62), cy - int(s * 0.05)),
               (cx + int(s * 0.62), cy - int(s * 0.05)),
               (cx, cy + int(s * 0.72))], fill=color)

def draw_arc(d, S, avg_hr):
    """与真机 drawZoneArc 一致：15 段，-152°→-28°，细到粗"""
    n, aStart, aEnd = 15, -152.0, -28.0
    step = (aEnd - aStart) / n
    segAng = step * 0.72
    cx = cy = S / 2
    rOut = S * 0.470
    tMin, tMax = S * 0.012, S * 0.040
    hrMin, hrMax = 90.0, 200.0
    for i in range(n):
        hrSeg = int(hrMin + (hrMax - hrMin) * i / (n - 1))
        if hrSeg > avg_hr:
            continue
        f = i / (n - 1)
        thick = tMin + (tMax - tMin) * f
        rIn = rOut - thick
        d._image and None
        pts = []
        for ang_deg, r in [(aStart + step * i, rOut),
                           (aStart + step * i + segAng * 0.5, rOut),
                           (aStart + step * i + segAng, rOut),
                           (aStart + step * i + segAng, rIn),
                           (aStart + step * i + segAng * 0.5, rIn),
                           (aStart + step * i, rIn)]:
            a = math.radians(ang_deg)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
        d.polygon(pts, fill=zone_color(hrSeg))

def draw_bold(d, cx, y, text, f, color=BLACK):
    w = d.textlength(text, font=f)
    d.text((cx - w / 2, y), text, font=f, fill=color)

def draw_tiny(d, cx, y, text, f, color=BLACK):
    w = d.textlength(text, font=f)
    d.text((cx - w / 2, y), text, font=f, fill=color)

def run_panel(S, avg_hr, hr_s, time_s, dist_s, timer_s, pace_s, right3=None):
    """跑步面板：与真机三行布局一致。right3=None 时行3 为配速居中（L跑步），
    否则为 配速 | right3 两列（L冬跑）"""
    img = Image.new("RGB", (S, S), BLACK)
    d = ImageDraw.Draw(img)
    # 圆形屏幕底
    d.ellipse([0, 0, S, S], fill=(255, 255, 255))
    draw_arc(d, S, avg_hr)
    fN = F_NUM(int(S * 0.105))
    fT = F_CN(int(S * 0.052))
    numH, tinyH, gap = int(S * 0.105), int(S * 0.052), int(S * 0.016)
    r1 = numH
    r2 = tinyH + gap + numH
    total = r1 + r2 * 2 + gap * 2
    y = (S - total) // 2
    cxL, cxR, cxM = int(S * 0.26), int(S * 0.72), S // 2
    # 行1 心率 | 时间（数字左对齐紧跟心形，避免重叠）
    hrCy = y + numH // 2
    heartCx = int(cxL - numH * 0.62)
    draw_heart(d, heartCx, hrCy, int(numH * 0.9), BLACK)
    w = d.textlength(hr_s, font=fN)
    d.text((heartCx + numH * 0.55, y), hr_s, font=fN, fill=BLACK)
    draw_bold(d, cxR, y, time_s, fN)
    y += r1 + gap
    # 行2 距离 | 计时器
    draw_tiny(d, cxL, y, "距离", fT)
    draw_tiny(d, cxR, y, "计时器", fT)
    draw_bold(d, cxL, y + tinyH + gap, dist_s, fN)
    draw_bold(d, cxR, y + tinyH + gap, timer_s, fN)
    y += r2 + gap
    # 行3
    if right3 is None:
        draw_tiny(d, cxM, y, "配速", fT)
        draw_bold(d, cxM, y + tinyH + gap, pace_s, fN)
    else:
        draw_tiny(d, cxL, y, "配速", fT)
        draw_tiny(d, cxR, y, "剩余", fT)
        draw_bold(d, cxL, y + tinyH + gap, pace_s, fN)
        draw_bold(d, cxR, y + tinyH + gap, right3, fN)
    return img

def menu_screen(S, km="9.25"):
    img = Image.new("RGB", (S, S), BLACK)
    d = ImageDraw.Draw(img)
    d.ellipse([0, 0, S, S], fill=(255, 255, 255))
    fN = F_NUM(int(S * 0.155))
    fT = F_CN(int(S * 0.055))
    y0 = int(S * 0.30)
    draw_tiny(d, S // 2, int(S * 0.13), "L冬跑", F_CN(int(S * 0.06)))
    draw_bold(d, S // 2, y0, km, fN)
    draw_tiny(d, S // 2, y0 + int(S * 0.155), "公里", fT)
    draw_tiny(d, S // 2, int(S * 0.64), "UP/DOWN 整数公里", fT)
    draw_tiny(d, S // 2, int(S * 0.72), "BACK 调小数 0.01", fT)
    draw_tiny(d, S // 2, int(S * 0.80), "START 确认", fT)
    return img

def armed_screen(S, km="9.25", sec=43, gps=True):
    img = Image.new("RGB", (S, S), BLACK)
    d = ImageDraw.Draw(img)
    d.ellipse([0, 0, S, S], fill=(255, 255, 255))
    fN = F_NUM(int(S * 0.13))
    fT = F_CN(int(S * 0.055))
    y0 = int(S * 0.28)
    draw_tiny(d, S // 2, int(S * 0.13), "目标距离", fT)
    draw_bold(d, S // 2, y0, km + " km", fN)
    draw_tiny(d, S // 2, int(S * 0.62), "姿态识别 %d/60 秒" % sec, fT)
    draw_tiny(d, S // 2, int(S * 0.70), "GPS 已连接" if gps else "GPS 搜星中…", fT)
    draw_tiny(d, S // 2, int(S * 0.80), "双条件就绪自动开跑", fT)
    return img

def done_screen(S, km="9.25", elapsed="1:05:12", pace="7'02\""):
    img = Image.new("RGB", (S, S), BLACK)
    d = ImageDraw.Draw(img)
    d.ellipse([0, 0, S, S], fill=(255, 255, 255))
    fN = F_NUM(int(S * 0.115))
    fT = F_CN(int(S * 0.050))
    y0 = int(S * 0.28)
    draw_tiny(d, S // 2, int(S * 0.15), "目标达成", fT)
    draw_bold(d, S // 2, y0, km + " km", fN)
    draw_tiny(d, S // 2, y0 + int(S * 0.115), "用时 " + elapsed + " · 配速 " + pace, fT)
    draw_tiny(d, S // 2, int(S * 0.72), "已自动保存", fT)
    draw_tiny(d, S // 2, int(S * 0.80), "START 返回", fT)
    return img

def save_screen(img, name):
    """加表圈外沿（黑色四角由圆形屏幕天然形成）"""
    img.save(os.path.join(OUT, name))

def cover(panel_img, title, tagline, accent, name):
    W = H = 500
    img = Image.new("RGB", (W, H), NAVY_TOP)
    d = ImageDraw.Draw(img)
    for y in range(H):
        t = y / H
        c = tuple(int(NAVY_TOP[i] + (NAVY_BOT[i] - NAVY_TOP[i]) * t) for i in range(3))
        d.line([(0, y), (W, y)], fill=c)
    # 圆形表盘（白色屏幕）+ 细表圈
    R = 165
    cx, cy = W // 2, 205
    d.ellipse([cx - R - 10, cy - R - 10, cx + R + 10, cy + R + 10], fill=(60, 74, 100))  # 表圈
    # 缩放面板贴入圆
    inner = panel_img.resize((2 * R, 2 * R), Image.LANCZOS)
    mask = Image.new("L", (2 * R, 2 * R), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, 2 * R, 2 * R], fill=255)
    img.paste(inner, (cx - R, cy - R), mask)
    # 标题与副标题
    f1 = F_EN(52)
    f2 = F_EN(24)
    w1 = d.textlength(title, font=f1)
    d.text(((W - w1) / 2, 400), title, font=f1, fill=WHITE)
    d.line([(W // 2 - 120, 458), (W // 2 + 120, 458)], fill=accent, width=4)
    w2 = d.textlength(tagline, font=f2)
    d.text(((W - w2) / 2, 468), tagline, font=f2, fill=(190, 204, 222))
    img.save(os.path.join(OUT, name), quality=95)

# ---------- L跑步：3 张截图（覆盖灰/绿/红三个区间） ----------
s1 = run_panel(280, 142, "142", "09:41", "5.28", "28:34", "5'24\"")          # 绿区
s2 = run_panel(280, 178, "178", "10:05", "8.15", "45:12", "5'33\"")          # 红区
s3 = run_panel(280, 125, "125", "07:58", "1.52", "9:45", "6'25\"")           # 蓝区
save_screen(s1, "LRunTime-screen-1.png")
save_screen(s2, "LRunTime-screen-2.png")
save_screen(s3, "LRunTime-screen-3.png")

# ---------- L跑步 cover ----------
cover(run_panel(330, 142, "142", "09:41", "5.28", "28:34", "5'24\""),
      "L Running", "Data Field · Fenix 7X", (255, 140, 0), "LRunTime-cover-500.png")

# ---------- L冬跑：4 张截图 ----------
w1 = menu_screen(280, "9.25")
w2 = armed_screen(280, "9.25", 43, True)
w3 = run_panel(280, 142, "142", "09:41", "6.83", "38:12", "5'35\"", right3="2.42")
w4 = done_screen(280, "9.25", "1:05:12", "7'02\"")
save_screen(w1, "LWinterRun-screen-1.png")
save_screen(w2, "LWinterRun-screen-2.png")
save_screen(w3, "LWinterRun-screen-3.png")
save_screen(w4, "LWinterRun-screen-4.png")

# ---------- L冬跑 cover ----------
cover(menu_screen(330, "9.25"),
      "L WinterRun", "Watch App · Fenix 7X", (140, 200, 240), "LWinterRun-cover-500.png")

print("store images done")
