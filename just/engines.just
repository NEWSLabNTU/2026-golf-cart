# TensorRT engine packs, cached in plain git and keyed by host compatibility.
#
#   just engines key        # this machine's key: aw<autoware>-trt<tensorrt>-<board>
#   just engines save       # data/autoware_data/**/*.engine -> data/engines/<key>/
#   just engines install    # data/engines/<key>/ -> data/autoware_data/, where the ONNX matches
#   just engines list       # packs in the repo; which one is this host's
#   just engines verify     # installed engines against this host's pack
#
# Every recipe accepts `--data-dir DIR` (default $GOLFCART_DATA_PATH, else
# data/autoware_data), e.g. `just engines install --data-dir /tmp/x`.
#
# An engine is installed only when the ONNX beside its target hashes to the one
# the pack was built from; anything skipped is built on first launch, as
# without a pack. After `install`, `just build-engines` loads (does not rebuild)
# what is there and builds the rest.
#
# Engines are stored as <stem>.engine.zst (zstd -19, the CLI) in plain git, no
# LFS: ~9.2 MB per key today. Every save of a CHANGED engine adds its packed
# size to history for good, so save only when an engine
# really changed; a rerun on unchanged engines writes nothing.
# Design: docs/research/perception/tensorrt-engine-prebuild.md.
set working-directory := '..'

# List this module's recipes
default:
    @just --list engines

# Print this machine's pack key and the fields recorded but not keyed on
key *ARGS:
    @python3 scripts/engines/engines.py {{ARGS}} key

# Copy the engines in data/autoware_data into this key's pack, update its manifest
save *ARGS:
    @python3 scripts/engines/engines.py {{ARGS}} save

# Install this key's engines into data/autoware_data where the ONNX matches (--force replaces local ones)
install *ARGS:
    #!/usr/bin/env bash
    # --force belongs to the subcommand, --data-dir to the tool; split them.
    pre=(); post=()
    for a in {{ARGS}}; do [[ "$a" == --force ]] && post+=("$a") || pre+=("$a"); done
    exec python3 scripts/engines/engines.py "${pre[@]}" install "${post[@]}"

# Packs in the repo, their engines, and which one matches this host
list *ARGS:
    @python3 scripts/engines/engines.py {{ARGS}} list

# Check the installed engines against this host's pack (sha256)
verify *ARGS:
    @python3 scripts/engines/engines.py {{ARGS}} verify
