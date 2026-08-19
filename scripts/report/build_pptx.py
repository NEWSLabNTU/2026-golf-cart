#!/usr/bin/env python3
"""Build the progress deck as a .pptx, on the lab's own template.

    python3 scripts/report/build_pptx.py

Why this exists alongside the Typst deck: a PDF cannot animate a GIF, and the
NDT slide is far better with the localization run moving. PowerPoint plays an
inserted GIF in slideshow mode, so this build gets the clip and the PDF gets a
still. The two decks carry the same content and should be edited together.

The template is assets/lab_template.pptx, which is 20251029_Progress.pptx with
its slides removed: theme, masters and layouts survive untouched. That matters
more than it sounds, because layouts 11 and 12 carry the band image, the large
Autoware mark and the three logo footers as layout shapes. Every slide inherits
the furniture without this script placing a single logo.

Geometry is the template's own, in centimetres:

    content title   48pt bold accent1, at x 1.40 y 0.24, no rule
    body starts     y 2.99
    slide           25.4 x 14.2875

Layout 11 = title (3 pictures).  Layout 12 = title and body (2 pictures).
"""

import copy
import re
import sys
from pathlib import Path

from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
from pptx.util import Cm, Pt

REPO = Path(__file__).resolve().parents[2]
ASSETS = REPO / "docs" / "reports" / "assets"
CAPTURES = REPO / "data" / "captures"
# The lab template with its slides removed, so only the theme, masters and
# layouts remain. Committed at 1.9 MB rather than the 8.2 MB original, whose
# unused slide media we do not need and should not carry. Regenerate with:
#
#   python3 -c "import sys; sys.path.insert(0,'scripts/report'); \
#     from build_pptx import strip_slides; from pptx import Presentation; \
#     p=Presentation('<original.pptx>'); strip_slides(p); \
#     p.save('docs/reports/assets/lab_template.pptx')"
TEMPLATE = REPO / "docs" / "reports" / "assets" / "lab_template.pptx"
OUT = REPO / "docs" / "reports" / "2026-08_golfcart_progress.pptx"

ACCENT = RGBColor(0x42, 0x85, 0xF4)
INK = RGBColor(0x00, 0x00, 0x00)
MUTED = RGBColor(0x53, 0x53, 0x53)
TEAL = RGBColor(0x00, 0x97, 0xA7)
AMBER = RGBColor(0xA8, 0x5F, 0x00)
RED = RGBColor(0xC5, 0x37, 0x2C)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)

FONT = "Arial"
TOP = 2.55          # cm, where content starts
BOTTOM = 12.95      # cm, above the logo footer
LEFT = 1.40
RIGHT = 24.00
WIDTH = RIGHT - LEFT

CHIPS = {
    "ready": ("ready", TEAL, RGBColor(0xE4, 0xF4, 0xF6)),
    "wip": ("in progress", AMBER, RGBColor(0xFF, 0xF6, 0xE8)),
    "flawed": ("done, data flawed", AMBER, RGBColor(0xFF, 0xF6, 0xE8)),
    "none": ("not started", RED, RGBColor(0xFB, 0xE9, 0xE7)),
}


# ── helpers ──────────────────────────────────────────────────────────────────

def strip_slides(prs):
    """Empty the deck without touching theme, masters or layouts."""
    ids = prs.slides._sldIdLst
    for sld in list(ids):
        rid = sld.get(
            "{http://schemas.openxmlformats.org/officeDocument/2006/"
            "relationships}id"
        )
        prs.part.drop_rel(rid)
        ids.remove(sld)


def drop_placeholder(slide, idx):
    for ph in list(slide.placeholders):
        if ph.placeholder_format.idx == idx:
            ph._element.getparent().remove(ph._element)


def runs(paragraph, text, size, color=INK, bold_default=False):
    """Write text into a paragraph, honouring **bold** spans."""
    for i, part in enumerate(re.split(r"\*\*(.+?)\*\*", text, flags=re.S)):
        if not part:
            continue
        run = paragraph.add_run()
        run.text = part
        run.font.size = Pt(size)
        run.font.name = FONT
        run.font.color.rgb = color
        run.font.bold = bold_default or (i % 2 == 1)


def textbox(slide, x, y, w, h, blocks, size: float = 13, color=INK, space=8,
            line=0.92, anchor=MSO_ANCHOR.TOP):
    """A plain text box. `blocks` is a list of strings, or (text, size, color)
    or (text, size, color, bullet)."""
    box = slide.shapes.add_textbox(Cm(x), Cm(y), Cm(w), Cm(h))
    tf = box.text_frame
    tf.word_wrap = True
    tf.margin_left = tf.margin_right = tf.margin_top = tf.margin_bottom = 0
    tf.vertical_anchor = anchor
    first = True
    for block in blocks:
        if isinstance(block, str):
            text, sz, col, bullet = block, size, color, False
        elif len(block) == 3:
            (text, sz, col), bullet = block, False
        else:
            text, sz, col, bullet = block
        para = tf.paragraphs[0] if first else tf.add_paragraph()
        first = False
        para.alignment = PP_ALIGN.LEFT
        para.space_before = Pt(0 if para is tf.paragraphs[0] else space)
        para.line_spacing = line
        if bullet:
            para.level = 0
            runs(para, "•   " + text, sz, col)
            para.space_after = Pt(2)
        else:
            runs(para, text, sz, col)
    return box


def chip(slide, x, y, state, size: float = 10):
    label, stroke, fill = CHIPS[state]
    w = 1.05 + 0.155 * len(label)
    shape = slide.shapes.add_shape(
        MSO_SHAPE.ROUNDED_RECTANGLE, Cm(x), Cm(y), Cm(w), Cm(0.62)
    )
    shape.adjustments[0] = 0.28
    shape.fill.solid()
    shape.fill.fore_color.rgb = fill
    shape.line.color.rgb = stroke
    shape.line.width = Pt(0.9)
    shape.shadow.inherit = False
    tf = shape.text_frame
    tf.margin_left = tf.margin_right = tf.margin_top = tf.margin_bottom = 0
    tf.word_wrap = False
    para = tf.paragraphs[0]
    para.alignment = PP_ALIGN.CENTER
    runs(para, label, size, stroke, bold_default=True)
    return w


def picture(slide, name, x, y, *, h=None, w=None, folder=ASSETS):
    path = folder / name
    if not path.exists():
        sys.exit(f"missing asset: {path}")
    kw = {}
    if h is not None:
        kw["height"] = Cm(h)
    if w is not None:
        kw["width"] = Cm(w)
    return slide.shapes.add_picture(str(path), Cm(x), Cm(y), **kw)


def centre(shape, left, width):
    """Horizontally centre an already-placed shape inside a column."""
    shape.left = Cm(left) + (Cm(width) - shape.width) // 2


def add(prs, layout, title=None, subtitle_idx=21):
    slide = prs.slides.add_slide(prs.slide_layouts[layout])
    drop_placeholder(slide, 1)
    drop_placeholder(slide, subtitle_idx)
    if title is not None:
        ph = slide.shapes.title
        ph.top, ph.left = Cm(0.24), Cm(LEFT)
        ph.width, ph.height = Cm(22.34), Cm(1.60)
        tf = ph.text_frame
        tf.word_wrap = True
        para = tf.paragraphs[0]
        runs(para, title, 48, ACCENT, bold_default=True)
    return slide


def table(slide, x, y, w, rows, widths, size: float = 12.5,
          header_size: float = 12.5, row_h=0.72):
    shape = slide.shapes.add_table(
        len(rows), len(widths), Cm(x), Cm(y), Cm(w), Cm(row_h * len(rows))
    )
    tbl = shape.table
    tbl.first_row = True
    tbl.horz_banding = False
    for i, cw in enumerate(widths):
        tbl.columns[i].width = Cm(cw)
    for r, row in enumerate(rows):
        tbl.rows[r].height = Cm(row_h)
        for c, cell in enumerate(row):
            tc = tbl.cell(r, c)
            tc.fill.background()
            tc.margin_left = Cm(0.12)
            tc.margin_right = Cm(0.12)
            tc.margin_top = Cm(0.05)
            tc.margin_bottom = Cm(0.05)
            tc.vertical_anchor = MSO_ANCHOR.MIDDLE
            para = tc.text_frame.paragraphs[0]
            para.alignment = PP_ALIGN.LEFT
            if cell is None:
                continue
            runs(para, cell, header_size if r == 0 else size, INK,
                 bold_default=(r == 0))
    return tbl


# ── the deck ─────────────────────────────────────────────────────────────────

def build():
    if not TEMPLATE.exists():
        sys.exit(f"missing template: {TEMPLATE}")
    prs = Presentation(str(TEMPLATE))
    strip_slides(prs)   # no-op on the committed template; kept for a fresh one

    # ── 1  title.  Layout 11 supplies the bands and the large Autoware mark.
    s = prs.slides.add_slide(prs.slide_layouts[11])
    drop_placeholder(s, 21)
    ph = s.shapes.title
    ph.top, ph.left = Cm(4.99), Cm(11.99)
    ph.width, ph.height = Cm(13.07), Cm(2.0)
    runs(ph.text_frame.paragraphs[0], "Golf Cart bring-up progress", 25,
         ACCENT, bold_default=True)
    body = s.placeholders[1]
    body.top, body.left = Cm(7.05), Cm(12.20)
    body.width, body.height = Cm(12.66), Cm(2.4)
    tf = body.text_frame
    tf.word_wrap = True
    runs(tf.paragraphs[0], "National Taiwan University", 20, INK,
         bold_default=True)
    p2 = tf.add_paragraph()
    p2.space_before = Pt(6)
    runs(p2, "Autoware LSV meeting, August 2026", 13, MUTED)

    # ══ what works ═══════════════════════════════════════════════════════════

    # ── 2  vehicle platform, and the six steps
    s = add(prs, 12, "Vehicle platform")
    picture(s, "vehicle_blvd_init.jpg", LEFT, TOP + 0.55, h=7.4)
    textbox(s, 13.6, TOP + 0.3, 10.4, 3.0, [
        "A low-speed campus vehicle on a **Turing Drive VCU**, with an "
        "Autoware stack across **two machines**.",
        "Bring-up sequence:",
    ], size=13.5, space=9)
    steps = [
        ("1.  Sensors", "ready"),
        ("2.  Two-host system", "ready"),
        ("3.  Vehicle interface", "wip"),
        ("4.  Map preparation", "ready"),
        ("5.  Data collection", "flawed"),
        ("6.  Autonomous run", "none"),
    ]
    for i, (label, state) in enumerate(steps):
        y = TOP + 2.55 + i * 0.86
        textbox(s, 13.6, y + 0.10, 5.2, 0.6, [label], size=12.5)
        chip(s, 18.9, y, state)
    textbox(s, 13.6, BOTTOM - 0.65, 10.4, 0.6,
            ["Currently operating at NTU."], size=13.5)

    # ── 3  system architecture
    s = add(prs, 12, "System architecture")
    pic = picture(s, "sensor_wiring.png", 0, TOP + 0.15, h=8.9)
    centre(pic, LEFT, WIDTH - 4.6)
    keys = [("sensor", RGBColor(0xF4, 0xF8, 0xFB), RGBColor(0xB7, 0xC7, 0xDA)),
            ("software", ACCENT, ACCENT),
            ("vehicle control", RGBColor(0xE4, 0xF4, 0xF6), TEAL),
            ("not in service", RGBColor(0xFF, 0xF6, 0xE8),
             RGBColor(0xFF, 0xAB, 0x40))]
    for i, (label, fill, line) in enumerate(keys):
        y = TOP + 2.4 + i * 1.15
        sw = s.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE,
                                Cm(20.1), Cm(y), Cm(0.62), Cm(0.36))
        sw.fill.solid()
        sw.fill.fore_color.rgb = fill
        sw.line.color.rgb = line
        sw.line.width = Pt(1)
        sw.shadow.inherit = False
        sw.text_frame.text = ""
        textbox(s, 20.95, y - 0.03, 3.2, 0.5, [label], size=11.5)

    # ── 4  sensor integration
    s = add(prs, 12, "Sensor integration")
    textbox(s, LEFT, TOP + 0.15, WIDTH, 0.7,
            ["All sensors publish, across both hosts."], size=14)
    table(s, LEFT, TOP + 1.2, WIDTH, [
        ["Sensor", "Host", "Feeds"],
        ["Velodyne VLP-32C", "Advantech", "NDT scan matching, perception"],
        ["Seyond Falcon", "Advantech", "perception"],
        ["3 GMSL cameras", "Advantech", "perception, recording"],
        ["ZED X stereo + IMU", "Orin", "the IMU the stack runs on today"],
        ["u-blox GNSS", "Orin", "pose initialisation"],
        ["Turing Drive VCU", "Advantech", "velocity, gear, subsystem states"],
    ], widths=[6.2, 4.0, 12.4], size=13, header_size=13, row_h=0.86)

    # ── 5  multi-host orchestration
    s = add(prs, 12, "Multi-host orchestration")
    textbox(s, LEFT, TOP + 0.15, WIDTH, 0.9, [
        "ROS 2 provides no equivalent of ROS 1's machine tag, so orchestration "
        "is ours to supply. It is in place and operational."], size=13.5)
    tb = textbox(s, LEFT, TOP + 1.5, 10.6, 6.5, [
        ("Single instance, no orphaned processes", 13, INK),
        ("**play_launch** reclaims orphaned processes when a launch "
         "terminates, and brings the stack up in **~20 s** against **~60 s** "
         "for ros2 launch", 12.5, INK, True),
        ("**systemd user units** around it: singleton by construction, "
         "KillMode=control-group takes the whole tree down", 12.5, INK, True),
    ], space=9)
    tb.text_frame.paragraphs[0].runs[0].font.bold = True
    tb = textbox(s, 13.0, TOP + 1.5, 11.0, 6.5, [
        ("Uniform environment on either host", 13, INK),
        ("one CycloneDDS profile per role, plus a config/host marker file",
         12.5, INK, True),
        ("scripts/env.sh reads it, and every shell and every unit sources it",
         12.5, INK, True),
        ("so any shell is correctly configured on open, and no operator needs "
         "to track which host they are working on", 12.5, INK, True),
    ], space=9)
    tb.text_frame.paragraphs[0].runs[0].font.bold = True
    textbox(s, LEFT, BOTTOM - 0.7, WIDTH, 0.6, [
        "just launch-all starts both hosts and returns; just stop-all shuts "
        "them down."], size=11.5, color=MUTED)

    # ── 6  vehicle interface
    s = add(prs, 12, "Vehicle interface")
    pic = picture(s, "vcu_lineage.png", 0, TOP + 0.2, h=8.6)
    centre(pic, LEFT, 8.0)
    textbox(s, 10.4, TOP + 0.3, 13.6, 8.5, [
        ("Developed from the vendor's own test code rather than from a "
         "specification. Every stage exists in the repository.", 13.5, INK),
        ("The safety constraints are our addition:", 13.5, INK),
        ("target speed is clamped non-negative; reverse is gear R",
         13, INK, True),
        ("gear P forces speed and steering angle to zero, re-applied each "
         "cycle", 13, INK, True),
        ("ESTOP release is never bound to a key the terminal cannot emit",
         13, INK, True),
        ("A test suite sits above it: keyboard control, a command service, "
         "and trajectory replay.", 11.5, MUTED),
    ], space=10)

    # ── 7  data acquisition
    s = add(prs, 12, "Data acquisition")
    picture(s, "vehicle_csie_init.jpg", LEFT, TOP + 0.3, h=7.6)
    textbox(s, 13.3, TOP + 0.3, 10.7, 8.5, [
        ("Three runs at NTU. **Each host records independently**, writing only "
         "the topics for the devices it owns; the bags are merged afterwards.",
         13, INK),
        ("Only **first-hand driver output** is recorded. Derived topics are "
         "excluded, so replay recomputes them under current parameters rather "
         "than those fixed at record time.", 13, INK),
        ("Replay is a single command, just ntu-test run: bag paused for "
         "/clock, then stack, RViz and initial pose, in the required order.",
         11.5, MUTED),
    ], space=11)

    # ══ what needs fixing ════════════════════════════════════════════════════

    # ── 8  integration findings
    s = add(prs, 12, "Integration findings")
    textbox(s, LEFT, TOP + 0.15, WIDTH, 0.7,
            ["Three findings relevant to comparable deployments."], size=14)
    textbox(s, LEFT, TOP + 1.35, WIDTH, 8.0, [
        ("**The vendor's default oToCam setup enables the cameras and disables "
         "every USB port.** A workaround now provides both. The .ko files "
         "remain ABI-bound to kernel 5.15.148-tegra, so a JetPack update "
         "silently reverts it.", 14, INK, True),
        ("**The Xsens IMU cable has failed and is being remade.** The stack "
         "currently uses the **ZED X built-in IMU**, which resides on the "
         "other host and crosses the network at 100 Hz.", 14, INK, True),
        ("**The u-blox GNSS is hosted on the Orin**, the Advantech having no "
         "free USB port. A second localization input is therefore also remote, "
         "for an unrelated reason.", 14, INK, True),
    ], space=14)

    # ── 9  compute and thermal limits
    s = add(prs, 12, "Compute and thermal limits")
    textbox(s, LEFT, TOP + 0.3, 12.6, 8.5, [
        ("The three GMSL cameras emit **UYVY** at 1920x1280, 30 fps, while the "
         "consuming nodes require **RGB or JPEG**. A conversion is therefore "
         "unavoidable. **nvvidconv** was evaluated; the conversion still "
         "incurs CPU cost per camera.", 13.5, INK),
        ("This load contributes to the thermal saturation shown here, and is "
         "part of the rationale for splitting the stack across **two hosts**.",
         13.5, INK),
        ("Mitigation in progress: github.com/newslabntu/gmslcam, which removes "
         "that stage.", 11.5, MUTED),
    ], space=12)
    picture(s, "thermal_fan_cooling.jpg", 14.6, TOP + 0.3, h=7.6)

    # ── 10  start-up contention
    s = add(prs, 12, "Start-up contention")
    picture(s, "htop_before_governor.jpg", LEFT, TOP + 0.6, w=10.2)
    textbox(s, 12.6, TOP + 0.2, 11.4, 9.0, [
        ("play_launch is fast because it spawns without rate limiting. On a "
         "host already at its limit this produces a thundering herd, and the "
         "machine becomes unresponsive, requiring a power cycle.", 13, INK),
        ("**Rate-limiting the spawns is the obvious remedy, and measurement "
         "rejects it:** roughly 10% fewer runnable tasks for more than double "
         "the start-up time, forfeiting the advantage the tool was adopted "
         "for.", 13, INK),
        ("The shipped mechanism is a **1 GiB MemAvailable floor**, engaging "
         "only as the host approaches exhaustion.", 13, INK),
        ("Constrain the resource that is exhausted, not the spawn rate.",
         11.5, MUTED),
    ], space=10)

    # ── 11  autonomous engagement
    s = add(prs, 12, "Autonomous engagement and VCU state entry")
    s.shapes.title.text_frame.paragraphs[0].runs[0].font.size = Pt(32)
    pic = picture(s, "vcu_states.png", 0, TOP + 0.9, w=17.0)
    centre(pic, LEFT, WIDTH)
    textbox(s, LEFT, TOP + 5.6, 10.6, 3.6, [
        ("There is no vehicle_cmd_gate external selector. The interface issues "
         "no commands until all four subsystems report autonomous, and **no "
         "service call can override this**.", 12.5, INK),
    ])
    textbox(s, 13.0, TOP + 5.6, 11.0, 3.6, [
        ("After a VCU restart, **BRK and Drv initialise as Invalid**, and only "
         "a brake-pedal press was observed to clear them. Not reproducible "
         "over CAN.", 12.5, INK),
        ("**Unattended autonomous start-up is therefore blocked.** This "
         "requires clarification from the vendor rather than further work on "
         "our side.", 12.5, RED),
    ], space=8)

    # ── 12  NDT localization.  The GIF is the reason this deck exists.
    s = add(prs, 12, "NDT localization")
    gif = CAPTURES / "ndt_run.gif"
    picture(s, gif.name, LEFT, TOP + 0.35, h=7.6,
            folder=CAPTURES if gif.exists() else ASSETS)
    textbox(s, LEFT, TOP + 8.15, 9.0, 0.6, [
        "Scan aligned to the map at 11 km/h, 2x."], size=10.5, color=MUTED)
    textbox(s, 11.6, TOP + 0.25, 12.4, 9.0, [
        ("**The first successful NDT initialisation and tracking run on the "
         "NTU map.** Initialisation from GNSS, and convergence to 0.14 m while "
         "stationary.", 12.5, INK),
        ("Tracking then **degrades within seconds of the vehicle moving**. "
         "Tuning was evaluated against **scan-to-map residual** rather than "
         "the NVTL score: the change that most improved accuracy in fact "
         "reduced NVTL.", 12.5, INK),
        ("**The cause has been identified, and lies upstream of NDT in the "
         "recording:** 45% of scans cover only part of a revolution, and scans "
         "arrive **376 ms stale**. Neither is a localization parameter.",
         12.5, INK),
        ("Both are addressed in the next collection run, which records raw "
         "LiDAR packets.", 12, MUTED),
    ], space=9)

    # ══ close ════════════════════════════════════════════════════════════════

    # ── 13  bring-up status
    s = add(prs, 12, "Bring-up status")
    rows = [
        ["Step", None, "Outstanding issue"],
        ["Sensors", "ready",
         "partial LiDAR scans; Xsens cable under repair"],
        ["Two-host system", "ready", "none"],
        ["Vehicle interface", "wip",
         "the VCU will not enter its autonomous state over CAN alone"],
        ["Map preparation", "ready",
         "PCD and lanelet2 supplied by Turing Drive, downsampled at runtime"],
        ["Data collection", "flawed",
         "the recordings carry the sensor defects above"],
        ["Autonomous run", "none",
         "dependent on the vehicle interface issue"],
    ]
    top = TOP + 0.5
    row_h = 1.14
    table(s, LEFT, top, WIDTH,
          [[r[0], "", r[2]] for r in rows],
          widths=[5.4, 4.6, 12.6], size=12.5, header_size=12.5, row_h=row_h)
    # "State" is a chip, not text, so it is drawn over the table's second column
    textbox(s, LEFT + 5.55, top + 0.28, 3.0, 0.6, ["State"], size=12.5,
            color=INK)
    s.shapes[-1].text_frame.paragraphs[0].runs[0].font.bold = True
    for i, r in enumerate(rows[1:], start=1):
        chip(s, LEFT + 5.5, top + i * row_h + 0.26, r[1], size=10)

    # ── 14  next steps
    s = add(prs, 12, "Next steps")
    textbox(s, LEFT, TOP + 0.5, WIDTH, 8.0, [
        ("**Establish with Turing Drive what clears the Invalid brake state "
         "after a restart.** All remaining work on the autonomous run depends "
         "on this.", 14, INK, True),
        ("**Record raw LiDAR packets** and verify the VLP-32C rotation "
         "configuration against the hardware, then repeat the localization "
         "work on sound data.", 14, INK, True),
        ("**Migrate the sensor kit to gmslcam**, eliminating the per-camera "
         "CPU conversion.", 14, INK, True),
        ("TSN is a separate line of work, available for discussion if of "
         "interest.", 11.5, MUTED),
    ], space=16)

    prs.save(str(OUT))
    print(f"wrote {OUT}  ({OUT.stat().st_size / 1e6:.1f} MB, "
          f"{len(prs.slides.__iter__.__self__._sldIdLst)} slides)")


if __name__ == "__main__":
    build()
