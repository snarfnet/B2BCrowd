import sys, os, bpy, math
from mathutils import Quaternion, Euler
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mh_common as mh
mh.clear(); mh.ensure_pack()
tests = [("LeftArm", "X", 60), ("LeftArm", "Z", 60), ("LeftForeArm", "X", 60), ("LeftForeArm", "Z", 60), ("Spine1", "X", 30), ("Head", "X", 30)]
for i, (bone, ax, deg) in enumerate(tests):
    b = mh.make_human(f"t{i}", {"gender": 1.0}, "young_caucasian_male", ["male_casualsuit02"], hair="", eyebrows="", proxy="male_generic")
    rig = b.parent
    rig.location.x = (i - 2.5) * 1.1
    pb = rig.pose.bones["mixamorig:" + bone]
    pb.rotation_mode = "XYZ"
    e = [0, 0, 0]; e["XYZ".index(ax)] = math.radians(deg)
    pb.rotation_euler = e
    print("REST", bone, [round(v, 2) for v in (rig.data.bones["mixamorig:" + bone].matrix_local.to_3x3() @ __import__('mathutils').Vector((0, 1, 0)))])
mh.preview(os.path.join(mh.ROOT, "out", "axis_test.png"), target=(0, 0, 1.0), dist=6.5, height=1.3, res=(1800, 700))
