# DJ 用のロボット3体。人と同じ Mixamo 互換リグに、骨ごとの硬い部品を載せる（各部品は1本の骨に100%）。
# そのため観客の動き・DJ の手の IK がそのまま使える。
import sys, os, bpy, bmesh, math
from mathutils import Vector, Matrix
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mh_common as mh

OUT = os.path.join(mh.ROOT, "..", "B2BCrowd", "Resources", "Crowd.scnassets")
P = "mixamorig:"

MATS = {}
def mat(name, color, metal=0.0, rough=0.4, emit=None, strength=0.0):
    if name in MATS:
        return MATS[name]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Metallic"].default_value = metal
    b.inputs["Roughness"].default_value = rough
    if emit:
        b.inputs["Emission Color"].default_value = (*emit, 1)
        b.inputs["Emission Strength"].default_value = strength
    MATS[name] = m
    return m

STYLES = {
    "r01": dict(  # クロームの人型
        body=lambda: mat("robo_chrome", (0.85, 0.86, 0.9), metal=1, rough=0.12),
        joint=lambda: mat("robo_black", (0.02, 0.02, 0.025), metal=0.5, rough=0.35),
        accent=lambda: mat("robo_glow_cyan", (0.0, 0.5, 0.7), emit=(0.1, 0.8, 1.0), strength=6),
        boxy=False, limb=1.0, head="visor"),
    "r02": dict(  # 白いアンドロイド
        body=lambda: mat("robo_white", (0.92, 0.92, 0.94), metal=0.0, rough=0.22),
        joint=lambda: mat("robo_gray", (0.18, 0.19, 0.21), metal=0.6, rough=0.3),
        accent=lambda: mat("robo_glow_pink", (0.6, 0.0, 0.3), emit=(1.0, 0.2, 0.6), strength=6),
        boxy=False, limb=0.85, head="face"),
    "r03": dict(  # 角ばった昔のロボ
        body=lambda: mat("robo_orange", (0.85, 0.32, 0.05), metal=0.3, rough=0.4),
        joint=lambda: mat("robo_gunmetal", (0.12, 0.12, 0.13), metal=0.85, rough=0.3),
        accent=lambda: mat("robo_lamp", (0.6, 0.5, 0.0), emit=(1.0, 0.85, 0.2), strength=6),
        boxy=True, limb=1.25, head="box"),
}

def add_part(parts, bone, prim, size, center_local, rot_local, m, bone_mat):
    """骨の休止行列を基準に、ローカル位置・回転で部品を置く"""
    if prim == "cyl":
        bpy.ops.mesh.primitive_cylinder_add(vertices=24, radius=1, depth=1)
    elif prim == "sphere":
        bpy.ops.mesh.primitive_uv_sphere_add(segments=24, ring_count=12, radius=1)
    else:
        bpy.ops.mesh.primitive_cube_add(size=1)
    o = bpy.context.object
    o.data.materials.append(m)
    o.matrix_world = bone_mat @ Matrix.Translation(center_local) @ rot_local.to_4x4() @ Matrix.Diagonal((*size, 1))
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    if prim != "sphere":
        bv = o.modifiers.new("bev", "BEVEL"); bv.width = min(size) * 0.25; bv.segments = 3; bv.limit_method = "ANGLE"
        bpy.ops.object.modifier_apply(modifier="bev")
    for p in o.data.polygons:
        p.use_smooth = True
    vg = o.vertex_groups.new(name=bone)
    vg.add(list(range(len(o.data.vertices))), 1.0, "REPLACE")
    parts.append(o)
    return o

Y_TO_Z = Matrix.Rotation(math.radians(-90), 3, "X")   # 円柱（z 軸）を骨の向き（y 軸）へ

def build(name, st):
    mh.clear(); mh.ensure_pack()
    body = mh.make_human(name, {"gender": 0.6, "muscle": 0.6, "height": 0.6}, "young_caucasian_male", [], hair="", eyebrows="", proxy="")
    rig = body.parent
    for o in list(bpy.data.objects):
        if o.type == "MESH":
            bpy.data.objects.remove(o, do_unlink=True)
    rig.name = "rig"
    bones = rig.data.bones
    B, J, A = st["body"](), st["joint"](), st["accent"]()
    boxy = st["boxy"]
    k = st["limb"]
    parts = []

    def bm(n):
        return bones[P + n].matrix_local.copy()

    def length(n):
        return bones[P + n].length

    def limb(n, r, m=B):
        L = length(n)
        if boxy:
            add_part(parts, P + n, "box", (r * 2.1, L * 0.86, r * 2.1), Vector((0, L / 2, 0)), Matrix.Identity(3), m, bm(n))
        else:
            add_part(parts, P + n, "cyl", (r, r, L * 0.86), Vector((0, L / 2, 0)), Y_TO_Z, m, bm(n))

    def joint(n, r):
        add_part(parts, P + n, "sphere", (r, r, r), Vector((0, 0, 0)), Matrix.Identity(3), J, bm(n))

    # 脚
    for s in ("Left", "Right"):
        limb(s + "UpLeg", 0.062 * k); joint(s + "UpLeg", 0.07 * k)
        limb(s + "Leg", 0.05 * k); joint(s + "Leg", 0.058 * k)
        joint(s + "Foot", 0.048 * k)
        add_part(parts, P + s + "Foot", "box", (0.1 * k, length(s + "Foot") * 1.25, 0.07 * k), Vector((0, length(s + "Foot") * 0.55, -0.02)),
                 Matrix.Identity(3), B, bm(s + "Foot"))
        add_part(parts, P + s + "ToeBase", "box", (0.095 * k, length(s + "ToeBase") * 1.1, 0.05 * k), Vector((0, length(s + "ToeBase") * 0.5, -0.02)),
                 Matrix.Identity(3), J, bm(s + "ToeBase"))
    # 胴
    add_part(parts, P + "Hips", "box", (0.32, 0.16, 0.2), Vector((0, 0.05, 0)), Matrix.Identity(3), J, bm("Hips"))
    add_part(parts, P + "Spine", "cyl" if not boxy else "box", (0.12, 0.1, length("Spine")) if not boxy else (0.24, length("Spine"), 0.18),
             Vector((0, length("Spine") / 2, 0)), Y_TO_Z if not boxy else Matrix.Identity(3), J, bm("Spine"))
    add_part(parts, P + "Spine1", "box", (0.3, length("Spine1") * 1.05, 0.2), Vector((0, length("Spine1") / 2, 0.01)), Matrix.Identity(3), B, bm("Spine1"))
    add_part(parts, P + "Spine2", "box", (0.42 if boxy else 0.38, length("Spine2") * 1.3, 0.25), Vector((0, length("Spine2") * 0.6, 0.015)), Matrix.Identity(3), B, bm("Spine2"))
    # 胸の光るライン
    add_part(parts, P + "Spine2", "box", (0.2, 0.02, 0.01), Vector((0, length("Spine2") * 0.75, 0.14)), Matrix.Identity(3), A, bm("Spine2"))
    # 腕
    for s in ("Left", "Right"):
        joint(s + "Arm", 0.075 * k)
        limb(s + "Arm", 0.045 * k); limb(s + "ForeArm", 0.04 * k)
        joint(s + "ForeArm", 0.048 * k); joint(s + "Hand", 0.035)
        # 手のひら
        hm = bm(s + "Hand")
        add_part(parts, P + s + "Hand", "box", (0.085, 0.09, 0.03), Vector((0, 0.05, 0)), Matrix.Identity(3), B, hm)
        for f in ("Thumb", "Index", "Middle", "Ring", "Pinky"):
            for i in (1, 2, 3):
                n = f"{s}Hand{f}{i}"
                if P + n not in bones:
                    continue
                L = max(length(n), 0.018)
                add_part(parts, P + n, "box" if boxy else "cyl", (0.018, L * 0.9, 0.018) if boxy else (0.0095, 0.0095, L * 0.9),
                         Vector((0, L / 2, 0)), Matrix.Identity(3) if boxy else Y_TO_Z, J if i == 1 else B, bm(n))
    # 首と頭
    limb("Neck", 0.045, J)
    hd = bm("Head")
    if st["head"] == "visor":
        add_part(parts, P + "Head", "sphere", (0.105, 0.13, 0.115), Vector((0, 0.1, 0.0)), Matrix.Identity(3), B, hd)
        add_part(parts, P + "Head", "sphere", (0.09, 0.035, 0.07), Vector((0, 0.11, 0.065)), Matrix.Identity(3), A, hd)
    elif st["head"] == "face":
        add_part(parts, P + "Head", "box", (0.19, 0.24, 0.21), Vector((0, 0.11, 0.0)), Matrix.Identity(3), B, hd)
        add_part(parts, P + "Head", "box", (0.15, 0.1, 0.02), Vector((0, 0.1, 0.105)), Matrix.Identity(3), J, hd)
        for sx in (-0.035, 0.035):
            add_part(parts, P + "Head", "sphere", (0.014, 0.008, 0.006), Vector((sx, 0.115, 0.117)), Matrix.Identity(3), A, hd)
    else:
        add_part(parts, P + "Head", "box", (0.24, 0.22, 0.22), Vector((0, 0.11, 0.0)), Matrix.Identity(3), B, hd)
        for sx in (-0.05, 0.05):
            add_part(parts, P + "Head", "cyl", (0.03, 0.03, 0.02), Vector((sx, 0.12, 0.11)), Matrix.Rotation(0, 3, "X"), A, hd)
        add_part(parts, P + "Head", "cyl", (0.006, 0.006, 0.12), Vector((0.07, 0.27, 0)), Y_TO_Z, J, hd)
        add_part(parts, P + "Head", "sphere", (0.018, 0.018, 0.018), Vector((0.07, 0.33, 0)), Matrix.Identity(3), A, hd)

    # 1つのメッシュにまとめてリグに付ける
    bpy.ops.object.select_all(action="DESELECT")
    for o in parts:
        o.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    bpy.ops.object.join()
    robo = bpy.context.object
    robo.name = f"{name}.robot"
    robo.parent = rig
    md = robo.modifiers.new("arm", "ARMATURE"); md.object = rig
    robo.modifiers.new("tri", "TRIANGULATE")
    print("ROBOT", name, len(robo.data.polygons))
    return rig, robo

def export(name):
    d = os.path.join(OUT, name)
    os.makedirs(d, exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.wm.collada_export(filepath=os.path.join(d, name + ".dae"), selected=True, apply_modifiers=True,
                              triangulate=True, include_armatures=True, deform_bones_only=True,
                              export_global_forward_selection="-Z", export_global_up_selection="Y",
                              apply_global_orientation=True, include_animations=False)

def preview(path):
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_EEVEE_NEXT"
    sc.render.resolution_x, sc.render.resolution_y = 500, 700
    w = bpy.data.worlds.new("w"); sc.world = w; w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.06, 0.05, 0.08, 1)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam")); sc.collection.objects.link(cam); sc.camera = cam
    cam.location = (0.9, -2.6, 1.3)
    cam.rotation_euler = (Vector((0, 0, 0.95)) - cam.location).to_track_quat('-Z', 'Y').to_euler()
    for loc, e, c in [((1.5, -2, 2.5), 400, (1, 1, 1)), ((-2, 1, 1.5), 300, (0.4, 0.6, 1)), ((1.5, 2, 1.0), 200, (1, 0.3, 0.7))]:
        L = bpy.data.objects.new("l", bpy.data.lights.new("l", "AREA")); L.data.energy = e; L.data.color = c; L.data.size = 1.5
        L.location = loc; L.rotation_euler = (Vector((0, 0, 1)) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
        sc.collection.objects.link(L)
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)

if __name__ == "__main__":
    only = sys.argv[sys.argv.index("--only") + 1].split(",") if "--only" in sys.argv else list(STYLES)
    for name in only:
        MATS.clear()
        rig, robo = build(name, STYLES[name])
        if "--preview" in sys.argv:
            preview(os.path.join(mh.ROOT, "out", f"{name}_preview.png"))
        else:
            export(name)
