# DJ の前腕と手だけを書き出す（フル解像度の MakeHuman ボディ＋長袖シャツ、Mixamo 互換リグ）
import sys, os, bpy, bmesh
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mh_common as mh
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "export_crowd.py"), encoding="utf-8").read().split("def export_one")[0].split("from crowd_variants import VARIANTS")[1])

OUT = os.path.join(mh.ROOT, "..", "B2BCrowd", "Resources", "Booth.scnassets")
DJS = [
    dict(name="arms_a", ph=dict(gender=0.0, age=0.42, muscle=0.5, weight=0.45, race=dict(asian=1, caucasian=0, african=0)),
         skin="young_asian_female", clothes=["female_elegantsuit01"]),
    dict(name="arms_b", ph=dict(gender=1.0, age=0.45, muscle=0.6, weight=0.5, race=dict(asian=0, caucasian=0.3, african=0.7)),
         skin="young_african_male", clothes=["male_casualsuit01"]),
]
KEEP = ("Arm", "Hand")   # 上腕・前腕・手（肩より先）

def keep_arm_only(o):
    names = {g.index: g.name for g in o.vertex_groups}
    bm = bmesh.new(); bm.from_mesh(o.data)
    dl = bm.verts.layers.deform.active
    kill = []
    for v in bm.verts:
        w_keep = 0.0
        w_all = 0.0
        if dl:
            for gi, w in v[dl].items():
                n = names.get(gi, "")
                if n.startswith("mixamorig"):
                    w_all += w
                    if any(k in n for k in KEEP):
                        w_keep += w
        if w_all == 0 or w_keep / w_all < 0.5:
            kill.append(v)
    bmesh.ops.delete(bm, geom=kill, context="VERTS")
    bm.to_mesh(o.data); bm.free()
    return len(o.data.polygons)

for dj in DJS:
    mh.clear(); mh.ensure_pack()
    body = mh.make_human(dj["name"], dj["ph"], dj["skin"], dj["clothes"], hair="", eyebrows="", subdiv=0)
    rig = body.parent
    for o in list(bpy.data.objects):
        if o.type != "MESH":
            continue
        if not (o == body or any(c in o.name for c in dj["clothes"])):
            bpy.data.objects.remove(o, do_unlink=True)
            continue
        for md in list(o.modifiers):
            if md.type in ("MASK", "SUBSURF"):
                o.modifiers.remove(md)
        n = keep_arm_only(o)
        print("ARM", o.name, n)
        simplify_materials(o)
        o.modifiers.new("tri", "TRIANGULATE")
    rig.name = "rig"
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.wm.collada_export(filepath=os.path.join(OUT, dj["name"] + ".dae"), selected=True, apply_modifiers=True,
                              triangulate=True, include_armatures=True, deform_bones_only=True,
                              use_texture_copies=True, export_global_forward_selection="-Z",
                              export_global_up_selection="Y", apply_global_orientation=True,
                              include_animations=False)
