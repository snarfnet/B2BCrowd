import sys, os, bpy
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mh_common as mh
from crowd_variants import VARIANTS
mh.clear(); mh.ensure_pack()
VS = VARIANTS[10:] if "--new" in sys.argv else VARIANTS
for i, v in enumerate(VS):
    proxy = "male_generic" if v["ph"]["gender"] > 0.5 else "female_generic"
    b = mh.make_human(v["name"], v["ph"], v["skin"], v["clothes"], hair=v["hair"], proxy=proxy)
    rig = b.parent if b.parent else b
    rig.location.x = (i - (len(VS) - 1) / 2) * 0.75
tot = 0
for o in bpy.data.objects:
    if o.type == "MESH" and o.name.startswith("c01"):
        print("POLY", o.name, len(o.data.polygons))
mh.preview(os.path.join(mh.ROOT, "out", "lineup.png"), target=(0, 0, 0.9), dist=7.5, height=1.4, res=(1800, 700))
