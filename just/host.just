# Host configuration kept in the repo: setup/host/ (manifest.yaml + a tree
# mirroring /etc). The manifest is an allow-list; nothing else is ever read
# into the repo. Restoring is the setup step `host-config`.
#
# Recipes here run from the REPO ROOT, not from just/.
set working-directory := '..'

hostcfg := "python3 setup/golfcart_setup/hostcfg.py"

# just runs a module's FIRST recipe when the module is named with no recipe,
# so `default` has to come first and has to be the harmless one.
# List this module's recipes
default:
    @just --list host

# This host (config/host role) against the repo: identical / differs / missing. --orin: the orin over ssh, read only
diff *args:
    {{hostcfg}} diff {{args}}

# The orin's live files against THIS checkout's tree, read only over ssh
diff-orin *args:
    {{hostcfg}} diff --orin {{args}}

# Live -> repo for this role's manifest entries (secrets stripped). Optional TARGET paths; --orin reads the orin
capture *args:
    {{hostcfg}} capture {{args}}

# Repo -> live for this role (the host-config setup step; asks for sudo)
restore:
    ./setup.sh --run --only host-config -y

# Every tracked file: roles, mode, owner, target
list:
    {{hostcfg}} list

# Validate the manifest and grep setup/host for anything that looks like a secret
scan:
    {{hostcfg}} scan
