#!/usr/bin/env bash

# You shouldn't really need to run this yourself, but it's here if you
# want to.

# It takes in a directory and analyzes each C file in it. Note how
# it doesn't use podman. This script is meant to be called through 
# oneShot.sh (tentative filename)


# You can specify a source directory, so you can use it on the decompiled
# binaries too. 


set -euo pipefail

SRC_DIR="${1:-src}"
[[ -d "$SRC_DIR" ]] || { echo "ERROR: not a directory: $SRC_DIR" >&2; exit 1; }

# The -i is just for the fgets and fscanf test cases. As for the others,
# a little superfluous input never hurt anybody.
for file in "$SRC_DIR"/*.c; do
    ./check.sh -i 12 "$file"
done