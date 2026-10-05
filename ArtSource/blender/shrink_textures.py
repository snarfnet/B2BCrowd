# 書き出したテクスチャを 1024 に縮め、アルファ無しは JPEG にして DAE の参照も書き換える
import os, sys
from PIL import Image
ROOT = sys.argv[1]
for d, _, files in os.walk(ROOT):
    daes = [os.path.join(d, f) for f in files if f.endswith(".dae")]
    for f in files:
        if not f.lower().endswith(".png"):
            continue
        path = os.path.join(d, f)
        im = Image.open(path)
        im.load()
        if max(im.size) > 1024:
            im.thumbnail((1024, 1024))
        alpha = im.mode in ("RGBA", "LA") and im.getchannel("A").getextrema()[0] < 250
        if alpha:
            im.save(path, optimize=True)
            continue
        jpg = f[:-4] + ".jpg"
        im.convert("RGB").save(os.path.join(d, jpg), quality=85)
        os.remove(path)
        for dae in daes:
            t = open(dae, encoding="utf-8").read()
            open(dae, "w", encoding="utf-8").write(t.replace(f, jpg))
    # Blender が Y 上に変換済みなのにヘッダーが Z_UP のままなので直す（SceneKit が二重に回さないように）
    for dae in daes:
        t = open(dae, encoding="utf-8").read()
        open(dae, "w", encoding="utf-8").write(t.replace("<up_axis>Z_UP</up_axis>", "<up_axis>Y_UP</up_axis>"))
    print(d, "ok")
