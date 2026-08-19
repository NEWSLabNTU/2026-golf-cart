# Deck assets

## Diagrams: edit the `.dot`, not the `.png`

Three figures are generated from Graphviz source. The `.dot` file is the master;
the `.png` and `.svg` beside it are outputs and are overwritten on every build.

| source | outputs | used on |
|---|---|---|
| `sensor_wiring.dot` | `.png`, `.svg` | System architecture |
| `vcu_lineage.dot` | `.png`, `.svg` | Vehicle interface |
| `vcu_states.dot` | `.png`, `.svg` | Autonomous engagement |

Rebuild after editing:

```bash
cd docs/reports/assets
for f in sensor_wiring vcu_lineage vcu_states; do
    dot -Tpng -Gdpi=150 "$f.dot" -o "$f.png"
    dot -Tsvg           "$f.dot" -o "$f.svg"
done
```

`dot` comes from the `graphviz` package.

### Editing without Graphviz

The `.svg` opens in Inkscape, Illustrator, Figma and draw.io, and imports into
PowerPoint (Insert > Pictures, then Graphics Format > Convert to Shape to get
native editable shapes). **If you edit the SVG, the `.dot` is no longer the
source of truth** for that figure. Either fold the change back into the `.dot`
or say so in a comment there, otherwise the next rebuild silently reverts it.

### Text size is chosen by measurement, not by eye

Each figure is scaled down to fit its slide, and that scales its text too. To
keep diagram text at the slide's own body size:

    effective_pt = fontsize * display_height_cm / (png_height_px / 150 * 2.54)

`sensor_wiring` uses `fontsize=34` because it is shown about 9 cm tall, which
lands near the 15 pt body text. If you change how large a figure appears on a
slide, re-measure rather than guessing.

Two layout traps that cost rebuilds, recorded so they are not rediscovered:

- **Height is what forces the scaling.** A tall figure gets shrunk until nothing
  is readable. `sensor_wiring` puts the Advantech sensors on two ranks for this
  reason. Side-by-side clusters were tried and rejected: at 5.5:1 the figure
  became a strip and had to be scaled down further still.
- **Keep labels short.** Interfaces, IP addresses and topic names inside node
  cards force the font down. They belong on an edge, in the slide text, or in
  what the presenter says.

## Other assets

- `theme_band.png`, `logo_*.png` are extracted from the lab PowerPoint template
  and used by the Typst deck. The pptx build does not need them: its layouts
  carry the same marks.
- `lab_template.pptx` is that template with its slides stripped. It is the input
  to `scripts/report/build_pptx.py`.
- `ndt_run_still.png` is a frame from `data/captures/ndt_run.gif`. The PDF
  cannot animate, so it holds the still while the pptx holds the clip.
- `ndt_slide_chart.png` is the NDT time series, no longer on a slide, kept for
  questions.
