// TSN setup — split out of the progress deck.
//
//   typst compile docs/reports/tsn_setup.typ
//
// This is future work rather than a bring-up step, so it was moved out of
// 2026-08_golfcart_progress.typ to keep that deck on the path to an autonomous
// run. Content and the architecture figure are from the 2026-08-05 draft.

#set page(paper: "presentation-16-9", margin: (x: 2.4cm, y: 1.8cm))
#set text(font: ("Liberation Sans", "DejaVu Sans"), size: 19pt)
#set par(justify: false, leading: 0.75em)

#let accent = rgb("#1f5c99")
#let muted = rgb("#5a5a5a")

#let slide(title, body) = {
  text(size: 27pt, weight: "regular")[#title]
  v(0.3em)
  line(length: 100%, stroke: 0.6pt + accent.lighten(45%))
  v(0.45em)
  block(width: 100%)[
    #set text(size: 17pt)
    #body
  ]
  pagebreak(weak: true)
}

#let note(body) = block(inset: (left: 1.1em, top: 0.2em), width: 100%)[
  #text(size: 14pt, fill: muted)[#body]
]

#align(center + horizon)[
  #text(size: 38pt)[TSN Setup]
  #v(0.4em)
  #text(size: 20pt, fill: muted)[Time-Sensitive Networking — target architecture]
  #v(1.4em)
  #text(size: 16pt, fill: muted)[NEWSLab NTU · future work]
]
#pagebreak(weak: true)

#slide[Target Time-Sensitive Network architecture][
  #align(center)[#image("assets/tsn_architecture.png", height: 9.6cm)]
]

#slide[Design options towards TSN][
  All hosts in the TSN must have a network card with TSN features:

  #v(0.4em)
  #note[
    - *gPTP* — generalized precision time protocol
    - *802.1Qbv* — enhancements for scheduled traffic
    - *802.1Qav* — credit-based shaper
  ]

  #v(0.8em)
  A TSN switch is necessary because there are three machines in the network.

  #v(0.3em)
  #note[The switch cannot be replaced by a normal hub, due to PTP requirements.]
]

#slide[TSN support on the machines we have][
  #set text(size: 17pt)
  #table(
    columns: (auto, 1fr),
    stroke: none,
    inset: (x: 0.4em, y: 0.55em),
    row-gutter: 0.15em,
    [*AGX Orin*], [I226 NIC attached on the PCIe slot],
    [*Advantech*], [NIC does not support TSN. PCIe is not available and may
                    require slot extension.],
    [*NXP safety island*], [Ethernet T1 socket requires a converter to standard
                            Ethernet TX.],
    [*AGX Thor*], [Supports built-in TSN, but has no PCIe slot. A candidate to
                   replace the AGX Orin.],
  )
]
