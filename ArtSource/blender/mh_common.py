# MPFB (MakeHuman) で人を作る共通処理。Blender 4.4 + MPFB 2.0.17 + makehuman_system_assets_cc0。
import bpy, os, zipfile, math, sys
from bl_ext.user_default.mpfb.services.locationservice import LocationService
from bl_ext.user_default.mpfb.services.humanservice import HumanService
from bl_ext.user_default.mpfb.services.assetservice import AssetService

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
PACK = os.path.join(ROOT, "dl", "mh_assets_cc0.zip")

def ensure_pack():
    data = LocationService.get_user_data()
    if not os.path.exists(os.path.join(data, "skins", "young_asian_female")):
        with zipfile.ZipFile(PACK) as z:
            z.extractall(data)
        AssetService.update_all_asset_lists()
    return data

def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)

def make_human(name, phenotype, skin, clothes, hair="", eyebrows="eyebrow001", rig="mixamo", proxy="", subdiv=0):
    info = HumanService._create_default_human_info_dict()
    ph = info["phenotype"]
    for k, v in phenotype.items():
        ph[k] = v
    info["name"] = name
    info["rig"] = rig
    info["eyes"] = "low-poly/low-poly.mhclo"
    info["eyebrows"] = f"{eyebrows}/{eyebrows}.mhclo" if eyebrows else ""
    info["eyelashes"] = "eyelashes01/eyelashes01.mhclo"
    info["hair"] = f"{hair}/{hair}.mhclo" if hair else ""
    info["proxy"] = f"{proxy}/{proxy}.proxy" if proxy else ""
    info["clothes"] = [f"{c}/{c}.mhclo" for c in clothes]
    info["skin_mhmat"] = f"skins/{skin}/{skin}.mhmat"
    info["skin_material_type"] = "GAMEENGINE"
    info["eyes_material_type"] = "MAKESKIN"
    info["clothes_material_type"] = "MAKESKIN"
    s = HumanService.get_default_deserialization_settings()
    s["subdiv_levels"] = subdiv
    return HumanService.deserialize_from_dict(info, s)

def preview(path, target=(0, 0, 0.9), dist=2.6, height=1.2, res=(700, 900)):
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_EEVEE_NEXT"
    sc.render.resolution_x, sc.render.resolution_y = res
    w = bpy.data.worlds.new("w"); sc.world = w; w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.25, 0.25, 0.28, 1)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    sc.collection.objects.link(cam); sc.camera = cam
    cam.location = (0, -dist, height)
    d = cam.location
    import mathutils
    v = mathutils.Vector(target) - d
    cam.rotation_euler = v.to_track_quat('-Z', 'Y').to_euler()
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 3; sun.rotation_euler = (0.8, 0.2, 0.4)
    sc.collection.objects.link(sun)
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
