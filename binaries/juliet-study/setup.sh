#!/usr/bin/env bash

#RUN THIS TO CREATE YOUR PODMAN IMAGE AND YOUR JULIET BINARIES


set -euo pipefail

# This creates the image.
buildah build -t localhost/juliet-study .

# Go go gadget Claude slop build script.
# runs it on the image created in the last command.
podman run --rm --network none -v "$PWD":/work:Z -w /work \
    localhost/juliet-study ./build.sh

