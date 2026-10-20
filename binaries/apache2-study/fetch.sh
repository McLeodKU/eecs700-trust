#!/usr/bin/env bash
# fetch.sh — collect Debian's prebuilt Apache httpd binaries, their runtime dependencies,
# and debug symbols, for any apache2 version Debian ever shipped (snapshot.debian.org).
#
# For each version:
#   1. Pick the Debian revision: the newest upload of that upstream version to unstable
#      (e.g. 2.4.9 -> 2.4.9-2), or the exact Debian version if one is given.
#   2. Find when its amd64 apache2-bin first appeared in the archive, and point apt at
#      unstable *as of that moment* (snapshot.debian.org/archive/debian/<timestamp>/).
#   3. In a buildah container, run apt with an empty package database and
#      --download-only, so it resolves and downloads apache2-bin plus the full closure
#      of its runtime dependencies as they were then.
#   4. Download the debug package (apache2-dbg for older versions, apache2-bin-dbgsym for
#      newer ones) by its SHA-1 from the snapshot API.
#   5. Extract every .deb into one rootfs.
#
# Output, per version (directory named by upstream version):
#   build/<ver>/rootfs/    usr/sbin/apache2, usr/lib/apache2/modules/*.so, the shared
#                          libraries they link against, and usr/lib/debug/... symbols
#   build/<ver>/debs/      the .deb files as downloaded
#   build/<ver>/MANIFEST   Debian version, snapshot timestamp, every package and version
#
# Usage:
#   ./fetch.sh [options] VERSION...   e.g. ./fetch.sh 2.4.9 2.4.49 2.4.50  or  ./fetch.sh 2.4.9-1
#   ./fetch.sh list                   upstream versions available and the revision each maps to
#   ./fetch.sh image VERSION...       build a runnable image from ./Containerfile (see there):
#                                     localhost/apache2-study:<ver>, on the Debian release that
#                                     was stable when that build appeared
#   ./fetch.sh clean                  remove ./build, the images and leftover containers
#
# Options:
#   --dry-run       print commands without running them
#   --no-dbg        skip the debug-symbol package
#   --pkgs "A B"    binary packages to fetch (default: "apache2-bin"; e.g. "apache2 apache2-utils"
#                   for the config files and support tools too)
#
# apt fetches the old indices over HTTPS from snapshot.debian.org with trusted=yes: the
# archive's old signing keys are expired and use SHA-1, which current apt rejects.
# Packages are still checked against the hashes in those indices.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/build}"

SNAPSHOT="https://snapshot.debian.org"
ARCH="amd64"
TOOLS_FROM="docker.io/library/debian:bookworm-slim"
TOOLS_IMAGE="localhost/apache2-study-tools:latest"
IMAGE="localhost/apache2-study"
CTR_PREFIX="apache2-study-fetch"

DRY_RUN=0
WITH_DBG=1
PKGS="apache2-bin"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { printf '  $ %s\n' "$*"; [[ $DRY_RUN -eq 1 ]] || "$@"; }

command -v buildah >/dev/null || die "buildah is not installed"
command -v python3 >/dev/null || die "python3 is not installed"

# ---------------------------------------------------------------------------
# snapshot.debian.org lookups

# snap MODE ARG...: query the snapshot API.
#   snap list                -> "<upstream> <debian version>" for every unstable upload of apache2-bin
#   snap resolve VERSION     -> "<debian version> <timestamp> <dbg package> <dbg sha1>"
#                               (dbg fields are "-" if there is no debug package)
snap() {
    python3 -I - "$SNAPSHOT/mr" "$ARCH" "$@" <<'EOF'
import json, sys, urllib.request

api, arch, mode, *args = sys.argv[1:]

def get(path):
    with urllib.request.urlopen(api + path, timeout=60) as r:
        return json.load(r)["result"]

def fileinfo(binary, source_ver, bin_ver):
    url = f"/package/apache2/{source_ver}/binfiles/{binary}/{bin_ver}?fileinfo=1"
    with urllib.request.urlopen(api + url, timeout=60) as r:
        data = json.load(r)
    hits = []
    for sha1, infos in data["fileinfo"].items():
        for i in infos:
            if i["name"].endswith(f"_{arch}.deb") and i["archive_name"] in ("debian", "debian-debug"):
                hits.append((i["first_seen"], sha1))
    return min(hits) if hits else None

# Binary versions of apache2-bin, with the source version each was built from.
# Uploads to unstable only: stable updates (+debNuM, ~debNuM) and backports (~bpo) are skipped.
bins = [(r["binary_version"], r["version"]) for r in get("/binary/apache2-bin/")]
unstable = [(b, s) for b, s in bins if "~" not in b and "+deb" not in b]

def upstream(v):
    return v.rsplit("-", 1)[0].split(":")[-1]

if mode == "list":
    for b, s in unstable:
        print(upstream(b), b)
    sys.exit(0)

want = args[0]
if "-" in want:
    cands = [(b, s) for b, s in bins if b == want]
else:
    cands = [(b, s) for b, s in unstable if upstream(b) == want]
if not cands:
    sys.exit(f"no apache2-bin {want} on snapshot.debian.org (try: ./fetch.sh list)")

# Newest revision = the one whose amd64 build appeared last.
best = None
for b, s in cands:
    fi = fileinfo("apache2-bin", s, b)
    if fi and (best is None or fi[0] > best[0]):
        best = (fi[0], b, s)
if best is None:
    sys.exit(f"apache2-bin {want}: no {arch} build on snapshot.debian.org")
ts, b, s = best

dbg = ("-", "-")
for name in ("apache2-dbg", "apache2-bin-dbgsym"):
    try:
        fi = fileinfo(name, s, b)
    except Exception:
        fi = None
    if fi:
        dbg = (name, fi[1])
        break
print(b, ts, *dbg)
EOF
}

# ---------------------------------------------------------------------------
# Tools image: bookworm-slim with ca-certificates (HTTPS to snapshot) and curl.

build_tools() {
    local ctr
    if buildah inspect --type image "$TOOLS_IMAGE" &>/dev/null; then return; fi
    log "Building $TOOLS_IMAGE"
    if [[ $DRY_RUN -eq 1 ]]; then ctr="<ctr>"; else ctr="$(buildah from --pull "$TOOLS_FROM")"; fi
    run buildah run "$ctr" -- sh -ec "
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl
        rm -rf /var/lib/apt/lists/*"
    run buildah commit --rm "$ctr" "$TOOLS_IMAGE"
}

# ---------------------------------------------------------------------------

fetch_version() {
    local want="$1" ver debver ts dbg dbgsha ctr out
    log "Resolving apache2 $want on snapshot.debian.org"
    read -r debver ts dbg dbgsha < <(snap resolve "$want") || die "lookup failed for $want"
    [[ -n "${debver:-}" ]] || die "lookup failed for $want"
    ver="${debver%-*}"
    out="$OUT_DIR/$ver"
    echo "  Debian version: $debver   snapshot: $ts   debug package: $dbg"
    [[ $WITH_DBG -eq 1 ]] || dbg="-"

    build_tools
    run buildah rm "$CTR_PREFIX-$ver" &>/dev/null || true
    if [[ $DRY_RUN -eq 1 ]]; then ctr="<ctr>"; else
        ctr="$(buildah from --name "$CTR_PREFIX-$ver" "$TOOLS_IMAGE")"
    fi

    local pinned="" p
    for p in $PKGS; do pinned+=" $p=$debver"; done

    log "Downloading$pinned and dependencies (unstable @ $ts)"
    # A private apt root with an empty dpkg status, so apt resolves every dependency
    # from scratch against the old index instead of against the container's own packages.
    run buildah run "$ctr" -- sh -ec "
        R=/aptroot
        mkdir -p \$R/etc/apt/apt.conf.d \$R/etc/apt/preferences.d \$R/etc/apt/sources.list.d \
                 \$R/var/lib/dpkg \$R/var/lib/apt/lists/partial \$R/var/cache/apt/archives/partial
        touch \$R/var/lib/dpkg/status
        echo 'deb [trusted=yes] $SNAPSHOT/archive/debian/$ts/ sid main' > \$R/etc/apt/sources.list
        APT=\"apt-get -q -o Dir=\$R -o Dir::State::status=\$R/var/lib/dpkg/status
             -o APT::Architecture=$ARCH -o APT::Architectures=$ARCH
             -o Acquire::Check-Valid-Until=false -o Acquire::Languages=none -o Debug::NoLocking=1\"
        \$APT update
        \$APT install -y --download-only --no-install-recommends$pinned
        mkdir -p /out/debs
        mv \$R/var/cache/apt/archives/*.deb /out/debs/"

    if [[ "$dbg" != "-" ]]; then
        log "Downloading $dbg $debver"
        run buildah run "$ctr" -- sh -ec "
            curl -fsSL -o /out/debs/${dbg}_${debver}_$ARCH.deb $SNAPSHOT/file/$dbgsha
            echo '$dbgsha  /out/debs/${dbg}_${debver}_$ARCH.deb' | sha1sum -c -"
    fi

    log "Extracting into ${out#$SCRIPT_DIR/}/rootfs"
    run buildah run "$ctr" -- sh -ec "
        mkdir -p /out/rootfs
        for d in /out/debs/*.deb; do dpkg-deb -x \"\$d\" /out/rootfs; done
        {
            echo 'requested: $want'
            echo 'debian:    $debver'
            echo 'snapshot:  $SNAPSHOT/archive/debian/$ts/ (sid)'
            echo 'arch:      $ARCH'
            echo
            for d in /out/debs/*.deb; do dpkg-deb -W --showformat='\${Package} \${Version}\\n' \"\$d\"; done \\
                | sort | awk '{ printf \"%-32s %s\\n\", \$1, \$2 }'
        } > /out/MANIFEST"

    run rm -rf "$out"
    run mkdir -p "$out"
    if [[ $DRY_RUN -eq 0 ]]; then
        buildah run "$ctr" -- tar -C /out -cf - . | tar -C "$out" -xf -
    fi
    run buildah rm "$ctr" >/dev/null
    [[ $DRY_RUN -eq 1 ]] || sed 's/^/  /' "$out/MANIFEST"
}

# ---------------------------------------------------------------------------
# Commands

cmd_list() {
    printf '  %-10s %s\n' UPSTREAM "DEBIAN REVISIONS (unstable uploads)"
    snap list | awk '{ r[$1] = r[$1] " " $2 } END { for (u in r) print u, r[u] }' \
        | sort -V | while read -r u revs; do printf '  %-10s %s\n' "$u" "$revs"; done
}

cmd_fetch() {
    local v failed=()
    [[ $# -gt 0 ]] || die "give at least one version (see: ./fetch.sh list)"
    for v in "$@"; do
        # Subshell so one failed version doesn't stop the rest. Not `( ... ) || ...`:
        # that would disable errexit inside the subshell.
        set +e
        ( set -eE; trap 'warn "apache2 $v: command failed at line $LINENO: $BASH_COMMAND"' ERR
          fetch_version "$v" )
        [[ $? -eq 0 ]] || failed+=("$v")
        set -e
    done
    echo
    [[ ${#failed[@]} -eq 0 ]] || die "failed: ${failed[*]}"
    log "Done: $*  ->  ${OUT_DIR#$SCRIPT_DIR/}/<version>/"
}

# base_for TIMESTAMP: the Debian release that was stable at that snapshot timestamp.
# Exception: squeeze and wheezy (glibc <= 2.13) segfault on kernels built with
# CONFIG_LEGACY_VSYSCALL_NONE (Debian's since 13), so anything before jessie's release
# uses jessie (glibc 2.19, the same glibc unstable had in 2014).
base_for() {
    local d="${1:0:8}"
    if   [[ $d < 20170617 ]]; then echo docker.io/debian/eol:jessie
    elif [[ $d < 20190706 ]]; then echo docker.io/debian/eol:stretch
    elif [[ $d < 20210814 ]]; then echo docker.io/debian/eol:buster
    elif [[ $d < 20230610 ]]; then echo docker.io/debian/eol:bullseye
    elif [[ $d < 20250809 ]]; then echo docker.io/library/debian:bookworm
    else                           echo docker.io/library/debian:trixie
    fi
}

image_version() {
    local want="$1" debver ts _dbg _sha ver base
    log "Resolving apache2 $want on snapshot.debian.org"
    read -r debver ts _dbg _sha < <(snap resolve "$want") || die "lookup failed for $want"
    ver="${debver%-*}"
    base="$(base_for "$ts")"
    log "Building $IMAGE:$ver  (apache2 $debver, unstable @ $ts, on $base)"
    run buildah build --pull --format docker \
        --build-arg "BASE=$base" --build-arg "SNAPSHOT=$ts" --build-arg "VERSION=$debver" \
        -t "$IMAGE:$ver" -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR/empty-context"
    echo "  Run: podman run --rm -p 8080:80 $IMAGE:$ver"
}

cmd_image() {
    local v failed=()
    [[ $# -gt 0 ]] || die "give at least one version (see: ./fetch.sh list)"
    # The Containerfile copies nothing in, so don't send ./build as build context.
    run mkdir -p "$SCRIPT_DIR/empty-context"
    for v in "$@"; do
        set +e
        ( set -eE; trap 'warn "apache2 $v: command failed at line $LINENO: $BASH_COMMAND"' ERR
          image_version "$v" )
        [[ $? -eq 0 ]] || failed+=("$v")
        set -e
    done
    run rmdir "$SCRIPT_DIR/empty-context"
    echo
    [[ ${#failed[@]} -eq 0 ]] || die "failed: ${failed[*]}"
}

cmd_clean() {
    local c
    for c in $(buildah containers --format '{{.ContainerName}}' | grep "^$CTR_PREFIX-" || true); do
        run buildah rm "$c"
    done
    for c in $(buildah images --format '{{.Name}}:{{.Tag}}' | grep "^$IMAGE:" || true); do
        run buildah rmi "$c"
    done
    run rm -rf "$OUT_DIR"
}

# ---------------------------------------------------------------------------

ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --no-dbg)  WITH_DBG=0 ;;
        --pkgs)    [[ $# -ge 2 ]] || die "--pkgs needs a value"; PKGS="$2"; shift ;;
        --pkgs=*)  PKGS="${1#*=}" ;;
        -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        -*)        die "unknown option $1" ;;
        *)         ARGS+=("$1") ;;
    esac
    shift
done

case "${ARGS[0]:-}" in
    list)  cmd_list ;;
    image) cmd_image "${ARGS[@]:1}" ;;
    clean) cmd_clean ;;
    *)     cmd_fetch "${ARGS[@]}" ;;
esac
