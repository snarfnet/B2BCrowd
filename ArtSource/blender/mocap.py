# CMU モーションキャプチャ（BVH、cgspeed 版。CMU は全用途で自由に使える）を、
# 骨の「向き」に直して clips.py の仕組みで Mixamo 互換リグへ載せる。
import math
import numpy as np

class Joint:
    def __init__(self, name, parent):
        self.name, self.parent = name, parent
        self.offset = np.zeros(3)
        self.channels = []
        self.children = []
        self.end = None   # End Site のオフセット

def parse(path):
    toks = open(path).read().split()
    i = 0
    order, joints, stack = [], {}, []
    pending = None
    def last_joint():
        for x in reversed(stack):
            if isinstance(x, Joint):
                return x
        return None
    while toks[i] != "MOTION":
        t = toks[i]
        if t in ("ROOT", "JOINT"):
            j = Joint(toks[i + 1], last_joint())
            joints[j.name] = j
            order.append(j)
            pending = j
            i += 2
        elif t == "End":
            pending = "end"
            i += 2
        elif t == "{":
            stack.append(pending)
            i += 1
        elif t == "}":
            stack.pop()
            i += 1
        elif t == "OFFSET":
            v = np.array([float(x) for x in toks[i + 1:i + 4]])
            if stack[-1] == "end":
                last_joint().end = v
            else:
                stack[-1].offset = v
            i += 4
        elif t == "CHANNELS":
            n = int(toks[i + 1])
            stack[-1].channels = toks[i + 2:i + 2 + n]
            i += 2 + n
        else:
            i += 1
    i += 1
    nframes = int(toks[i + 1]); i += 2
    ft = float(toks[i + 2]); i += 3
    data = np.array([float(x) for x in toks[i:]]).reshape(nframes, -1)
    return order, joints, data, ft

def rot(axis, deg):
    a = math.radians(deg); c, s = math.cos(a), math.sin(a)
    if axis == "X": return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])
    if axis == "Y": return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])

def fk(order, data_row):
    """各関節のワールド位置（BVH 空間）"""
    pos, R = {}, {}
    k = 0
    for j in order:
        vals = data_row[k:k + len(j.channels)]; k += len(j.channels)
        local_t = j.offset.copy()
        Rl = np.eye(3)
        for ch, v in zip(j.channels, vals):
            if ch.endswith("position"):
                local_t["XYZ".index(ch[0])] = v
            else:
                Rl = Rl @ rot(ch[0], v)
        if j.parent is None:
            R[j.name] = Rl; pos[j.name] = local_t
        else:
            R[j.name] = R[j.parent.name] @ Rl
            pos[j.name] = pos[j.parent.name] + R[j.parent.name] @ local_t
        if j.end is not None:
            pos[j.name + "_end"] = pos[j.name] + R[j.name] @ j.end
    return pos

# Mixamo の骨 → BVH の（根元, 先）
BONES = {
    "Spine": ("LowerBack", "Spine"), "Spine1": ("Spine", "Spine1"), "Spine2": ("Spine1", "Neck"),
    "Neck": ("Neck", "Head"), "Head": ("Head", "Head_end"),
    "LeftShoulder": ("LeftShoulder", "LeftArm"), "LeftArm": ("LeftArm", "LeftForeArm"),
    "LeftForeArm": ("LeftForeArm", "LeftHand"), "LeftHand": ("LeftHand", "LeftFingerBase"),
    "RightShoulder": ("RightShoulder", "RightArm"), "RightArm": ("RightArm", "RightForeArm"),
    "RightForeArm": ("RightForeArm", "RightHand"), "RightHand": ("RightHand", "RightFingerBase"),
    "LeftUpLeg": ("LeftUpLeg", "LeftLeg"), "LeftLeg": ("LeftLeg", "LeftFoot"), "LeftFoot": ("LeftFoot", "LeftToeBase"),
    "RightUpLeg": ("RightUpLeg", "RightLeg"), "RightLeg": ("RightLeg", "RightFoot"), "RightFoot": ("RightFoot", "RightToeBase"),
}

def clamp_tilt(d, max_deg):
    """縦からの傾きを max_deg までに抑える（人混みで寝転がって見えないように）"""
    up = np.array([0, 0, 1.0])
    d = d / np.linalg.norm(d)
    ang = math.acos(max(-1.0, min(1.0, float(d @ up))))
    lim = math.radians(max_deg)
    if ang <= lim:
        return d
    h = d - up * (d @ up)
    if np.linalg.norm(h) < 1e-6:
        return up
    h /= np.linalg.norm(h)
    return up * math.cos(lim) + h * math.sin(lim)

def to_blender(v):
    # BVH（y 上）→ Blender（z 上）
    return np.array([v[0], -v[2], v[1]])

def clip(path, start_s, length_s, fps=30, blend_s=0.6):
    """BVH の一部を取り出し、骨の向き・横向き・腰のずれをフレームごとに返す（ループ用につなぎ目を混ぜる）"""
    order, joints, data, ft = parse(path)
    step = (1 / fps) / ft
    n = int(length_s * fps)
    frames = []
    for f in range(n + int(blend_s * fps)):
        idx = int(round(start_s / ft + f * step))
        idx = min(idx, len(data) - 1)
        p = {k: to_blender(v) for k, v in fk(order, data[idx]).items()}
        frames.append(p)
    # 向きをそろえる：最初のフレームで正面が -y になるよう z 軸回りに回す
    def facing(p):
        side = p["LeftUpLeg"] - p["RightUpLeg"]
        fwd = np.cross(side, np.array([0, 0, 1.0]))
        return math.atan2(fwd[0], -fwd[1])
    yaw = -np.mean([facing(p) for p in frames[: fps]])   # 元の向きを打ち消す
    c, s = math.cos(yaw), math.sin(yaw)
    Rz = np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])
    frames = [{k: Rz @ v for k, v in p.items()} for p in frames]
    # 脚の長さで腰の動きを人の大きさにそろえる
    leg = np.mean([np.linalg.norm(p["LeftUpLeg"] - p["LeftFoot"]) for p in frames])
    scale = 0.82 / leg
    hips = np.array([p["Hips"] for p in frames])
    base_z = np.median(hips[:, 2])
    # 横方向は 1 秒の移動平均を引いて、その場で揺れるだけにする
    k = fps
    smooth = np.array([hips[max(0, i - k // 2): i + k // 2 + 1, :2].mean(axis=0) for i in range(len(hips))])
    out = []
    for i, p in enumerate(frames):
        dirs = {}
        for b, (a, e) in BONES.items():
            if a in p and e in p:
                d = p[e] - p[a]
                if np.linalg.norm(d) > 1e-6:
                    d = d / np.linalg.norm(d)
                    if b in ("Spine", "Spine1", "Spine2", "Neck", "Head"):
                        d = clamp_tilt(d, 30)
                    dirs[b] = d
        hip_side = p["LeftUpLeg"] - p["RightUpLeg"]
        chest_side = p["LeftArm"] - p["RightArm"]
        off = np.zeros(3)
        off[:2] = np.clip((hips[i, :2] - smooth[i]) * scale, -0.12, 0.12)
        off[2] = np.clip((hips[i, 2] - base_z) * scale, -0.25, 0.3)
        hip_up = p["Spine"] - p["Hips"] if "Spine" in p else np.array([0, 0, 1.0])
        out.append(dict(dirs=dirs, hip_up=clamp_tilt(hip_up, 20), hip_side=hip_side / np.linalg.norm(hip_side),
                        chest_side=chest_side / np.linalg.norm(chest_side), hips=off))
    # ループ：最後の blend 分を最初へ混ぜる
    nb = int(blend_s * fps)
    for j in range(nb):
        w = (j + 1) / (nb + 1)
        a, b = out[n + j], out[j]
        mixed = {}
        for bn in b["dirs"]:
            if bn in a["dirs"]:
                v = a["dirs"][bn] * (1 - w) + b["dirs"][bn] * w
                mixed[bn] = v / np.linalg.norm(v)
        def mx(x, y):
            v = x * (1 - w) + y * w
            return v / np.linalg.norm(v)
        out[j] = dict(dirs=mixed, hip_up=mx(a["hip_up"], b["hip_up"]), hip_side=mx(a["hip_side"], b["hip_side"]),
                      chest_side=mx(a["chest_side"], b["chest_side"]), hips=a["hips"] * (1 - w) + b["hips"] * w)
    return out[:n]
