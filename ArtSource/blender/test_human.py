import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mh_common as mh
mh.clear()
print("DATA", mh.ensure_pack())
b = mh.make_human("test", {"gender": 0.0, "age": 0.4, "race": {"asian": 1.0, "caucasian": 0.0, "african": 0.0}},
                  "young_asian_female", ["female_casualsuit01", "shoes02"], hair="bob01")
import bpy
for o in bpy.data.objects: print("OBJ", o.name, o.type, len(o.data.polygons) if o.type == "MESH" else "")
mh.preview(os.path.join(mh.ROOT, "out", "test_human.png"))
