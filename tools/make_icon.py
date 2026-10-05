# 仮アイコン（あとで codex imagen 版に差し替え可）
from PIL import Image, ImageDraw, ImageFilter, ImageFont
S = 1024
img = Image.new("RGB", (S, S), (12, 4, 20))
d = ImageDraw.Draw(img)
for y in range(S):
    t = y / S
    d.line([(0, y), (S, y)], fill=(int(30 + 40 * t), int(6 + 4 * t), int(50 - 20 * t)))
glow = Image.new("RGB", (S, S), (0, 0, 0))
g = ImageDraw.Draw(glow)
for cx, col in ((360, (255, 40, 150)), (664, (0, 220, 255))):
    g.ellipse([cx - 250, 300, cx + 250, 800], outline=col, width=26)
glow = glow.filter(ImageFilter.GaussianBlur(28))
img.paste(glow, (0, 0), Image.eval(glow.convert("L"), lambda v: min(255, v * 2)))
d = ImageDraw.Draw(img)
for cx, col in ((360, (255, 40, 150)), (664, (0, 220, 255))):
    d.ellipse([cx - 240, 310, cx + 240, 790], fill=(14, 14, 18), outline=col, width=14)
    for r in range(60, 230, 26):
        d.ellipse([cx - r, 550 - r, cx + r, 550 + r], outline=(40, 40, 48), width=3)
    d.ellipse([cx - 70, 480, cx + 70, 620], fill=col)
    d.ellipse([cx - 10, 540, cx + 10, 560], fill=(0, 0, 0))
try:
    f = ImageFont.truetype("C:/Windows/Fonts/ariblk.ttf", 210)
except Exception:
    f = ImageFont.load_default()
txt = "B2B"
w = d.textlength(txt, font=f)
d.text(((S - w) / 2 + 6, 60 + 6), txt, font=f, fill=(255, 40, 150))
d.text(((S - w) / 2, 60), txt, font=f, fill=(255, 255, 255))
for i in range(9):
    h = [60, 110, 160, 90, 190, 130, 70, 150, 100][i]
    x = 200 + i * 72
    d.rounded_rectangle([x, 960 - h, x + 50, 960], radius=10, fill=(255, 200 - i * 15, 40 + i * 20))
img.save("B2BCrowd/Resources/Assets.xcassets/AppIcon.appiconset/icon.png")
print("ok")
