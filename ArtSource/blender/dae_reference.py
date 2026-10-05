"""Read the project's exported Collada rig for offline pose generation/QA.

Blender 5 removed the built-in Collada importer. This small reader supports
the matrix/triangles/skin subset emitted by export_crowd.py, without plugins.
It does not change or re-export the character assets.
"""
from pathlib import Path
import xml.etree.ElementTree as ET
import bpy
from mathutils import Matrix, Vector

NS = {"c": "http://www.collada.org/2005/11/COLLADASchema"}
TO_BLENDER = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))


def matrix(node):
    text = node.findtext("c:matrix", namespaces=NS)
    vals = list(map(float, text.split())) if text else []
    return Matrix([vals[i:i + 4] for i in range(0, 16, 4)]) if vals else Matrix.Identity(4)


def load_rig(path, meshes=False):
    path = Path(path)
    doc = ET.parse(path).getroot()
    joints, aliases = {}, {}

    def walk(node, parent_world, parent_joint=None):
        world = parent_world @ matrix(node)
        parent = parent_joint
        if node.get("type") == "JOINT":
            name = node.get("name")
            joints[name] = (TO_BLENDER @ world, parent_joint)
            aliases[node.get("sid")] = name
            parent = name
        for child in node.findall("c:node", NS):
            walk(child, world, parent)

    for n in doc.findall("c:library_visual_scenes/c:visual_scene/c:node", NS):
        walk(n, Matrix.Identity(4))
    if not joints:
        raise ValueError("No joints in " + str(path))
    data = bpy.data.armatures.new("reference")
    rig = bpy.data.objects.new("reference", data)
    bpy.context.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    rig.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    for name, (world, _) in joints.items():
        bone = data.edit_bones.new(name)
        bone.head = world.translation
        bone.tail = bone.head + world.to_3x3().col[1].normalized() * 0.1
        bone.matrix = world
        bone.length = 0.1
    for name, (_, parent) in joints.items():
        if parent:
            data.edit_bones[name].parent = data.edit_bones[parent]
    bpy.ops.object.mode_set(mode="OBJECT")
    rig.select_set(False)
    if meshes:
        attach_meshes(doc, path, rig, aliases)
    return rig


def source_arrays(element):
    out = {}
    for source in element.findall("c:source", NS):
        accessor = source.find("c:technique_common/c:accessor", NS)
        stride = int(accessor.get("stride", "1"))
        arr = source.find("c:float_array", NS)
        if arr is not None:
            values = list(map(float, arr.text.split()))
            out[source.get("id")] = [values[i:i + stride] for i in range(0, len(values), stride)]
        else:
            arr = source.find("c:Name_array", NS)
            if arr is not None:
                out[source.get("id")] = arr.text.split()
    return out


def attach_meshes(doc, path, rig, aliases):
    images = {n.get("id"): n.findtext("c:init_from", namespaces=NS)
              for n in doc.findall("c:library_images/c:image", NS)}
    effects = {n.get("id"): n for n in doc.findall("c:library_effects/c:effect", NS)}
    mats = {}
    for n in doc.findall("c:library_materials/c:material", NS):
        mat = bpy.data.materials.new(n.get("name", n.get("id")))
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes.get("Principled BSDF")
        bsdf.inputs["Roughness"].default_value = 0.55 if ".body" in mat.name else 0.78
        effect = effects[n.find("c:instance_effect", NS).get("url")[1:]]
        params = {p.get("sid"): p for p in effect.findall("c:profile_COMMON/c:newparam", NS)}
        tex = effect.find(".//c:diffuse/c:texture", NS)
        if tex is not None:
            sampler = params[tex.get("texture")].findtext("c:sampler2D/c:source", namespaces=NS)
            image_id = params[sampler].findtext("c:surface/c:init_from", namespaces=NS)
            filename = path.parent / images[image_id]
            image = bpy.data.images.load(str(filename), check_existing=True)
            node = mat.node_tree.nodes.new("ShaderNodeTexImage")
            node.image = image
            mat.node_tree.links.new(node.outputs["Color"], bsdf.inputs["Base Color"])
            if any(k in mat.name for k in ("short", "bob", "eyebrow", "eyelash", "ponytail", "long", "afro")):
                mat.node_tree.links.new(node.outputs["Alpha"], bsdf.inputs["Alpha"])
        else:
            color = effect.findtext(".//c:diffuse/c:color", namespaces=NS)
            if color:
                bsdf.inputs["Base Color"].default_value = list(map(float, color.split()))
        mats[n.get("id")] = mat

    geometries = {n.get("id"): n.find("c:mesh", NS) for n in doc.findall("c:library_geometries/c:geometry", NS)}
    for controller in doc.findall("c:library_controllers/c:controller", NS):
        skin = controller.find("c:skin", NS)
        geom = geometries[skin.get("source")[1:]]
        arrays = source_arrays(geom)
        vertices = geom.find("c:vertices/c:input[@semantic='POSITION']", NS).get("source")[1:]
        xyz = arrays[vertices]
        shape = list(map(float, skin.findtext("c:bind_shape_matrix", namespaces=NS).split()))
        shape = TO_BLENDER @ Matrix([shape[i:i + 4] for i in range(0, 16, 4)])
        coords = [shape @ Vector(v[:3]) for v in xyz]
        faces, uvcoords, material_ids = [], [], []
        slots = []
        for tris in geom.findall("c:triangles", NS):
            inputs = {x.get("semantic"): (int(x.get("offset")), x.get("source")[1:]) for x in tris.findall("c:input", NS)}
            stride = max(x[0] for x in inputs.values()) + 1
            raw = list(map(int, tris.findtext("c:p", namespaces=NS).split()))
            idx = [raw[i:i + stride] for i in range(0, len(raw), stride)]
            symbol = tris.get("material")
            if symbol not in slots:
                slots.append(symbol)
            for i in range(0, len(idx), 3):
                faces.append([x[inputs["VERTEX"][0]] for x in idx[i:i + 3]])
                material_ids.append(slots.index(symbol))
                if "TEXCOORD" in inputs:
                    off, key = inputs["TEXCOORD"]
                    uvcoords.extend([arrays[key][x[off]][:2] for x in idx[i:i + 3]])
                else:
                    uvcoords.extend([(0, 0)] * 3)
        mesh = bpy.data.meshes.new(controller.get("id"))
        mesh.from_pydata(coords, [], faces)
        mesh.update()
        obj = bpy.data.objects.new(mesh.name, mesh)
        bpy.context.collection.objects.link(obj)
        for symbol in slots:
            mesh.materials.append(mats[symbol])
        uv = mesh.uv_layers.new(name="UVMap")
        for i, coord in enumerate(uvcoords):
            uv.data[i].uv = coord
        for poly, mid in zip(mesh.polygons, material_ids):
            poly.material_index = mid
            poly.use_smooth = True
        if rig is None:
            continue
        arrays = source_arrays(skin)
        vw = skin.find("c:vertex_weights", NS)
        inp = {x.get("semantic"): (int(x.get("offset")), x.get("source")[1:]) for x in vw.findall("c:input", NS)}
        bone_names = arrays[inp["JOINT"][1]]
        groups = [obj.vertex_groups.new(name=aliases[name]) for name in bone_names]
        weights = arrays[inp["WEIGHT"][1]]
        counts = list(map(int, vw.findtext("c:vcount", namespaces=NS).split()))
        values = list(map(int, vw.findtext("c:v", namespaces=NS).split()))
        stride = max(x[0] for x in inp.values()) + 1
        cursor = 0
        for vi, count in enumerate(counts):
            for _ in range(count):
                joint = values[cursor + inp["JOINT"][0]]
                weight = values[cursor + inp["WEIGHT"][0]]
                groups[joint].add([vi], weights[weight][0], "REPLACE")
                cursor += stride
        mod = obj.modifiers.new("pose", "ARMATURE")
        mod.object = rig
        obj.parent = rig


def load_static(path):
    """Read matrix-transformed static geometry, e.g. the actual gear.dae."""
    path = Path(path)
    doc = ET.parse(path).getroot()
    ns = '{' + NS['c'] + '}'
    controllers = ET.SubElement(doc, ns + 'library_controllers')

    def walk(node, parent):
        world = parent @ matrix(node)
        for instance in node.findall('c:instance_geometry', NS):
            controller = ET.SubElement(controllers, ns + 'controller', id=node.get('name', node.get('id')))
            skin = ET.SubElement(controller, ns + 'skin', source=instance.get('url'))
            shape = ET.SubElement(skin, ns + 'bind_shape_matrix')
            shape.text = ' '.join(str(world[r][c]) for r in range(4) for c in range(4))
        for child in node.findall('c:node', NS):
            walk(child, world)

    for node in doc.findall('c:library_visual_scenes/c:visual_scene/c:node', NS):
        walk(node, Matrix.Identity(4))
    attach_meshes(doc, path, None, {})
