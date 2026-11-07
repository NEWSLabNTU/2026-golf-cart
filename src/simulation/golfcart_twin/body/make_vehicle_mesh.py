#!/usr/bin/env python3
"""The cart's body as an Autoware vehicle mesh (COLLADA), for golfcart_vehicle_description.

    python3 make_vehicle_mesh.py OUT.dae

The same geometry as make_body.py (body, sensor housings, wheels), written in the frame
Autoware's vehicle descriptions use for their mesh (sample_vehicle_description's lexus.dae):
Y up, the vehicle facing -X and its left along +Z, the origin on the ground at mid wheelbase.
vehicle.xacro places it on base_link with

    <origin xyz="${wheel_base/2.0} 0 0" rpy="${pi/2.0} 0 ${pi}"/>

One geometry per material, flat shaded (a normal per triangle), every triangle written for
both sides (RViz culls back faces), colours as plain Phong diffuse, no textures. Needs numpy and make_body.py beside this file (usd-core, which
make_body imports, is not used here but must be importable).
"""
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_body as mb  # noqa: E402


def mesh_frame():
    """base_link -> mesh: the inverse of the xacro's origin (translate wheel_base/2, rpy pi/2, 0, pi)."""
    R = mb.rpy(math.pi / 2, 0.0, math.pi)
    t = np.array([mb.WHEEL_BASE / 2.0, 0.0, 0.0])
    return lambda p: (np.asarray(p) - t) @ R      # R^T (p - t), row vectors


def parts_by_material():
    """{material: (points [N,3] base_link, triangles [M,3])} for the body and the four wheels."""
    out = {}

    def add(mat, pts, faces):
        P, T = out.setdefault(mat, ([], []))
        o = sum(len(p) for p in P)
        P.append(np.asarray(pts, float))
        for f in faces:
            for k in range(1, len(f) - 1):
                T.append((f[0] + o, f[k] + o, f[k + 1] + o))

    for _, (part, mat) in mb.build().items():
        add(mat, part.points(), part.faces)
    for name, (xb, left) in mb.WHEELS.items():
        c = np.array([xb, (1 if left else -1) * mb.WHEEL_TREAD / 2, mb.WHEEL_RADIUS])
        for _, (part, mat) in mb.wheel(left).items():
            add(mat, part.points() + c, part.faces)
    return {m: (np.concatenate(P), np.array(T, int)) for m, (P, T) in out.items()}


def floats(a):
    return " ".join(f"{v:.5f}" for v in np.asarray(a).ravel())


def write_dae(path):
    to_mesh = mesh_frame()
    parts = parts_by_material()
    effects, materials, geometries, nodes = [], [], [], []
    ntri = 0
    for mat, (P, T) in sorted(parts.items()):
        col, rough, metal, opac = mb.MATERIALS[mat]
        rgb = " ".join(f"{c:.4f}" for c in col)
        shin = f"{(1.0 - rough) * 64:.1f}"
        tr = f"<transparent opaque=\"A_ONE\"><color>1 1 1 {opac:.3f}</color></transparent><transparency><float>1</float></transparency>" if opac < 1 else ""
        effects.append(f"""    <effect id="{mat}-effect"><profile_COMMON><technique sid="common"><phong>
      <diffuse><color>{rgb} 1</color></diffuse><specular><color>0.2 0.2 0.2 1</color></specular>
      <shininess><float>{shin}</float></shininess>{tr}
    </phong></technique></profile_COMMON></effect>""")
        materials.append(f'    <material id="{mat}-material" name="{mat}"><instance_effect url="#{mat}-effect"/></material>')
        V = to_mesh(P)
        n = np.cross(V[T[:, 1]] - V[T[:, 0]], V[T[:, 2]] - V[T[:, 0]])
        ln = np.linalg.norm(n, axis=1)
        keep = ln > 1e-12
        T, n = T[keep], n[keep] / ln[keep, None]
        # both sides: RViz culls back faces, and the generator's winding is not uniformly outward
        T, n = np.concatenate([T, T[:, ::-1]]), np.concatenate([n, -n])
        ntri += len(T)
        idx = np.stack([T, np.repeat(np.arange(len(T))[:, None], 3, 1)], 2).ravel()
        g = mat
        geometries.append(f"""    <geometry id="{g}-mesh" name="{g}"><mesh>
      <source id="{g}-pos"><float_array id="{g}-pos-array" count="{V.size}">{floats(V)}</float_array>
        <technique_common><accessor source="#{g}-pos-array" count="{len(V)}" stride="3"><param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/></accessor></technique_common></source>
      <source id="{g}-nrm"><float_array id="{g}-nrm-array" count="{n.size}">{floats(n)}</float_array>
        <technique_common><accessor source="#{g}-nrm-array" count="{len(n)}" stride="3"><param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/></accessor></technique_common></source>
      <vertices id="{g}-vtx"><input semantic="POSITION" source="#{g}-pos"/></vertices>
      <triangles material="{mat}" count="{len(T)}">
        <input semantic="VERTEX" source="#{g}-vtx" offset="0"/><input semantic="NORMAL" source="#{g}-nrm" offset="1"/>
        <p>{" ".join(map(str, idx))}</p></triangles>
    </mesh></geometry>""")
        nodes.append(f"""      <node id="{g}" name="{g}"><instance_geometry url="#{g}-mesh"><bind_material><technique_common>
        <instance_material symbol="{mat}" target="#{mat}-material"/></technique_common></bind_material></instance_geometry></node>""")
    dae = f"""<?xml version="1.0" encoding="utf-8"?>
<COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
  <asset>
    <contributor><authoring_tool>make_vehicle_mesh.py (2026-golf-cart src/simulation/golfcart_twin/body)</authoring_tool></contributor>
    <unit name="meter" meter="1"/>
    <up_axis>Y_UP</up_axis>
  </asset>
  <library_effects>
{chr(10).join(effects)}
  </library_effects>
  <library_materials>
{chr(10).join(materials)}
  </library_materials>
  <library_geometries>
{chr(10).join(geometries)}
  </library_geometries>
  <library_visual_scenes>
    <visual_scene id="Scene" name="Scene">
{chr(10).join(nodes)}
    </visual_scene>
  </library_visual_scenes>
  <scene><instance_visual_scene url="#Scene"/></scene>
</COLLADA>
"""
    Path(path).write_text(dae)
    allp = to_mesh(np.concatenate([P for P, _ in parts.values()]))
    print(f"{path}: {ntri} triangles, {len(parts)} materials; mesh-frame box {allp.min(0).round(3).tolist()} .. {allp.max(0).round(3).tolist()}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    write_dae(sys.argv[1])
