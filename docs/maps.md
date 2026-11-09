# Maps

Maps live under `data/`. Choose one with `map_path:=` (see
[operating.md](operating.md#choosing-the-map)). Some are in the git repository
(compressed, see [Preparing map data](#preparing-map-data)); the NTU campus
maps are downloaded.

| map | directory |
|---|---|
| COSS practice map (default) | `data/COSS-map-planning` |
| NTU campus, per route | `data/ntu-campus-planning/r01`, `r02`, ... |
| basement (indoor) | `data/basement-indoor` |
| Ming-Da basement (indoor) | `data/mingda-basement` |

The 華夏科大 campus map is planned and does not exist yet.

## Preparing map data

Point clouds are committed compressed, as `pointcloud_map.pcd.zst` (zstd -19),
so a shallow clone (`git clone --depth 1`) stays small. Autoware reads
`pointcloud_map.pcd`, so unpack them once after cloning, and again after a pull
that changes a map:

```bash
just data unpack     # writes pointcloud_map.pcd beside every .pcd.zst under data/
just data status     # ok / NOT UNPACKED / DIFFERS, per map
```

`./setup.sh` does the first unpack for you (step `map-data`). The `.pcd` files
are gitignored. Without them a launch fails to load the map.

| map in git | compressed | unpacked |
|---|---|---|
| `data/COSS-map-planning` | 24.0 MB | 78.3 MB |
| `data/mingda-basement` | 45.5 MB | 63.9 MB |
| `data/sample-map-planning` | 14.5 MB | 28.1 MB |

`unpack` never overwrites a `.pcd` you edited (one newer than its `.zst` and
different from it); it reports it as `KEPT`. `just data unpack --force` throws
the edit away.

### Changing a map that is in git

Edit or replace `pointcloud_map.pcd`, then pack it and commit the `.zst`:

```bash
just data pack data/mingda-basement/pointcloud_map.pcd
git add data/mingda-basement/pointcloud_map.pcd.zst
```

`just data pack` with no argument repacks every map whose `.pcd` changed and
leaves unchanged ones alone (the output is byte-for-byte reproducible, so git
stays clean). Each committed change stores the whole compressed file in git
history again, so commit a map when it really changed, not every experiment.

### Adding a new map to git

Put the three files in `data/<name>/` (layout below), then
`just data pack data/<name>/pointcloud_map.pcd` and commit
`pointcloud_map.pcd.zst` with the `.osm` and `.yaml` files, never the `.pcd`.

## Download

Download the NTU campus map into `data/ntu-campus-planning/`:
https://newslabn.csie.ntu.edu.tw/drive/d/s/17udXr7jE0y1uVZuITDKMHFdhprfnH8l/y7cT2BSRT_5RUSI5bp4blXm8MI8qlp-3-iLCA3n5hIg0

Downloaded maps are not in git: copy them to both machines' `data/`
directories if you use them on both.

## Directory layout

Every map is one directory holding exactly these three files, with these exact
names. Autoware looks them up by name, so a renamed file (`map.osm`,
`pointcloud_map.pcd.pcd`) is not found:

```
data/
└── ntu-campus-planning/
    ├── r01/                          # route 01
    │   ├── lanelet2_map.osm          # Lanelet2 vector map (lanes, routes)
    │   ├── map_projector_info.yaml   # how map coordinates relate to lat/lon
    │   └── pointcloud_map.pcd        # point cloud, for NDT localization
    └── r02/                          # route 02, same three files
        ├── lanelet2_map.osm
        ├── map_projector_info.yaml
        └── pointcloud_map.pcd
```

Do not add an extra folder level. After unzipping, the files must sit directly in
`r02/`, not in `r02/r02/` or `r02/map/`.

A map may hold a second lane file, such as `lanelet2_map_loop.osm` in
`data/mingda-basement`. Select it with `lanelet2_map_file:=lanelet2_map_loop.osm`
(the `@mingda-loop` argument file does this).

## Checking a new map

Example: you have just put a new route at `data/ntu-campus-planning/r03`.

**1. All three files are there and not empty:**

```bash
MAP=data/ntu-campus-planning/r03
for f in lanelet2_map.osm map_projector_info.yaml pointcloud_map.pcd; do
  [ -s "$MAP/$f" ] && echo "ok       $f" || echo "MISSING  $f"
done
```

A correct map prints three `ok` lines:

```
ok       lanelet2_map.osm
ok       map_projector_info.yaml
ok       pointcloud_map.pcd
```

**2. The files have the right contents.** Each one starts like this (values
differ per map):

```bash
cat $MAP/map_projector_info.yaml
# projector_type: MGRS
# mgrs_grid: 51RUH           <- NTU campus is in grid 51RUH
# vertical_datum: WGS84

head -3 $MAP/lanelet2_map.osm
# <?xml version="1.0" encoding="UTF-8"?>
# <osm generator="VMB">
#   <MetaInfo format_version="1" map_version="4" validation_version="1"/>

grep -a -m3 -E '^(FIELDS|POINTS|DATA)' $MAP/pointcloud_map.pcd
# FIELDS x y z intensity
# POINTS 2493616
# DATA binary
```

**3. Autoware loads it.** Start the planning simulator on it:

```bash
just sim planning map_path:=./data/ntu-campus-planning/r03
```

The map loaded if RViz shows the point cloud and the lanes. Node output goes to
`play_log/`, not the terminal; the map loader's log should say:

```bash
grep lanelet2_map_loader "$(ls -td play_log/*/ | head -1)"node/map_container/err
# [map.lanelet2_map_loader]: Succeeded to load lanelet2_map. Map is published.
```

Once it loads here, use the same path on the cart:

```bash
just up map_path:=./data/ntu-campus-planning/r03
```

To use saved start spots on a new map, see
[operating.md](operating.md#saved-start-spots).
