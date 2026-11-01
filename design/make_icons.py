"""Generates Tempra's Icon Composer documents (design/icons/*.icon).

Each icon is a stack of layer groups; Icon Composer/ictool apply Liquid Glass
(specular highlights, translucency, shadows) at render time. Open any .icon in
Icon Composer to fine-tune it.
"""
import json
import pathlib
import shutil

OUT = pathlib.Path(__file__).parent / "icons"

# Shared geometry on the 1024 pt canvas: history on the left, "now" at NOW, forecast cones to the right.
NOW = (540, 470)
HISTORY = "M170 690 C 235 690, 250 590, 315 590 S 395 660, 435 640 S 495 470, 540 470"


def fan(spread_top, spread_bottom, end_x=872):
    """Forecast cone from NOW to end_x, with a rounded outer edge."""
    x0, y0 = NOW
    top, bottom = y0 - spread_top, y0 + spread_bottom
    mid = (top + bottom) / 2
    return (f"M{x0} {y0} C {x0+110} {y0-10}, {end_x-120} {top+40}, {end_x} {top} "
            f"Q {end_x+46} {mid} {end_x} {bottom} "
            f"C {end_x-120} {bottom-40}, {x0+110} {y0+10}, {x0} {y0} Z")


def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{body}</svg>\n'


def stroke(path, color="#FFFFFF", width=66):
    return svg(f'<path d="{path}" fill="none" stroke="{color}" stroke-width="{width}" stroke-linecap="round" stroke-linejoin="round"/>')


def shape(path, color, opacity=1.0):
    return svg(f'<path d="{path}" fill="{color}" fill-opacity="{opacity}"/>')


def p3(r, g, b, a=1.0):
    return f"display-p3:{r:.5f},{g:.5f},{b:.5f},{a:.5f}"


def gradient(top, bottom):
    return {"linear-gradient": [p3(*top), p3(*bottom)],
            "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}}


def group(name, image, *, translucency=0.5, shadow="neutral", shadow_opacity=0.5, opacity=None, glass=True):
    layer = {"glass": glass, "image-name": f"{name}.svg", "name": name}
    if opacity is not None:
        layer["opacity"] = opacity
    return {"name": name, "layers": [layer], "_svg": image,
            "shadow": {"kind": shadow, "opacity": shadow_opacity},
            "translucency": {"enabled": translucency > 0, "value": translucency},
            "specular": True}


def bands(top, bottom, outer, mid, inner, *, line="#FFFFFF", opacities=(0.75, 0.85, 1.0),
          translucency=(0.6, 0.5, 0.35), shadow="layer-color"):
    """Tempra's icon: a history line flowing into three nested forecast cones (the 10–90,
    25–75 and 40–60 percentile bands). Variants only change palette and glass style."""
    return dict(
        fill=gradient(top, bottom),
        groups=[
            group("history", stroke(HISTORY, line), translucency=0.2),
            group("band-inner", shape(fan(70, 60), inner), translucency=translucency[2],
                  shadow=shadow, shadow_opacity=0.5, opacity=opacities[2]),
            group("band-mid", shape(fan(160, 145), mid), translucency=translucency[1],
                  shadow=shadow, shadow_opacity=0.5, opacity=opacities[1]),
            group("band-outer", shape(fan(260, 240), outer), translucency=translucency[0],
                  shadow=shadow, shadow_opacity=0.5, opacity=opacities[0]),
        ])


# Tinted variants colour each band; frosted variants use white glass at three densities.
FROSTED = dict(opacities=(0.35, 0.55, 0.9), translucency=(0.8, 0.7, 0.4), shadow="neutral")

VARIANTS = {
    "Indigo": bands((0.20, 0.13, 0.45), (0.06, 0.04, 0.17), "#9B7BFF", "#4F8DFF", "#7CEBFF"),
    "Night": bands((0.13, 0.18, 0.38), (0.03, 0.05, 0.14), "#2F6FE0", "#3FB8F0", "#9AF3FF"),
    "Dawn": bands((0.28, 0.30, 0.70), (1.00, 0.52, 0.40), "#FFB08F", "#FFD2B3", "#FFF4D6",
                  opacities=(0.6, 0.75, 0.95)),
    "Aurora": bands((0.05, 0.22, 0.24), (0.02, 0.07, 0.09), "#1FA98A", "#3DEB9A", "#C2FFD9"),
    "Sky": bands((0.33, 0.68, 1.00), (0.12, 0.36, 0.96), "#FFFFFF", "#FFFFFF", "#FFFFFF", **FROSTED),
    "Graphite": bands((0.33, 0.34, 0.37), (0.10, 0.11, 0.12), "#FFFFFF", "#FFFFFF", "#FFFFFF", **FROSTED),
}


def write(name, spec):
    doc = OUT / f"Tempra-{name}.icon"
    shutil.rmtree(doc, ignore_errors=True)
    (doc / "Assets").mkdir(parents=True)
    groups = []
    for g in spec["groups"]:
        g = dict(g)
        (doc / "Assets" / f"{g['name']}.svg").write_text(g.pop("_svg"))
        groups.append(g)
    icon = {"fill": spec["fill"], "groups": groups,
            "supported-platforms": {"circles": ["watchOS"], "squares": "shared"}}
    (doc / "icon.json").write_text(json.dumps(icon, indent=2) + "\n")
    return doc


# The variant compiled into the app as its primary icon (Settings can switch to the others).
DEFAULT = "Indigo"
APP_ICON = pathlib.Path(__file__).parent.parent / "Tempra" / "Resources" / "AppIcon.icon"

if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    for name, spec in VARIANTS.items():
        print(write(name, spec))
    shutil.rmtree(APP_ICON, ignore_errors=True)
    shutil.copytree(OUT / f"Tempra-{DEFAULT}.icon", APP_ICON)
    print(APP_ICON)
