# Map data committed compressed: <map>/pointcloud_map.pcd.zst in git, the .pcd
# unpacked beside it (gitignored) because the map loaders read the .pcd.
#
#   just data unpack            # after a clone or a pull that brought a map
#   just data pack [FILE.pcd]   # after editing a map, then commit the .pcd.zst
#   just data status
#
# A shallow clone (git clone --depth 1) then carries only the compressed maps.
set working-directory := '..'

# List this module's recipes
default:
    @just --list data

# Decompress every data/**/*.pcd.zst whose .pcd is missing or stale (--force overwrites local edits)
unpack *ARGS:
    @scripts/data/pcd.sh unpack {{ARGS}}

# Compress changed maps to .pcd.zst (zstd -19): every map with a .zst, or the FILE.pcd given
pack *ARGS:
    @scripts/data/pcd.sh pack {{ARGS}}

# Which maps are unpacked, stale or edited
status:
    @scripts/data/pcd.sh status
