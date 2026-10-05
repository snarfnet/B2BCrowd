# 機材の天板に印刷される文字・目盛り（汎用デザイン。実在メーカーのロゴや配置は使わない）
# 座標はメートル（gear.py と同じ）。出力は ../out/tex/*.png
import os, math
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import random

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "out", "tex")
os.makedirs(OUT, exist_ok=True)
PX = 3200  # 1m あたりの画素

def font(size, bold=True):
    for f in (["C:/Windows/Fonts/arialbd.ttf"] if bold else []) + ["C:/Windows/Fonts/arial.ttf"]:
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()

class Panel:
    def __init__(self, w, d, base=(14, 14, 16)):
        self.w, self.d = w, d
        self.W, self.H = int(w * PX), int(d * PX)
        self.img = Image.new("RGB", (self.W, self.H), base)
        self.g = ImageDraw.Draw(self.img)
        # うっすら細かい粒（塗装のざらつき）
        px = self.img.load()
        rnd = random.Random(7)
        for _ in range(self.W * self.H // 6):
            x, y = rnd.randrange(self.W), rnd.randrange(self.H)
            v = rnd.randint(-4, 4)
            r, g, b = px[x, y]
            px[x, y] = (max(0, r + v), max(0, g + v), max(0, b + v))

    def p(self, x, y):
        """メートル座標（中心原点、y は奥が +）→ 画素"""
        return (self.w / 2 + x) * PX, (self.d / 2 - y) * PX

    def text(self, x, y, s, size=0.007, color=(205, 205, 210), anchor="mm"):
        self.g.text(self.p(x, y), s, font=font(int(size * PX)), fill=color, anchor=anchor)

    def ring_ticks(self, x, y, r, n=11, a0=225, a1=-45, length=0.004, color=(180, 180, 185)):
        cx, cy = self.p(x, y)
        for i in range(n):
            a = math.radians(a0 + (a1 - a0) * i / (n - 1))
            r1, r2 = r * PX, (r + length) * PX
            self.g.line([(cx + math.cos(a) * r1, cy - math.sin(a) * r1), (cx + math.cos(a) * r2, cy - math.sin(a) * r2)],
                        fill=color, width=max(2, int(0.0006 * PX)))

    def rect(self, x, y, w, h, outline=(90, 90, 95), fill=None, width=0.0006):
        x0, y0 = self.p(x - w / 2, y + h / 2)
        x1, y1 = self.p(x + w / 2, y - h / 2)
        self.g.rectangle([x0, y0, x1, y1], outline=outline, fill=fill, width=max(1, int(width * PX)))

    def circle(self, x, y, r, outline=(90, 90, 95), width=0.0006, fill=None):
        cx, cy = self.p(x, y)
        R = r * PX
        self.g.ellipse([cx - R, cy - R, cx + R, cy + R], outline=outline, width=max(1, int(width * PX)), fill=fill)

    def scale(self, x, y0, y1, n=11, w=0.006, labels=None):
        for i in range(n):
            y = y0 + (y1 - y0) * i / (n - 1)
            ww = w * (1.6 if i % 5 == 0 else 1)
            a, b = self.p(x - ww / 2, y), self.p(x + ww / 2, y)
            self.g.line([a, b], fill=(160, 160, 165), width=max(1, int(0.0005 * PX)))
        if labels:
            for t, yy in labels:
                self.text(x - w * 1.6, yy, t, size=0.0042, anchor="rm")

    def save(self, name):
        self.img.save(os.path.join(OUT, name + ".png"))
        print("tex", name, self.img.size)

def deck(side):
    P = Panel(0.33 - 0.014, 0.42 - 0.014)
    s = -1 if side == "A" else 1          # 外側（A は左）
    jy = -0.048
    # ジョグまわりの目盛り
    P.ring_ticks(0, jy, 0.11, n=48, a0=0, a1=360 - 7.5, length=0.003, color=(110, 110, 115))
    P.text(0, jy - 0.121, "JOG / VINYL", size=0.0045, color=(130, 130, 135))
    # 画面まわり
    P.rect(0, 0.152, 0.148, 0.093, outline=(70, 70, 75))
    P.text(-0.074, 0.199, "DECK " + side, size=0.0055, anchor="lm")
    # 再生ボタン
    sx = 0.12 * s
    P.circle(sx, -0.155, 0.024, outline=(120, 120, 125))
    P.circle(sx, -0.11, 0.024, outline=(120, 120, 125))
    P.text(sx, -0.155 - 0.031, "CUE", size=0.006)
    P.text(sx, -0.11 + 0.031, "PLAY / PAUSE", size=0.0048)
    # パッド
    P.text(0.03 * -s if False else (0.03 if side == "A" else -0.03), 0.118, "HOT CUE", size=0.0048, color=(150, 150, 155))
    for row in range(2):
        for i in range(4):
            px = (-0.09 + i * 0.06) * 0.8 + (0.03 if side == "A" else -0.03)
            py = 0.095 - row * 0.027
            P.text(px, py - 0.0155, chr(ord("A") + row * 4 + i), size=0.0038, color=(120, 120, 125))
    # テンポ
    tx = 0.14 if side == "A" else -0.14
    P.scale(tx, -0.12, 0.04, n=17, w=0.008, labels=[("+", 0.04), ("0", -0.04), ("−", -0.12)])
    P.text(tx, 0.056, "TEMPO", size=0.0045)
    # ループ
    lx = 0.07 if side == "A" else -0.07
    for k, tt in enumerate(["IN", "OUT", "RELOOP"]):
        P.text(lx + (k - 1) * 0.027 * (-s), -0.2, tt, size=0.0032)
    P.text(lx, -0.179, "LOOP", size=0.0040, color=(150, 150, 155))
    P.text(-tx * 0.15 + (0.1 if side == "A" else -0.1), 0.172, "BROWSE", size=0.0038)
    P.save(f"deck_{side}_print")

def mixer():
    P = Panel(0.27 - 0.014, 0.42 - 0.014)
    chx = [-0.055, 0.055]
    ys = [0.17, 0.125, 0.08, 0.035, -0.015]
    names = ["TRIM", "HI", "MID", "LOW", "FILTER"]
    for c, x in enumerate(chx):
        P.text(x, 0.198, f"CH {c + 1}", size=0.0062)
        for y, nm in zip(ys, names):
            r = 0.0125 if nm != "FILTER" else 0.015
            P.ring_ticks(x, y, r + 0.002, n=11, length=0.003)
            if nm == "FILTER":
                P.text(x + (-0.03 if c == 0 else 0.03), y + 0.003, nm, size=0.0038)
            else:
                P.text(x, y - r - 0.0075, nm, size=0.0042)
        # フェーダー目盛り
        P.scale(x + 0.022, -0.14, -0.05, n=11, w=0.006, labels=None)
        for i, t in enumerate(["0", "2", "4", "6", "8", "10"]):
            P.text(x - 0.022, -0.14 + i * 0.018, t, size=0.0036, color=(140, 140, 145))
        cx = x + (-0.03 if c == 0 else 0.03)
        P.circle(cx, -0.04, 0.0095, outline=(110, 110, 115))
        P.text(cx, -0.054, "CUE", size=0.0033)
    # 真ん中の LED は観客の盛り上がり表示
    P.rect(0, -0.0505, 0.026, 0.14, outline=(55, 55, 60))
    P.text(0, -0.128, "CROWD", size=0.0040, color=(160, 160, 165))
    P.text(0, -0.134, "ENERGY", size=0.0040, color=(160, 160, 165))
    P.text(0, 0.17 - 0.024, "MASTER", size=0.0042)
    P.ring_ticks(0, 0.17, 0.016, n=11, length=0.003)
    # クロスフェーダー
    for i in range(9):
        x = -0.05 + i * 0.0125
        a, b = P.p(x, -0.172), P.p(x, -0.176 if i % 4 == 0 else -0.174)
        P.g.line([a, b], fill=(160, 160, 165), width=3)
    P.text(-0.062, -0.185, "A", size=0.006)
    P.text(0.062, -0.185, "B", size=0.006)
    P.text(0, -0.2, "CROSSFADER", size=0.0038, color=(140, 140, 145))
    P.save("mixer_print")

def booth_top():
    # 黒い天板：細かい擦り傷
    W, H = 1600, 700
    img = Image.new("RGB", (W, H), (16, 15, 15))
    g = ImageDraw.Draw(img)
    rnd = random.Random(3)
    for _ in range(900):
        x, y = rnd.randrange(W), rnd.randrange(H)
        l = rnd.randint(4, 40)
        a = rnd.uniform(0, math.pi)
        c = rnd.randint(22, 34)
        g.line([(x, y), (x + math.cos(a) * l, y + math.sin(a) * l)], fill=(c, c, c), width=1)
    img = img.filter(ImageFilter.GaussianBlur(0.6))
    img.save(os.path.join(OUT, "booth_top_tex.png"))
    print("tex booth_top_tex")

if __name__ == "__main__":
    deck("A"); deck("B"); mixer(); booth_top()
