# Map preparation — a bring-up step in its own right

Added to the brief 2026-08-19. It was missing from the five-step sequence, and
it should not have been: without a map there is no NDT, no lanelet routing and
no autonomous run.

## What we have

**The maps come from Turing Drive** — both halves:

- a **point cloud map** (PCD), for NDT scan matching
- a **lanelet2 vector map** (`.osm`), for routing and planning

In the repo, `data/ntu-campus-merged/` holds exactly that shape:

```
pointcloud_map.pcd
lanelet2_map.osm
map_projector_info.yaml
```

`data/ntu-campus-planning/` holds the per-run material (`r01`).

That the maps are supplied rather than surveyed by us is worth saying plainly on
a slide. It is a dependency, and it is one more thing the vendor relationship
carries besides the VCU.

## What we do to them

**The PCD is downsampled at runtime**, for two reasons the team gave together:

1. **NDT runs faster** on a coarser map.
2. **The map loads faster**, which matters on every single launch.

Both are the same argument as the startup governor and the camera conversion:
this hardware has no headroom to spare, so anything that can be made cheaper is.

### One thing to check before it goes on a slide

The committed `config/map/pointcloud_map_loader.param.yaml` reads:

```yaml
enable_whole_load: true
enable_downsampled_whole_load: false
enable_partial_load: true
leaf_size: 3.0   # only used when downsample_whole_load enabled
```

So the loader's own downsampling path is **off**, and the `leaf_size: 3.0` that
would apply is explicitly documented as unused while it is off. That does not
contradict the team — the downsampling may happen offline before the PCD is
committed, or through `enable_partial_load`, or the vehicle may run a different
value than what is committed here — but the slide should not claim a mechanism
until someone says which of those it is.

Worth resolving because the number is the interesting part: "we downsample the
map" is a shrug, and "we downsample it to N metres and loading went from X to Y"
is a result.

## Where it goes in the sequence

The bring-up sequence becomes **six** steps, not five:

1. Sensors
2. Two-host system
3. Vehicle interface
4. **Map preparation** ← new
5. Data collection
6. Autonomous run

Map sits before data collection because the NTU replay work already depended on
it — the merged map is what the NDT runs were scored against.

Slides 3 and 13 both enumerate the steps, so both need the extra row, and the
status chips need a sixth entry.

## Naming

**Do not mention 華夏科大 anywhere in the deck.** The work is at NTU and stays at
NTU for now. Slide 2 currently ends "The 華夏科大 campus is the destination" —
that line goes.

Note this contradicts `CLAUDE.md` and `docs/roadmaps/0-migration.md`, which both
describe the 華夏科大 campus as the production target. Those are project records
rather than slides, so they are left alone here; worth a separate decision about
whether they are now stale.
