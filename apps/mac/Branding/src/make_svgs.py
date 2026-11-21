#!/usr/bin/env python3
"""Generates the CraftPanel icon masters (1024x1024 SVG) from one geometry.

Artwork is a vector recreation of the current app icon (orange 2x2x2 grid
cube over a slider glyph on a charcoal squircle). Placed on Apple's macOS
icon grid (824pt body centered on the 1024 canvas) so macOS 26 doesn't
put it in a grey backing plate.
"""
import os
OUT = os.path.join(os.path.dirname(__file__), "..")

# Geometry in a 1024 "full-bleed" space (measured from the current PNG).
T, R, C, L = (512, 150), (762, 295), (512, 440), (262, 295)
B, LB, RB = (512, 725), (262, 580), (762, 580)
def mid(a, b): return ((a[0]+b[0])/2, (a[1]+b[1])/2)
def poly(*pts): return " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)

def cube(top, left, right, seam_t, seam_l, seam_r, seam_w=16):
    s = []
    for pts, fill in ((poly(T, R, C, L), top), (poly(L, C, B, LB), left), (poly(C, R, RB, B), right)):
        # same-colour round-joined stroke = softly rounded corners
        s.append(f'<polygon points="{pts}" fill="{fill}" stroke="{fill}" stroke-width="18" stroke-linejoin="round"/>')
    def line(a, b, col): return f'<line x1="{a[0]:.1f}" y1="{a[1]:.1f}" x2="{b[0]:.1f}" y2="{b[1]:.1f}" stroke="{col}" stroke-width="{seam_w}" stroke-linecap="round"/>'
    s += [line(mid(T, L), mid(R, C), seam_t), line(mid(T, R), mid(L, C), seam_t),
          line(mid(L, C), mid(LB, B), seam_l), line(mid(L, LB), mid(C, B), seam_l),
          line(mid(R, C), mid(RB, B), seam_r), line(mid(R, RB), mid(C, B), seam_r)]
    return "\n    ".join(s)

def sliders(col, knob):
    s = []
    for y, kx in ((795, 432), (852, 570), (910, 473)):
        s.append(f'<line x1="366" y1="{y}" x2="{kx-26}" y2="{y}" stroke="{col}" stroke-width="18" stroke-linecap="round"/>')
        s.append(f'<line x1="{kx+26}" y1="{y}" x2="660" y2="{y}" stroke="{col}" stroke-width="18" stroke-linecap="round"/>')
        s.append(f'<rect x="{kx-8}" y="{y-23}" width="16" height="46" rx="8" fill="{knob}"/>')
    return "\n    ".join(s)

def doc(body, bg=None, grid=True, defs=""):
    back = ""
    if bg:
        back = f'<rect x="0" y="0" width="1024" height="1024" rx="230" ry="230" fill="url(#bg)"/>'
        defs += f'<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{bg[0]}"/><stop offset="1" stop-color="{bg[1]}"/></linearGradient>'
    t = 'transform="translate(100 100) scale(0.8046875)"' if grid else ""
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>{defs}</defs>
  <g {t}>
    {back}
    {body}
  </g>
</svg>
'''

ORANGE = ("#E0586B", "#C83246", "#A8283A", "#8F2230", "#7D1D2B", "#6B1824")  # name kept; OMNI crimson
variants = {
    # (a) light/default
    "icon-default.svg": doc(cube(*ORANGE) + "\n    " + sliders("#8f8677", "#b9af9f"), bg=("#2a2522", "#0f0e0d")),
    # (b) dark appearance: deeper background, slightly brighter glyph
    "icon-dark.svg": doc(cube("#EA6A7C", "#D43A4F", "#B52C40", "#9A2536", "#872030", "#751A28") + "\n    " + sliders("#7d7466", "#a39a8a"), bg=("#1c1917", "#070605")),
    # (c) tinted/monochrome: grayscale luminance only, the system applies the tint
    "icon-tinted.svg": doc(cube("#FFFFFF", "#D9D9D9", "#B3B3B3", "#9A9A9A", "#8C8C8C", "#7A7A7A") + "\n    " + sliders("#8A8A8A", "#B0B0B0"), bg=("#1C1C1C", "#0A0A0A")),
    # (d) glyph only, transparent — web, docs, landing page (full-bleed art, no grid inset)
    "glyph.svg": doc(cube(*ORANGE) + "\n    " + sliders("#8f8677", "#b9af9f"), grid=True),
    # small-size variant (16/32 px): cube only, enlarged, heavier seams — sliders are mush at 16px
    "icon-small.svg": doc(
        '<g transform="translate(512 512) scale(1.28) translate(-512 -437)">' + cube(*ORANGE, seam_w=26) + '</g>',
        bg=("#2a2522", "#0f0e0d")),
}
os.makedirs(OUT, exist_ok=True)
for name, svg in variants.items():
    with open(os.path.join(OUT, name), "w") as f: f.write(svg)
    print("wrote", name)
