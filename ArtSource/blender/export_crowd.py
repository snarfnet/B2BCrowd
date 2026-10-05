# 観客10人を Mixamo 互換リグ付きで DAE に書き出す（アニメは別ファイル）
import sys, os, bpy
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mh_common as mh
from crowd_variants import VARIANTS

OUT = os.path.join(mh.ROOT, "..", "B2BCrowd", "Resources", "Crowd.scnassets")
only = sys.argv[sys.argv.index("--only") + 1].split(",") if "--only" in sys.argv else None

def simplify_materials(o):
    # MakeHuman のノード群を「画像→Principled」に置き換える（Collada が拾えるように）
    for slot in o.material_slots:
        m = slot.material
        if not m or not m.use_nodes:
            continue
        imgs = [n.image for n in m.node_tree.nodes if n.type == "TEX_IMAGE" and n.image]
        for n in m.node_tree.nodes:
            if n.type == "GROUP" and n.node_tree:
                imgs += [k.image for k in n.node_tree.nodes if k.type == "TEX_IMAGE" and k.image]
        def score(im):
            nm = im.name.lower()
            if "normal" in nm or "_ao" in nm or "bump" in nm or "spec" in nm or "rough" in nm:
                return -1
            return 2 if "diffuse" in nm or "albedo" in nm or "color" in nm else 1
        imgs = sorted(set(imgs), key=score, reverse=True)
        diffuse = imgs[0] if imgs and score(imgs[0]) >= 0 else None
        nt = m.node_tree
        nt.nodes.clear()
        out = nt.nodes.new("ShaderNodeOutputMaterial")
        b = nt.nodes.new("ShaderNodeBsdfPrincipled")
        nt.links.new(b.outputs[0], out.inputs[0])
        if diffuse:
            t = nt.nodes.new("ShaderNodeTexImage")
            t.image = diffuse
            nt.links.new(t.outputs["Color"], b.inputs["Base Color"])
            if any(k in o.name for k in ("hair", "bob", "afro", "ponytail", "long", "short", "braid", "eyebrow", "eyelash", "fedora")):
                nt.links.new(t.outputs["Alpha"], b.inputs["Alpha"])
        print("MAT", o.name, m.name, diffuse.name if diffuse else None)

LOD = "--lod" in sys.argv

def export_one(v):
    mh.clear(); mh.ensure_pack()
    proxy = "male_generic" if v["ph"]["gender"] > 0.5 else "female_generic"
    body = mh.make_human(v["name"], v["ph"], v["skin"], v["clothes"], hair=v["hair"], proxy=proxy)
    rig = body.parent
    # 本体メッシュはプロキシに置き換わっているので消す（目・まつげ・眉は残す）
    keep = []
    for o in list(bpy.data.objects):
        if o == body:
            bpy.data.objects.remove(o, do_unlink=True)
            continue
        if o.type == "MESH":
            if LOD and not any(k in o.name for k in ("low-poly", "eyebrow", "eyelash")):
                dm = o.modifiers.new("lod", "DECIMATE")
                dm.ratio = 0.22 if "generic" in o.name else 0.35
            o.modifiers.new("tri", "TRIANGULATE")
            for md in o.modifiers:
                if md.type == "SUBSURF":
                    md.levels = 0
            keep.append(o)
            simplify_materials(o)
    for o in keep:
        arm = [m for m in o.modifiers if m.type == "ARMATURE"]
        print("MESH", o.name, len(o.data.polygons), "armature" if arm else "NO ARMATURE", [m.type for m in o.modifiers])
    rig.name = "rig"
    d = os.path.join(OUT, v["name"])
    os.makedirs(d, exist_ok=True)
    fname = v["name"] + ("_lod" if LOD else "")
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.wm.collada_export(filepath=os.path.join(d, fname + ".dae"), selected=True, apply_modifiers=True,
                              triangulate=True, include_armatures=True, deform_bones_only=True,
                              use_texture_copies=True, export_global_forward_selection="-Z",
                              export_global_up_selection="Y", apply_global_orientation=True,
                              include_animations=False)

for v in VARIANTS:
    if only and v["name"] not in only:
        continue
    export_one(v)
