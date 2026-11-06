#!/usr/bin/env bash

# RUN THIS TO SCAN ALL SOURCES IN A DIRECTORY.
# You can specify a source directory, so you can use it on the decompiled
# binaries too. 


set -euo pipefail

SRC_DIR="${1:-src}"
[[ -d "$SRC_DIR" ]] || { echo "ERROR: not a directory: $SRC_DIR" >&2; exit 1; }

podman run --rm --network none --cap-add SYS_PTRACE -v "$PWD":/work:Z -w /work \
    localhost/juliet-study bash analysis.sh "$SRC_DIR"