# 観客の動き（ループ）を「骨の向き」で定義し、骨ローカルの回転差分として JSON に書き出す。
# 座標はキャラクター空間（Blender）：x = 本人の左、y = 背中側、z = 上。正面は -y。
# アプリ側は  orientation = バインド姿勢 × 差分  で再生するので、体格が違っても同じクリップを使える。
import sys, os, bpy, json, math
from mathutils import Vector, Matrix, Quaternion
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mh_common as mh
import mocap
MOCAP_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mocap")
# 名前: (BVH, 開始秒, 長さ秒)
MOCAP = {
    "dance_twist": ("141_12.bvh", 0.4, 3.6),
    "dance_a": ("111_05.bvh", 1.0, 5.0),
    "dance_b": ("113_04.bvh", 1.0, 5.0),
    "macarena": ("143_35.bvh", 1.0, 8.0),
    "jump_mc": ("49_02.bvh", 1.0, 4.0),
    "mickey": ("120_05.bvh", 1.0, 6.0),
}

FPS = 30
P = "mixamorig:"

def V(x, y, z):
    return Vector((x, y, z)).normalized()

def mirror_dirs(d):
    """左の向きから右の向きを作る（x を反転）"""
    out = {}
    for k, v in d.items():
        if k.startswith("Left"):
            out["Right" + k[4:]] = Vector((-v.x, v.y, v.z))
    return out

def both(d):
    d = {k: V(*v) for k, v in d.items()}
    d.update(mirror_dirs(d))
    return d

def dirs(d):
    return {k: V(*v) for k, v in d.items()}

# 腕・脚の基本形
DOWN = both({"LeftArm": (0.14, 0.04, -1), "LeftForeArm": (0.08, -0.12, -1), "LeftHand": (0.06, -0.15, -1)})
LEGS = both({"LeftUpLeg": (0.04, 0.0, -1), "LeftLeg": (0.0, 0.05, -1)})

def lerp_pose(a, b, t):
    keys = set(a) | set(b)
    out = {}
    for k in keys:
        va, vb = a.get(k), b.get(k)
        if va is None: out[k] = vb; continue
        if vb is None: out[k] = va; continue
        out[k] = (va.lerp(vb, t)).normalized()
    return out

def ease(t):
    return 0.5 - 0.5 * math.cos(math.pi * t)

# クリップ：キーフレーム [(秒, {骨: 向き}, 腰オフセット(x,y,z), 体の傾き(骨:向き)…)]
def clip_crossed():
    base = {**LEGS, **dirs({
        "LeftArm": (0.22, -0.3, -0.93), "RightArm": (-0.22, -0.3, -0.93),
        "LeftForeArm": (-0.95, -0.3, 0.12), "RightForeArm": (0.95, -0.38, 0.2),
        "LeftHand": (-0.9, -0.2, 0.0), "RightHand": (0.9, -0.3, 0.1)})}
    b2 = dict(base); b2["Head"] = V(0.08, -0.05, 1)
    return 4.0, [(0, base, (0, 0, 0)), (2.0, b2, (0.01, 0, 0)), (4.0, base, (0, 0, 0))]

def clip_phone():
    base = {**LEGS, **DOWN, **dirs({
        "RightArm": (-0.12, -0.35, -0.93), "RightForeArm": (0.3, -0.75, 0.6), "RightHand": (0.3, -0.85, 0.4),
        "LeftArm": (0.1, -0.25, -0.96), "LeftForeArm": (-0.35, -0.8, 0.45), "LeftHand": (-0.3, -0.9, 0.2),
        "Neck": (0, -0.25, 0.97), "Head": (0, -0.55, 0.83)})}
    b2 = dict(base); b2["Head"] = V(0.05, -0.5, 0.86)
    return 3.0, [(0, base, (0, 0, 0)), (1.5, b2, (0, 0, 0)), (3.0, base, (0, 0, 0))]

def clip_sway():
    l = {**LEGS, **DOWN, **dirs({"Spine1": (0.08, 0.0, 1), "Head": (0.06, -0.05, 1)})}
    r = {**LEGS, **DOWN, **dirs({"Spine1": (-0.08, 0.0, 1), "Head": (-0.06, -0.05, 1)})}
    return 2.0, [(0, l, (-0.02, 0, 0)), (1.0, r, (0.02, 0, 0)), (2.0, l, (-0.02, 0, 0))]

def clip_bounce():
    up = {**dirs({"LeftUpLeg": (0.05, -0.1, -1), "RightUpLeg": (-0.05, -0.1, -1), "LeftLeg": (0, 0.1, -1), "RightLeg": (0, 0.1, -1)}),
          **both({"LeftArm": (0.4, -0.15, -0.9), "LeftForeArm": (0.15, -0.95, 0.25), "LeftHand": (0.1, -1, 0.1)}),
          **dirs({"Head": (0, -0.12, 1)})}
    down = {**dirs({"LeftUpLeg": (0.06, -0.38, -0.92), "RightUpLeg": (-0.06, -0.38, -0.92), "LeftLeg": (0, 0.35, -0.94), "RightLeg": (0, 0.35, -0.94),
                    "LeftFoot": (0, -0.9, -0.45), "RightFoot": (0, -0.9, -0.45)}),
            **both({"LeftArm": (0.4, -0.2, -0.88), "LeftForeArm": (0.15, -0.7, 0.7), "LeftHand": (0.1, -0.6, 0.8)}),
            **dirs({"Head": (0, -0.3, 0.95), "Spine1": (0, -0.12, 1)})}
    return 1.0, [(0, up, (0, 0, 0)), (0.5, down, (0, 0, -0.06)), (1.0, up, (0, 0, 0))]

def clip_clap():
    open_ = {**LEGS, **both({"LeftArm": (0.3, -0.6, -0.75), "LeftForeArm": (-0.15, -0.95, 0.3), "LeftHand": (-0.25, -0.9, 0.3)}), **dirs({"Head": (0, -0.1, 1)})}
    shut = {**LEGS, **both({"LeftArm": (0.22, -0.65, -0.73), "LeftForeArm": (-0.55, -0.8, 0.3), "LeftHand": (-0.75, -0.6, 0.3)}), **dirs({"Head": (0, -0.2, 1)})}
    return 0.6, [(0, open_, (0, 0, 0)), (0.3, shut, (0, 0, -0.02)), (0.6, open_, (0, 0, 0))]

def clip_hands_up():
    a = {**LEGS, **both({"LeftArm": (0.5, -0.1, 0.86), "LeftForeArm": (0.25, -0.1, 1), "LeftHand": (0.2, -0.1, 1)}), **dirs({"Head": (0, 0.15, 1)})}
    b = {**dirs({"LeftUpLeg": (0.06, -0.3, -0.95), "RightUpLeg": (-0.06, -0.3, -0.95), "LeftLeg": (0, 0.3, -0.95), "RightLeg": (0, 0.3, -0.95)}),
         **both({"LeftArm": (0.6, -0.15, 0.78), "LeftForeArm": (0.5, -0.1, 0.86), "LeftHand": (0.45, -0.1, 0.9)}), **dirs({"Head": (0, 0.05, 1)})}
    return 0.9, [(0, a, (0, 0, 0)), (0.45, b, (0, 0, -0.05)), (0.9, a, (0, 0, 0))]

def clip_jump():
    crouch = {**dirs({"LeftUpLeg": (0.06, -0.5, -0.86), "RightUpLeg": (-0.06, -0.5, -0.86), "LeftLeg": (0, 0.5, -0.86), "RightLeg": (0, 0.5, -0.86),
                      "LeftFoot": (0, -0.95, -0.3), "RightFoot": (0, -0.95, -0.3)}),
              **both({"LeftArm": (0.45, -0.2, 0.86), "LeftForeArm": (0.3, -0.2, 0.93), "LeftHand": (0.3, -0.2, 0.93)})}
    air = {**dirs({"LeftUpLeg": (0.05, -0.15, -1), "RightUpLeg": (-0.05, -0.15, -1), "LeftLeg": (0, 0.2, -1), "RightLeg": (0, 0.2, -1),
                   "LeftFoot": (0, -0.5, -0.86), "RightFoot": (0, -0.5, -0.86)}),
           **both({"LeftArm": (0.3, -0.05, 1), "LeftForeArm": (0.15, -0.05, 1), "LeftHand": (0.15, -0.05, 1)}), **dirs({"Head": (0, 0.2, 1)})}
    return 0.8, [(0, crouch, (0, 0, -0.1)), (0.4, air, (0, 0, 0.18)), (0.8, crouch, (0, 0, -0.1))]

def clip_idle():
    a = {**LEGS, **DOWN, **dirs({"Head": (0.03, -0.05, 1)})}
    b = {**LEGS, **DOWN, **dirs({"Head": (-0.04, -0.08, 1), "Spine1": (0.02, 0, 1)})}
    return 4.0, [(0, a, (0, 0, 0)), (2.0, b, (0.005, 0, 0)), (4.0, a, (0, 0, 0))]

CLIPS = {"idle": clip_idle, "crossed": clip_crossed, "phone": clip_phone, "sway": clip_sway,
         "bounce": clip_bounce, "clap": clip_clap, "hands_up": clip_hands_up, "jump": clip_jump}

# 親から順に処理する骨
ORDER = ["Hips", "Spine", "Spine1", "Spine2", "Neck", "Head",
         "LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand", "RightShoulder", "RightArm", "RightForeArm", "RightHand",
         "LeftUpLeg", "LeftLeg", "LeftFoot", "RightUpLeg", "RightLeg", "RightFoot"]

_side_local = {}

def side_ref(rig):
    """腰と胸の「左右」の向きを骨ローカルで覚えておく（休止姿勢）"""
    if _side_local:
        return _side_local
    bones = rig.data.bones
    for n, (l, r) in {"Hips": ("LeftUpLeg", "RightUpLeg"), "Spine2": ("LeftArm", "RightArm")}.items():
        side = (bones[P + l].head_local - bones[P + r].head_local).normalized()
        _side_local[n] = bones[P + n].matrix_local.to_3x3().inverted() @ side
    return _side_local

def solve(rig, pose):
    sides = side_ref(rig)
    for n in ORDER:
        pb = rig.pose.bones[P + n]
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = Quaternion()
        pb.scale = (1, 1, 1)
        if n != "Hips":
            pb.location = (0, 0, 0)
    bpy.context.view_layer.update()
    for n in ORDER:
        if n not in pose:
            continue
        pb = rig.pose.bones[P + n]
        M = pb.matrix.copy()
        y = M.to_3x3().col[1].normalized()
        q = y.rotation_difference(pose[n])
        R = q.to_matrix() @ M.to_3x3()
        key = "__side_" + n
        if key in pose and n in sides:
            yv = pose[n]
            cur = (R @ sides[n])
            tgt = pose[key]
            cur = (cur - yv * cur.dot(yv)).normalized()
            tgt = (tgt - yv * tgt.dot(yv)).normalized()
            ang = math.atan2(yv.dot(cur.cross(tgt)), cur.dot(tgt))
            R = Quaternion(yv, ang).to_matrix() @ R
        R = R.to_quaternion().normalized().to_matrix()
        pb.matrix = Matrix.Translation(M.translation) @ R.to_4x4()
        pb.scale = (1, 1, 1)
        bpy.context.view_layer.update()
    return {n: tuple(rig.pose.bones[P + n].rotation_quaternion) for n in ORDER}

def sample(keys, t):
    for i in range(len(keys) - 1):
        t0, p0, h0 = keys[i]
        t1, p1, h1 = keys[i + 1]
        if t0 <= t <= t1:
            u = ease((t - t0) / (t1 - t0))
            hip = tuple(h0[j] + (h1[j] - h0[j]) * u for j in range(3))
            return lerp_pose(p0, p1, u), hip
    return keys[-1][1], keys[-1][2]

def build(out_path, preview_dir=None):
    mh.clear(); mh.ensure_pack()
    body = mh.make_human("ref", {"gender": 0.5}, "young_caucasian_male", ["male_casualsuit02"], hair="", eyebrows="", proxy="male_generic")
    rig = body.parent
    data = {"fps": FPS, "clips": {}}
    for name, fn in CLIPS.items():
        dur, keys = fn()
        n = int(round(dur * FPS))
        bones = {P + b: [] for b in ORDER}
        hips = []
        for f in range(n):
            pose, hip = sample(keys, f / FPS)
            rots = solve(rig, pose)
            for b in ORDER:
                w, x, y, z = rots[b]
                bones[P + b] += [round(x, 4), round(y, 4), round(z, 4), round(w, 4)]
            hips += [round(v, 4) for v in hip]
        data["clips"][name] = {"frames": n, "bones": bones, "hips": hips}
    for name, (bvh, st, ln) in MOCAP.items():
        frames = mocap.clip(os.path.join(MOCAP_DIR, bvh), st, ln, fps=FPS)
        bones = {P + b: [] for b in ORDER}
        hips = []
        for fr in frames:
            pose = {k: Vector(v) for k, v in fr["dirs"].items()}
            pose["Hips"] = Vector(fr["hip_up"])
            pose["__side_Hips"] = Vector(fr["hip_side"])
            pose["__side_Spine2"] = Vector(fr["chest_side"])
            rots = solve(rig, pose)
            for b in ORDER:
                w, x, y, z = rots[b]
                bones[P + b] += [round(x, 4), round(y, 4), round(z, 4), round(w, 4)]
            hips += [round(float(v), 4) for v in fr["hips"]]
        data["clips"][name] = {"frames": len(frames), "bones": bones, "hips": hips}
        print("MOCAP", name, len(frames))
        if preview_dir:
            for q in (0.25, 0.6):
                fr = frames[int(len(frames) * q)]
                pose = {k: Vector(v) for k, v in fr["dirs"].items()}
                pose["Hips"] = Vector(fr["hip_up"]); pose["__side_Hips"] = Vector(fr["hip_side"]); pose["__side_Spine2"] = Vector(fr["chest_side"])
                solve(rig, pose)
                mh_preview_pose(rig, os.path.join(preview_dir, f"mc_{name}_{int(q * 100)}.png"), tuple(fr["hips"]))
        if preview_dir:
            pose, hip = sample(keys, dur / 2)
            solve(rig, pose)
            mh_preview_pose(rig, os.path.join(preview_dir, f"clip_{name}.png"), hip)
            pose, hip = sample(keys, 0)
            solve(rig, pose)
            mh_preview_pose(rig, os.path.join(preview_dir, f"clip_{name}_0.png"), hip)
    json.dump(data, open(out_path, "w"), separators=(",", ":"))
    print("WROTE", out_path, os.path.getsize(out_path))

_cam_ready = [False]
def mh_preview_pose(rig, path, hip):
    rig.pose.bones[P + "Hips"].location = (0, 0, 0)
    sc = bpy.context.scene
    if not _cam_ready[0]:
        sc.render.engine = "BLENDER_EEVEE_NEXT"
        sc.render.resolution_x, sc.render.resolution_y = 400, 600
        w = bpy.data.worlds.new("w"); sc.world = w; w.use_nodes = True
        w.node_tree.nodes["Background"].inputs[0].default_value = (0.25, 0.25, 0.28, 1)
        cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
        sc.collection.objects.link(cam); sc.camera = cam
        cam.location = (1.4, -2.6, 1.3)
        cam.rotation_euler = (Vector((0, 0, 0.95)) - cam.location).to_track_quat('-Z', 'Y').to_euler()
        sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN")); sun.data.energy = 3
        sun.rotation_euler = (0.8, 0.2, 0.4); sc.collection.objects.link(sun)
        _cam_ready[0] = True
    rig.location = (hip[0], hip[1], hip[2])
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    rig.location = (0, 0, 0)

if __name__ == "__main__":
    out = sys.argv[sys.argv.index("--out") + 1]
    prev = sys.argv[sys.argv.index("--preview") + 1] if "--preview" in sys.argv else None
    build(out, prev)
