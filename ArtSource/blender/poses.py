# 観客のポーズ定義（Mixamo 互換リグの骨ローカル回転、度）。キー = 骨名（mixamorig: を除く）
# 値 = (X, Y, Z) オイラー。左右の符号は pose_tester で確認済みのものを使う。
import math
def mirror(p):
    out = {}
    for k, v in p.items():
        if k.startswith("Left"):
            out["Right" + k[4:]] = (v[0], -v[1], -v[2])
        elif k.startswith("Right"):
            out["Left" + k[5:]] = (v[0], -v[1], -v[2])
        else:
            out[k] = v
    return out

def sym(p):
    q = dict(p)
    q.update(mirror({k: v for k, v in p.items() if k.startswith("Left")}))
    return q

ARMS_DOWN = sym({"LeftArm": (0, 0, 35), "LeftForeArm": (8, 0, 0)})
POSES = {
    "rest": {},
    "arms_down": ARMS_DOWN,
    "crossed": sym({"LeftArm": (25, 0, 30), "LeftForeArm": (110, 0, 25), "LeftHand": (0, 0, 0)}),
    "hands_up": sym({"LeftArm": (20, 0, -95), "LeftForeArm": (15, 0, 0)}),
    "clap": sym({"LeftArm": (55, 0, 25), "LeftForeArm": (60, 0, 30)}),
    "phone": {**ARMS_DOWN, **{"RightArm": (35, 0, -25), "RightForeArm": (115, 0, 0), "Head": (25, 0, 0), "Neck": (10, 0, 0)}},
    "bounce": {**sym({"LeftArm": (25, 0, 25), "LeftForeArm": (75, 0, 0), "LeftUpLeg": (-20, 0, 0), "LeftLeg": (35, 0, 0), "LeftFoot": (-15, 0, 0)}), "Spine1": (8, 0, 0)},
}
