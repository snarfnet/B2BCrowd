# キャラ選択の顔写真（上半身、正面やや斜め）
import sys, os, bpy
from mathutils import Vector
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mh_common as mh
from crowd_variants import VARIANTS
import robots
OUT = os.path.join(mh.ROOT, "..", "B2BCrowd", "Resources", "Characters")
os.makedirs(OUT, exist_ok=True)
HUMANS = [n for n in ["c07", "c13", "c16"] if n in sys.argv] or ["c09", "c02", "c12", "c16", "c05", "c07", "c13"]

def shoot(path, head_z):
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_EEVEE_NEXT"
    sc.render.resolution_x = sc.render.resolution_y = 512
    w = bpy.data.worlds.new("w"); sc.world = w; w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.03, 0.02, 0.05, 1)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam")); sc.collection.objects.link(cam); sc.camera = cam
    cam.data.lens = 70
    cam.location = (0.45, -1.7, head_z - 0.05)
    cam.rotation_euler = (Vector((0, 0, head_z - 0.18)) - cam.location).to_track_quat('-Z', 'Y').to_euler()
    for loc, e, c in [((1.2, -1.5, head_z + 1.0), 250, (1, 0.95, 0.9)), ((-1.5, 0.8, head_z + 0.3), 260, (1, 0.2, 0.6)),
                      ((1.4, 1.0, head_z + 0.2), 220, (0.2, 0.7, 1))]:
        L = bpy.data.objects.new("l", bpy.data.lights.new("l", "AREA")); L.data.energy = e; L.data.color = c; L.data.size = 1.2
        L.location = loc; L.rotation_euler = (Vector((0, 0, head_z - 0.2)) - Vector(loc)).to_track_quat('-Z', 'Y').to_euler()
        sc.collection.objects.link(L)
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)

def head_height():
    rig = [o for o in bpy.data.objects if o.type == "ARMATURE"][0]
    return (rig.matrix_world @ rig.data.bones["mixamorig:Head"].head_local).z + 0.08

for name in HUMANS:
    v = [x for x in VARIANTS if x["name"] == name][0]
    mh.clear(); mh.ensure_pack()
    proxy = "male_generic" if v["ph"]["gender"] > 0.5 else "female_generic"
    mh.make_human(name, v["ph"], v["skin"], v["clothes"], hair=v["hair"], proxy=proxy, subdiv=1)
    shoot(os.path.join(OUT, f"char_{name}.png"), head_height())
for name, st in ([] if "--humans" in sys.argv else robots.STYLES.items()):
    robots.MATS.clear()
    robots.build(name, st)
    shoot(os.path.join(OUT, f"char_{name}.png"), head_height())
print("done")
