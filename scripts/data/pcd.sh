#!/usr/bin/env bash
# Point cloud maps are committed compressed (<name>.pcd.zst, zstd -19) and
# unpacked beside themselves, because the map loaders read <name>.pcd. The
# .pcd files are gitignored (data/**/*.pcd), so a shallow clone carries only
# the compressed copies.
#
#   pcd.sh unpack [--force] [FILE.pcd.zst ...]   every data/**/*.pcd.zst by default
#   pcd.sh pack   [FILE.pcd ...]                 every .pcd that already has a .zst
#   pcd.sh status
#
# unpack writes <name>.pcd when it is missing or older than the .zst (a pull
# brought a new map). A .pcd newer than its .zst that differs from it is a local
# edit: it is kept, and reported, unless --force.
#
# pack writes <name>.pcd.zst when it is missing or no longer decompresses to the
# .pcd. Single-threaded zstd -19 is deterministic, so packing an unchanged map
# rewrites nothing and leaves git clean. Every committed change adds the whole
# compressed size to history: pack a map only when it really changed.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
LEVEL=19

need_zstd() {
    command -v zstd >/dev/null || { echo "zstd not found: sudo apt install zstd" >&2; exit 1; }
}

same() {   # same FILE.pcd.zst FILE.pcd -> 0 if the .zst decompresses to the .pcd
    [[ -f "$1" && -f "$2" ]] && zstd -dq -c -- "$1" | cmp -s - "$2"
}

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"; }

all_zst() { find data -name '*.pcd.zst' -not -path 'data/autoware_data/*' | sort; }

cmd_unpack() {
    need_zstd
    local force=0 files=() rc=0
    for a in "$@"; do [[ "$a" == --force ]] && force=1 || files+=("$a"); done
    [[ ${#files[@]} -gt 0 ]] || mapfile -t files < <(all_zst)
    [[ ${#files[@]} -gt 0 ]] || { echo "no .pcd.zst under data/"; return 0; }
    for z in "${files[@]}"; do
        [[ "$z" == *.pcd.zst && -f "$z" ]] || { echo "  skip      $z: not a .pcd.zst"; rc=1; continue; }
        local p="${z%.zst}"
        if [[ -f "$p" && $force -eq 0 ]]; then
            if [[ ! "$z" -nt "$p" ]]; then
                if same "$z" "$p"; then echo "  ok        $p"
                else echo "  KEPT      $p: newer than its .zst and different (local edit?); 'just data pack $p' to save it, or unpack --force"; fi
                continue
            fi
            if same "$z" "$p"; then touch -r "$z" "$p"; echo "  ok        $p"; continue; fi
        fi
        local tmp="$p.tmp.$$"
        if zstd -dq -f -o "$tmp" -- "$z"; then
            mv -f -- "$tmp" "$p" && touch -r "$z" "$p"
            echo "  unpacked  $p ($(human "$(stat -c%s "$p")"))"
        else
            rm -f -- "$tmp"; echo "  FAILED    $z does not decompress"; rc=1
        fi
    done
    return $rc
}

cmd_pack() {
    need_zstd
    local files=() rc=0
    if [[ $# -gt 0 ]]; then files=("$@")
    else mapfile -t files < <(all_zst | sed 's/\.zst$//'); fi
    for p in "${files[@]}"; do
        [[ "$p" == *.pcd && -f "$p" ]] || { echo "  skip      $p: not a .pcd file"; rc=1; continue; }
        local z="$p.zst"
        if same "$z" "$p"; then echo "  unchanged $z"; continue; fi
        local tmp="$z.tmp.$$"
        if zstd -"$LEVEL" -q --no-progress --single-thread -f -o "$tmp" -- "$p" && same "$tmp" "$p"; then
            mv -f -- "$tmp" "$z" && touch -r "$z" "$p"
            echo "  packed    $z ($(human "$(stat -c%s "$p")") -> $(human "$(stat -c%s "$z")")); commit it"
        else
            rm -f -- "$tmp"; echo "  FAILED    $p"; rc=1
        fi
    done
    return $rc
}

cmd_status() {
    local z p state
    while read -r z; do
        p="${z%.zst}"
        if [[ ! -f "$p" ]]; then state="NOT UNPACKED"
        elif same "$z" "$p"; then state="ok"
        else state="DIFFERS (unpack or pack)"; fi
        printf '  %-14s %s (%s)\n' "$state" "$z" "$(human "$(stat -c%s "$z")")"
    done < <(all_zst)
}

case "${1:-}" in
    unpack) shift; cmd_unpack "$@" ;;
    pack)   shift; cmd_pack "$@" ;;
    status) shift; cmd_status ;;
    *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
