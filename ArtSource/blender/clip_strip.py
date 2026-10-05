import sys, os, bpy, json
from mathutils import Quaternion, Vector
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mh_common as mh
import clips as C
data = json.load(open("C:/Users/Windows/B2BCrowd/B2BCrowd/Resources/crowd_clips.json"))
mh.clear(); mh.ensure_pack()
body = mh.make_human("ref", {"gender": 0.5}, "young_caucasian_male", ["male_casualsuit02"], hair="", eyebrows="", proxy="male_generic")
rig = body.parent
names = sys.argv[sys.argv.index("--") + 1:]
for name in names:
    c = data["clips"][name]
    n = c["frames"]
    for k in range(8):
        f = int(n * k / 8)
        for b, arr in c["bones"].items():
            pb = rig.pose.bones[b]
            pb.rotation_mode = "QUATERNION"
            x, y, z, w = arr[f * 4:f * 4 + 4]
            pb.rotation_quaternion = Quaternion((w, x, y, z))
        h = c["hips"][f * 3:f * 3 + 3]
        C.mh_preview_pose(rig, f"C:/Users/Windows/B2BCrowd/ArtSource/out/clips/strip_{name}_{k}.png", tuple(h))
