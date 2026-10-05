# DJ ブースの機材（汎用デザイン。実在メーカーの形・ロゴは真似しない）
# 単位はメートル、Blender は Z 上。アプリ側で動かす部品は名前で探す:
#   platter_A/B, screen_A/B, play_A/B, cue_A/B, pad_A/B_0..7,
#   knob_0/1_0..4, fader_0/1, xfader, meter_0/1_0..11, booth_led
import bpy, bmesh, math, os, sys
from mathutils import Vector

def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)

MATS = {}
def mat(name, color, metal=0.0, rough=0.5, emit=None, emit_strength=0.0):
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
        b.inputs["Emission Strength"].default_value = emit_strength
    MATS[name] = m
    return m

def assign(o, m):
    o.data.materials.clear()
    o.data.materials.append(m)

def bevel(o, w=0.003, seg=3):
    md = o.modifiers.new("bev", "BEVEL")
    md.width = w
    md.segments = seg
    md.limit_method = "ANGLE"
    o.modifiers.new("wn", "WEIGHTED_NORMAL")
    for p in o.data.polygons:
        p.use_smooth = True

def box(name, size, loc, m, bev=0.003, parent=None):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc)
    o = bpy.context.object
    o.name = name
    o.scale = size
    bpy.ops.object.transform_apply(scale=True)
    assign(o, m)
    if bev:
        bevel(o, bev)
    if parent:
        o.parent = parent
    return o

def cyl(name, r, h, loc, m, verts=48, bev=0.0015, parent=None, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=r, depth=h, location=loc, rotation=rot)
    o = bpy.context.object
    o.name = name
    assign(o, m)
    if bev:
        bevel(o, bev, 2)
    if parent:
        o.parent = parent
    return o

def empty(name, loc=(0, 0, 0), parent=None):
    o = bpy.data.objects.new(name, None)
    bpy.context.scene.collection.objects.link(o)
    o.location = loc
    if parent:
        o.parent = parent
    return o

# 素材
M_BODY = lambda: mat("gunmetal", (0.045, 0.047, 0.052), metal=0.85, rough=0.38)
M_PANEL = lambda: mat("panel_black", (0.012, 0.012, 0.014), metal=0.2, rough=0.55)
M_RUBBER = lambda: mat("rubber", (0.02, 0.02, 0.02), rough=0.85)
M_ALU = lambda: mat("brushed_alu", (0.72, 0.73, 0.75), metal=1.0, rough=0.28)
M_CHROME = lambda: mat("chrome", (0.9, 0.9, 0.92), metal=1.0, rough=0.12)
M_GLASS = lambda: mat("screen_glass", (0.005, 0.008, 0.015), metal=0.0, rough=0.05)
M_KNOB = lambda: mat("knob_plastic", (0.035, 0.035, 0.038), rough=0.45)
M_CAP = lambda: mat("fader_cap", (0.08, 0.08, 0.085), rough=0.4)
M_WHITE = lambda: mat("print_white", (0.85, 0.85, 0.85), rough=0.6)
M_LABEL = lambda: mat("platter_label", (0.2, 0.2, 0.2), rough=0.4)
M_WOOD = lambda: mat("booth_top", (0.025, 0.022, 0.02), metal=0.0, rough=0.35)
M_FACADE = lambda: mat("booth_facade", (0.015, 0.015, 0.017), metal=0.3, rough=0.5)

TEX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "out", "tex")

def print_plane(name, w, d, z, parent, image):
    bpy.ops.mesh.primitive_plane_add(size=1, location=(0, 0, z))
    o = bpy.context.object
    o.name = name
    o.scale = (w, d, 1)
    bpy.ops.object.transform_apply(scale=True)
    m = bpy.data.materials.new(name + "_mat")
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    t = m.node_tree.nodes.new("ShaderNodeTexImage")
    t.image = bpy.data.images.load(os.path.join(TEX, image))
    m.node_tree.links.new(t.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = 0.55
    o.data.materials.append(m)
    o.parent = parent
    return o

def curve_tube(name, pts, r, m):
    cd = bpy.data.curves.new(name, "CURVE")
    cd.dimensions = "3D"
    cd.bevel_depth = r
    cd.bevel_resolution = 3
    sp = cd.splines.new("BEZIER")
    sp.bezier_points.add(len(pts) - 1)
    for bp, co in zip(sp.bezier_points, pts):
        bp.co = co
        bp.handle_left_type = bp.handle_right_type = "AUTO"
    o = bpy.data.objects.new(name, cd)
    bpy.context.scene.collection.objects.link(o)
    bpy.context.view_layer.objects.active = o
    o.select_set(True)
    bpy.ops.object.convert(target="MESH")
    o = bpy.context.object
    o.data.materials.append(m)
    for pl in o.data.polygons:
        pl.use_smooth = True
    o.select_set(False)
    return o

def extras():
    cable = mat("cable", (0.012, 0.012, 0.012), rough=0.55)
    # 機材の裏からミキサーへ、台の奥から下へ垂れるケーブル
    for x in (-0.34, 0.34):
        curve_tube(f"cable_{'A' if x < 0 else 'B'}", [(x, 0.2, 0.03), (x * 0.6, 0.27, 0.004), (x * 0.25, 0.25, 0.004), (x * 0.1, 0.205, 0.04)], 0.003, cable)
        curve_tube(f"power_{'A' if x < 0 else 'B'}", [(x + 0.1, 0.2, 0.02), (x + 0.12, 0.3, 0.004), (x + 0.1, 0.33, -0.05), (x + 0.1, 0.34, -0.4)], 0.0035, cable)
    curve_tube("cable_mix", [(0.02, 0.205, 0.05), (0.05, 0.28, 0.004), (0.1, 0.33, -0.05), (0.12, 0.34, -0.5)], 0.0035, cable)
    # ヘッドホン（手前右に置いてある）
    hp = empty("headphones", (0.6, -0.3, 0.0))
    hp.rotation_euler.z = math.radians(-25)
    pad = mat("hp_pad", (0.02, 0.02, 0.022), rough=0.8)
    shell = mat("hp_shell", (0.03, 0.03, 0.033), metal=0.4, rough=0.35)
    for sx in (-0.085, 0.085):
        c = cyl("hp_cup", 0.045, 0.03, (sx, 0, 0.022), shell, verts=48, parent=hp, rot=(0, math.radians(90 if sx < 0 else -90) * 0 + 0, 0))
        c.rotation_euler = (0, 0, 0)
        cyl("hp_cushion", 0.043, 0.014, (sx, 0, 0.007), pad, verts=48, parent=hp)
        cyl("hp_logo", 0.02, 0.002, (sx, 0, 0.0375), mat("brushed_alu", (0.72, 0.73, 0.75), metal=1.0, rough=0.28), verts=32, parent=hp)
    curve_tube("hp_band", [(-0.085, 0.0, 0.03), (-0.07, 0.07, 0.035), (0.0, 0.1, 0.038), (0.07, 0.07, 0.035), (0.085, 0.0, 0.03)], 0.007, shell).parent = hp
    curve_tube("hp_cord", [(0.6 + 0.08, -0.32, 0.01), (0.7, -0.26, 0.004), (0.66, -0.12, 0.004), (0.58, -0.02, 0.004), (0.45, 0.12, 0.004)], 0.0022, cable)
    # 飲み物のカップ（奥の左）
    cup = mat("cup_plastic", (0.6, 0.05, 0.05), rough=0.25)
    bpy.ops.mesh.primitive_cone_add(vertices=40, radius1=0.032, radius2=0.044, depth=0.115, location=(-0.66, 0.2, 0.0575))
    c = bpy.context.object; c.name = "cup"; assign(c, cup)
    bpy.ops.mesh.primitive_cylinder_add(vertices=40, radius=0.041, depth=0.002, location=(-0.66, 0.2, 0.09))
    l = bpy.context.object; l.name = "cup_drink"; assign(l, mat("drink", (0.35, 0.18, 0.03), rough=0.05))
    # グースネックのランプ（ミキサーの奥）
    lampm = mat("lamp_metal", (0.05, 0.05, 0.055), metal=0.8, rough=0.3)
    curve_tube("lamp_neck", [(0.11, 0.2, 0.09), (0.11, 0.2, 0.22), (0.07, 0.12, 0.3), (0.03, 0.05, 0.27)], 0.004, lampm)
    head = cyl("lamp_head", 0.014, 0.03, (0.03, 0.05, 0.26), lampm, verts=24)
    head.rotation_euler.x = math.radians(35)
    cyl("lamp_bulb", 0.011, 0.002, (0, 0, -0.016), mat("lamp_bulb", (1, 0.95, 0.85), emit=(1, 0.9, 0.75), emit_strength=8), verts=24, parent=head)
    # フライトケース風のブース：アルミの縁と角金具
    alu = mat("brushed_alu", (0.72, 0.73, 0.75), metal=1.0, rough=0.28)
    for z in (-0.005, -1.0):
        box("case_edge", (1.71, 0.02, 0.022), (0, 0.365, z), alu, bev=0.002)
    for x in (-0.855, 0.855):
        box("case_edge_v", (0.022, 0.02, 1.0), (x, 0.365, -0.5), alu, bev=0.002)
        for z in (-0.02, -0.985):
            bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=8, radius=0.018, location=(x, 0.372, z))
            ball = bpy.context.object; ball.name = "case_corner"; assign(ball, mat("chrome", (0.9, 0.9, 0.92), metal=1.0, rough=0.12))
    box("case_edge_top", (1.71, 0.75, 0.012), (0, -0.05, -0.046), alu, bev=0.002)

def deck(side, x):
    root = empty(f"deck_{side}", (x, 0, 0))
    W, D, H = 0.33, 0.42, 0.075
    box(f"deck_{side}_body", (W, D, H), (0, 0, H / 2), M_BODY(), bev=0.008, parent=root)
    box(f"deck_{side}_top", (W - 0.012, D - 0.012, 0.002), (0, 0, H + 0.001), M_PANEL(), bev=0.001, parent=root)
    top = H + 0.002
    print_plane(f"print_{side}", W - 0.014, D - 0.014, H + 0.0021, root, f"deck_{side}_print.png")
    jy = -0.048
    # ジョグ：金属リング・ゴムの側面・上面の盤（ジャケットを貼る）
    cyl(f"jogring_{side}", 0.106, 0.012, (0, jy, top + 0.006), M_ALU(), verts=96, parent=root)
    cyl(f"jogside_{side}", 0.099, 0.018, (0, jy, top + 0.012), M_RUBBER(), verts=96, parent=root)
    p = cyl(f"platter_{side}", 0.093, 0.004, (0, jy, top + 0.022), M_LABEL(), verts=96, bev=0.0008, parent=root)
    # 盤の UV を円形に（上面だけ使う）
    bm = bmesh.new(); bm.from_mesh(p.data)
    uv = bm.loops.layers.uv.new("UVMap") if not bm.loops.layers.uv else bm.loops.layers.uv[0]
    for f in bm.faces:
        for l in f.loops:
            v = l.vert.co
            l[uv].uv = (0.5 + v.x / 0.186, 0.5 + v.y / 0.186)
    bm.to_mesh(p.data); bm.free()
    cyl(f"jogcenter_{side}", 0.022, 0.006, (0, 0, 0.004), M_CHROME(), parent=p)
    cyl(f"jogrim_{side}", 0.1, 0.004, (0, jy, top + 0.0215), M_CHROME(), verts=96, parent=root)
    # ゴムのすべり止めの溝
    for k in range(72):
        a = k / 72 * math.tau
        g = box(f"jogrib_{side}_{k}", (0.003, 0.003, 0.01), (math.cos(a) * 0.0985, jy + math.sin(a) * 0.0985, top + 0.012),
                M_RUBBER(), bev=0, parent=root)
        g.rotation_euler.z = a
    # 画面
    s = box(f"screen_{side}", (0.13, 0.075, 0.003), (0, 0.15, top + 0.012), M_GLASS(), bev=0.001, parent=root)
    s.rotation_euler.x = math.radians(-12)
    box(f"screenbezel_{side}", (0.142, 0.087, 0.012), (0, 0.152, top + 0.005), M_PANEL(), bev=0.002, parent=root)
    # PLAY / CUE（手前の角）
    sx = -0.12 if side == "A" else 0.12
    for i, nm in enumerate(["cue", "play"]):
        cyl(f"{nm}_{side}", 0.018, 0.008, (sx, -0.155 + i * 0.045, top + 0.004),
            mat(f"{nm}_led", (0.05, 0.05, 0.05), rough=0.3, emit=(1, 0.45, 0.05) if nm == "cue" else (0.1, 1, 0.2), emit_strength=0.0),
            verts=32, parent=root)
        cyl(f"{nm}_{side}_ring", 0.021, 0.004, (sx, -0.155 + i * 0.045, top + 0.002), M_ALU(), verts=32, parent=root)
    # パッド 8個
    for i in range(8):
        px = -0.09 + (i % 4) * 0.06
        py = 0.08 + (i // 4) * -0.03 - 0.03
        box(f"pad_{side}_{i}", (0.045, 0.022, 0.006), (px * 0.8 + (0.03 if side == "A" else -0.03), 0.095 - (i // 4) * 0.027, top + 0.003),
            mat(f"pad_rubber", (0.04, 0.04, 0.045), rough=0.7), bev=0.002, parent=root)
    lx = 0.07 if side == "A" else -0.07
    for k in range(3):
        box(f"loop_{side}_{k}", (0.02, 0.009, 0.004), (lx + (k - 1) * 0.027 * (1 if side == "A" else -1), -0.19, top + 0.002),
            mat("pad_rubber", (0.04, 0.04, 0.045), rough=0.7), bev=0.0015, parent=root)
    # テンポスライダー（飾り。アプリでは動かさない）
    tx = 0.14 if side == "A" else -0.14
    box(f"tempo_slot_{side}", (0.006, 0.17, 0.002), (tx, -0.04, top + 0.001), mat("slot", (0, 0, 0), rough=0.9), bev=0, parent=root)
    box(f"tempo_cap_{side}", (0.026, 0.014, 0.012), (tx, -0.04, top + 0.006), M_CAP(), bev=0.002, parent=root)
    # ブラウズのつまみ
    cyl(f"browse_{side}", 0.012, 0.016, (-tx * 0.15 + (0.1 if side == "A" else -0.1), 0.15, top + 0.008), M_KNOB(), verts=32, parent=root)
    return root

def mixer():
    root = empty("mixer", (0, 0, 0))
    W, D, H = 0.27, 0.42, 0.09
    box("mixer_body", (W, D, H), (0, 0, H / 2), M_BODY(), bev=0.008, parent=root)
    box("mixer_top", (W - 0.012, D - 0.012, 0.002), (0, 0, H + 0.001), M_PANEL(), bev=0.001, parent=root)
    top = H + 0.002
    print_plane("print_mixer", W - 0.014, D - 0.014, H + 0.0021, root, "mixer_print.png")
    chx = [-0.055, 0.055]
    ys = [0.17, 0.125, 0.08, 0.035, -0.015]
    for c, x in enumerate(chx):
        for i, y in enumerate(ys):
            k = cyl(f"knob_{c}_{i}", 0.0125 if i < 4 else 0.015, 0.018, (x, y, top + 0.009),
                    M_KNOB() if i < 4 else mat("filter_knob", (0.25, 0.02, 0.06) if c == 0 else (0.02, 0.15, 0.25), rough=0.4), verts=32, parent=root)
            box(f"knob_{c}_{i}_mark", (0.0018, 0.008, 0.001), (0, 0.006, 0.0095), M_WHITE(), bev=0, parent=k)
        cyl(f"chcue_{c}", 0.0075, 0.005, (x + (-0.03 if c == 0 else 0.03), -0.04, top + 0.0025),
            mat("chcue", (0.06, 0.06, 0.065), rough=0.4, emit=(1, 0.5, 0.1), emit_strength=0), verts=24, parent=root)
        box(f"fader_slot_{c}", (0.004, 0.09, 0.002), (x, -0.095, top + 0.001), mat("slot", (0, 0, 0), rough=0.9), bev=0, parent=root)
        box(f"fader_{c}", (0.03, 0.013, 0.014), (x, -0.06, top + 0.007), M_CAP(), bev=0.002, parent=root)
    box("xfader_slot", (0.1, 0.004, 0.002), (0, -0.185, top + 0.001), mat("slot", (0, 0, 0), rough=0.9), bev=0, parent=root)
    box("xfader", (0.013, 0.028, 0.014), (-0.035, -0.185, top + 0.007), M_CAP(), bev=0.002, parent=root)
    # CROWD ENERGY の LED（アプリで光らせる。音の測定ではない）
    for c in range(2):
        for i in range(12):
            box(f"meter_{c}_{i}", (0.007, 0.006, 0.002), (-0.007 + c * 0.014, -0.11 + i * 0.011, top + 0.001),
                mat("meter_led", (0.02, 0.02, 0.02), rough=0.3, emit=(0.2, 1, 0.2), emit_strength=0.0), bev=0, parent=root)
    cyl("master_knob", 0.014, 0.018, (0, 0.17, top + 0.009), M_KNOB(), verts=32, parent=root)
    return root

def booth():
    root = empty("booth", (0, 0, 0))
    bt = box("booth_top", (1.7, 0.75, 0.04), (0, -0.05, -0.02), M_WOOD(), bev=0.004, parent=root)
    print_plane("booth_top_print", 1.69, 0.74, 0.0006, root, "booth_top_tex.png").location.y = -0.05
    box("booth_facade", (1.7, 0.04, 1.0), (0, 0.35, -0.52), M_FACADE(), bev=0.004, parent=root)
    box("booth_led", (1.68, 0.006, 0.012), (0, 0.373, -0.06), mat("booth_led", (0.02, 0.02, 0.02), emit=(1, 0.1, 0.6), emit_strength=6), bev=0, parent=root)
    # 横のモニタースピーカー
    for sx in (-0.78, 0.78):
        sp = box(f"monitor_{'L' if sx < 0 else 'R'}", (0.2, 0.22, 0.32), (sx, 0.12, 0.16), mat("speaker_cab", (0.02, 0.02, 0.022), rough=0.7), bev=0.01, parent=root)
        sp.rotation_euler.z = math.radians(18 if sx < 0 else -18)
        cyl(f"woofer_ring_{'L' if sx < 0 else 'R'}", 0.08, 0.008, (0, -0.111, -0.03), mat("woofer_ring", (0.12, 0.12, 0.13), metal=0.6, rough=0.35),
            verts=48, parent=sp, rot=(math.radians(90), 0, 0))
        cyl(f"woofer_{'L' if sx < 0 else 'R'}", 0.068, 0.01, (0, -0.113, -0.03), mat("woofer", (0.035, 0.035, 0.037), rough=0.75),
            verts=48, parent=sp, rot=(math.radians(90), 0, 0))
        cyl(f"tweeter_{'L' if sx < 0 else 'R'}", 0.02, 0.01, (0, -0.112, 0.1), M_ALU(), verts=32, parent=sp, rot=(math.radians(90), 0, 0))
    return root

def build():
    clear()
    booth()
    deck("A", -0.34)
    deck("B", 0.34)
    mixer()
    extras()

def preview(path):
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.samples = 48
    sc.cycles.device = "CPU"
    sc.render.resolution_x, sc.render.resolution_y = 1400, 800
    w = bpy.data.worlds.new("w"); sc.world = w; w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.03, 0.02, 0.05, 1)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    sc.collection.objects.link(cam); sc.camera = cam
    cam.data.lens = 22
    cam.location = (0, -1.05, 0.8)
    cam.rotation_euler = (Vector((0, -0.05, 0)) - cam.location).to_track_quat('-Z', 'Y').to_euler()
    for loc, e, c in [((0, -0.5, 1.4), 120, (1, 1, 1)), ((0, 1.6, 0.9), 120, (1, 0.2, 0.7)), ((-1, 0.3, 0.6), 40, (0.3, 0.6, 1))]:
        L = bpy.data.objects.new("l", bpy.data.lights.new("l", "AREA")); L.data.energy = e; L.data.color = c; L.data.size = 1.0
        L.location = loc; L.rotation_euler = (Vector((0, 0, 0)) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
        sc.collection.objects.link(L)
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)

def export_dae(path):
    # SceneKit 用。Y 上・-Z 前（Blender の +Y＝観客側が SceneKit の -Z になる）
    bpy.ops.object.select_all(action="SELECT")
    for o in bpy.context.selected_objects:
        if o.type == "MESH":
            o.modifiers.new("tri", "TRIANGULATE")
    bpy.ops.wm.collada_export(filepath=path, selected=True, apply_modifiers=True, triangulate=True,
                              export_global_forward_selection="-Z", export_global_up_selection="Y",
                              apply_global_orientation=True, use_object_instantiation=False,
                              use_texture_copies=True)

if __name__ == "__main__":
    build()
    if "--export" in sys.argv:
        export_dae(sys.argv[sys.argv.index("--export") + 1])
        sys.exit(0)
    here = os.path.dirname(os.path.abspath(__file__))
    preview(os.path.join(here, "..", "out", "gear_preview.png"))
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(here, "..", "out", "gear.blend"))
