"""Generates Tempra's Icon Composer documents (design/icons/*.icon).

Each icon is a stack of layer groups; Icon Composer/ictool apply Liquid Glass
(specular highlights, translucency, shadows) at render time. Open any .icon in
Icon Composer to fine-tune it.
"""
import json
import pathlib
import shutil

OUT = pathlib.Path(__file__).parent / "icons"

# Shared geometry on the 1024 pt canvas: history on the left, "now" at NOW, forecast fan to the right.
NOW = (540, 470)
HISTORY = "M170 690 C 235 690, 250 590, 315 590 S 395 660, 435 640 S 495 470, 540 470"
ECG = "M165 560 L 290 560 L 330 450 L 385 680 L 440 500 L 475 560 L 540 470"
MEDIAN_DOTS = [(615, 462), (690, 452), (765, 440), (840, 426)]


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


def dots(color="#FFFFFF", r=21):
    return svg("".join(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{color}"/>' for x, y in MEDIAN_DOTS))


def now_dot(color="#FFFFFF", r=46):
    return svg(f'<circle cx="{NOW[0]}" cy="{NOW[1]}" r="{r}" fill="{color}"/>')


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


VARIANTS = {
    # Deep night sky, cyan forecast cone: the original proposal C.
    "Horizon-Night": dict(
        fill=gradient((0.13, 0.18, 0.38), (0.03, 0.05, 0.14)),
        groups=[
            group("now", now_dot("#7CEBFF"), translucency=0.2, shadow="layer-color", shadow_opacity=0.7),
            group("median", dots(), translucency=0.3),
            group("history", stroke(HISTORY), translucency=0.25),
            group("fan", shape(fan(250, 230), "#5BE0FF"), translucency=0.55, shadow="layer-color", shadow_opacity=0.6, opacity=0.85),
        ]),
    # Dawn over the horizon: indigo to warm coral, frosted white cone.
    "Horizon-Dawn": dict(
        fill=gradient((0.28, 0.30, 0.70), (1.00, 0.52, 0.40)),
        groups=[
            group("now", now_dot(), translucency=0.15),
            group("median", dots(), translucency=0.3),
            group("history", stroke(HISTORY), translucency=0.2),
            group("fan", shape(fan(250, 230), "#FFFFFF"), translucency=0.7, opacity=0.6),
        ]),
    # Bright system blue, one bold glass cone: closest to Apple's own utility icons.
    "Horizon-Sky": dict(
        fill=gradient((0.33, 0.68, 1.00), (0.12, 0.36, 0.96)),
        groups=[
            group("history", stroke(HISTORY, width=72), translucency=0.15),
            group("fan", shape(fan(270, 250), "#FFFFFF"), translucency=0.75, opacity=0.55),
        ]),
    # Heartbeat history flowing into the forecast: vital signs + prediction.
    "Horizon-Pulse": dict(
        fill=gradient((0.05, 0.22, 0.24), (0.02, 0.07, 0.09)),
        groups=[
            group("now", now_dot("#B6FFD9"), translucency=0.15, shadow="layer-color", shadow_opacity=0.7),
            group("median", dots("#B6FFD9"), translucency=0.3),
            group("history", stroke(ECG, "#3DEB9A", 62), translucency=0.2, shadow="layer-color", shadow_opacity=0.6),
            group("fan", shape(fan(250, 230), "#2FD39A"), translucency=0.6, shadow="layer-color", shadow_opacity=0.5, opacity=0.7),
        ]),
    # Three stacked glass cones = the quantile bands (10–90, 25–75, 40–60).
    "Horizon-Bands": dict(
        fill=gradient((0.20, 0.13, 0.45), (0.06, 0.04, 0.17)),
        groups=[
            group("history", stroke(HISTORY), translucency=0.2),
            group("band-inner", shape(fan(70, 60), "#7CEBFF"), translucency=0.35, shadow="layer-color", shadow_opacity=0.5),
            group("band-mid", shape(fan(160, 145), "#4F8DFF"), translucency=0.5, shadow="layer-color", shadow_opacity=0.5, opacity=0.85),
            group("band-outer", shape(fan(260, 240), "#9B7BFF"), translucency=0.6, shadow="layer-color", shadow_opacity=0.5, opacity=0.75),
        ]),
    # Graphite and white glass only: quiet, and works best with tinted/clear modes.
    "Horizon-Graphite": dict(
        fill=gradient((0.33, 0.34, 0.37), (0.10, 0.11, 0.12)),
        groups=[
            group("now", now_dot(), translucency=0.1),
            group("median", dots(), translucency=0.3),
            group("history", stroke(HISTORY), translucency=0.15),
            group("fan", shape(fan(250, 230), "#FFFFFF"), translucency=0.8, opacity=0.4),
        ]),
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


if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    for name, spec in VARIANTS.items():
        print(write(name, spec))
