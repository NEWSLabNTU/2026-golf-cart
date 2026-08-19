# Progress deck — brief and working notes

Requirements captured 2026-08-19, driving the structure of
`2026-08_golfcart_progress.typ`.

## What the report has to do

**Tell the story as a sequence of bring-up steps, not as a list of subsystems.**
The audience should be able to see where the project is along a path to an
autonomous run:

1. **Sensors** — LiDARs, cameras, IMU, GNSS
2. **System** — multi-host bring-up, systemd orchestration
3. **Vehicle interface** — VCU to Autoware
4. **Full data collection run** — the run that produced the NDT data
5. **Full autonomous run** — the goal

Each step carries a status: **ready** or **in progress**. The value of the deck
is that someone can see at a glance which steps are done and where the front
line is.

## What to emphasise

Work specific to *this* vehicle, rather than anything Autoware gives for free:

- **VCU → vehicle interface.** The Turing Drive CAN integration: the DBC, the
  interface node, what the VCU does and does not report.
- **Multi-host.** Splitting the stack across the Advantech and the AGX Orin, and
  the orchestration that took (host arguments, systemd units, cgroup cleanup,
  watchdog).

These are the parts that were engineered here and are worth presenting in
detail. NDT tuning is one part of the story, not the centre of it.

## Consequences for the current deck

The 2026-08-05 draft was organised by topic (multi-host, TSN, CAN). The report
needs re-organising around the five steps above, with TSN and the CAN wiring
folded in as supporting detail rather than as top-level sections.

## Figures on hand

`assets/vehicle_csie_init.jpg` — the cart at the CSIE initial pose, the start of
the CSIE-1 / CSIE-2 sets. `assets/vehicle_blvd_init.jpg` — the cart on the palm
boulevard at the BLVD initial pose, the start of BLVD-1. Both show the sensor
box and the safety driver, so they double as the vehicle photograph.

`assets/thermal_fan_cooling.jpg` — a household fan held against the open
equipment cabinet to cool the compute during a run. This is the evidence behind
"the Advantech burns" in the multi-host rationale: the thermal limit is not a
projection, it is being managed by hand in the field. Also shows the cabinet
interior — the 2400 W portable power station above, the compute stack below.

Draft figures carried over from the 2026-08-05 deck: multi-host photo, NXP
safety island, multi-host launch diagram, TSN architecture, broken CAN
connector, CAN wire remake sketch.

## TSN moved out

TSN is future work, not a bring-up step, so it now lives in `tsn_setup.typ` as a
separate 4-slide deck. Nothing was deleted — the architecture figure and both
design-option slides moved across intact.

## Startup governor belongs to the system step

`play_launch`'s `execution::startup_governor` (NEWSLabNTU/play_launch, 26be606
and follow-ups) is golf-cart-relevant engineering and sits under *System*:
bringing up 144 processes at once could kill the host. Worth presenting because
the negative result is the interesting part — pacing spawns was implemented,
measured, and rejected (startup 10.6 s -> 23.8 s for ~10% fewer runnable
tasks); what ships is a 1 GiB MemAvailable floor, capped at a quarter of RAM.

## Sensor wiring diagram

`assets/sensor_wiring.dot` -> `sensor_wiring.png`, rendered with graphviz.
Ownership is taken from `config/recording/{master,orin}_topics.txt`, which is
the authoritative record of which host publishes what; connection types come
from the sensor kit configs.

Advantech AFE-R750 (master): VLP-32C and Falcon over Ethernet, three GMSL
cameras over MIPI capture, u-blox over USB serial, Xsens IMU over CAN (not
working), VCU over CAN can0. AGX Orin: ZED X over GMSL into the ZEDLink capture
card, PCIe to the driver.

The link between the machines is drawn as what it is — not a cable but ROS 2
topics over DDS on the GolfCart wifi AP, plus ssh for unit start/stop. Worth
drawing because the IMU the stack actually uses crosses that link at 100 Hz,
which is why its latency is a localization concern rather than a networking
detail.

## Sensor integration material

See `notes-otocam.md` for the oToCam GMSL cameras — the device tree overlay that
kills the USB ports, and the UYVY-to-RGB/JPEG conversion for which no GPU
GStreamer element was found, forcing it onto the CPU once per camera. Both belong under *Sensors*, and both feed the compute-budget story
that runs through the thermal photo, the htop photo and the governor.

## Open questions to resolve before finalising

- Status of each of the five steps — the repo shows evidence for sensors,
  system and vehicle interface, but "ready" vs "in progress" is a judgement the
  team should make, not one to infer from commits.
- Whether the autonomous run has been attempted at all, and if so what stopped
  it.
- Whether TSN belongs in this deck or is future work shown separately.
  RESOLVED: moved to `tsn_setup.typ`.
- gmslcam: RESOLVED — migration is planned, not done. Present as intended fix.
- Whether the Seyond Falcon is still fitted. It is in the master recording list
  and recorded 4208 messages in CSIE-1, but the localization story is
  VLP-32C-only.
- Whether the u-blox GNSS is fitted at all right now. It is drawn as present
  hardware in the wiring diagram but was switched off for the NTU runs.
