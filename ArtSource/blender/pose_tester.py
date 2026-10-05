import sys, os, bpy, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mh_common as mh, importlib
import poses; importlib.reload(poses)
mh.clear(); mh.ensure_pack()
names = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else list(poses.POSES)
for i, nm in enumerate(names):
    b = mh.make_human(f"p{i}", {"gender": 1.0}, "young_caucasian_male", ["male_casualsuit02"], hair="", eyebrows="", proxy="male_generic")
    rig = b.parent
    rig.location.x = (i - (len(names) - 1) / 2) * 1.0
    for bone, e in poses.POSES[nm].items():
        pb = rig.pose.bones["mixamorig:" + bone]
        pb.rotation_mode = "XYZ"
        pb.rotation_euler = [math.radians(a) for a in e]
mh.preview(os.path.join(mh.ROOT, "out", "poses.png"), target=(0, 0, 1.0), dist=1.0 + len(names) * 1.05, height=1.3, res=(260 * len(names), 560))
