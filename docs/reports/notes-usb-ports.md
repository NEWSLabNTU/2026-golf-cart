# The Advantech ran out of USB ports

Stated by the team, 2026-08-19. This is why the u-blox GNSS is on the Orin.

## The count

Five things want a USB port on the Advantech, and there are not five ports:

| Device | Why it is there |
|---|---|
| Keyboard | it is also the development machine |
| Mouse | same |
| Phone | USB tethering, the only internet the vehicle has |
| External disk | the on-board eMMC is too small for maps, bags and models |
| **u-blox GNSS** | the odd one out — the only one that is part of the vehicle |

The GNSS lost, and moved to the Orin.

## What this is not

**It is not the oToCam device tree overlay.** That overlay has its own USB
problem (`notes-otocam.md`), and the two are easy to conflate — but the team's
account of the GNSS move is a plain port count, not a driver conflict. Do not
merge them on a slide. If a slide needs the overlay's USB cost, state it on its
own terms and leave the GNSS out of it.

*(Worth a sentence of clarification from the team at some point: the oToCam notes
say enabling the overlay stops the USB ports working, and this note says four USB
devices are plugged in and working. Both came from the team, so one of them is
narrower than it reads — most likely the overlay affects some ports or some
configurations rather than all. Nothing in the deck should depend on resolving
it.)*

## Why it is worth a slide anyway

Not as a complaint — as an honest picture of what a research vehicle actually
looks like. The compute box is simultaneously the development workstation, the
internet gateway and the data logger, and those roles compete with the sensors
for physical ports. That is why a GNSS receiver ends up on the other machine and
its fix crosses a wifi link before reaching the localization stack that needs it.

Two consequences that do belong in the deck:

- **The eMMC is too small**, so bags, maps and models live on external storage.
  Anyone reproducing this setup should size the disk up front.
- **The GNSS fix now crosses the DDS link**, like the ZED IMU does, for a
  completely unrelated reason. Two of the localization inputs are remote, and
  neither is remote by design.

## Software has not caught up

The move is physical only. Both of these still place the GNSS on the master:

- `src/launcher/golfcart_launch/launch/golfcart.launch.yaml` — the host profile
  gives the Orin `ZED camera only`, so the u-blox driver never starts there.
- `config/recording/master_topics.txt` lists `/sensing/gnss/*`;
  `orin_topics.txt` lists none — the host without the device is the one told to
  record it, against this repo's own first-hand-topics rule.

Left alone, the next recording run has no GNSS in it and looks fine in
`ros2 bag info` — the exact failure the header comment in `master_topics.txt`
already warns about for the old `top/` and `ublox/` namespaces.
