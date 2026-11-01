#!/bin/sh
# Scan a spread of MariaDB versions (each paired with its era's Apache base) with nuclei.
#
# For each version it builds a MariaDB image FROM the matching apache2-study image, runs it
# on a private podman network with no published port, and scans it from the official nuclei
# container on that same network. The database is reachable only from the network, so the
# host's own services are never touched.
#
# Unlike apache2-study/php-study (HTTP), the target here is a TCP database on port 3306, so
# the scan uses nuclei's service templates (javascript/tcp/ssl) rather than the HTTP set.
#
# This reuses the apache2-study images and the shared nuclei-templates podman volume, so
# nothing depends on a nuclei install or templates in your home directory.
#
# Usage: ./scan.sh [apache-version ...]
#   With no arguments, scans the 10 apache2-study versions. The MariaDB version follows each
#   Apache version's Debian era (MariaDB 5.5 .. 11.x); reports land in reports/<version>.txt.
set -eu

# The same 10 versions as apache2-study; MariaDB follows each one's era.
DEFAULT_VERSIONS="2.4.9 2.4.16 2.4.23 2.4.29 2.4.37 2.4.43 2.4.49 2.4.53 2.4.59 2.4.69"

NET=mariadb-study-net
VOL=apache2-study-nuclei-templates
NUCLEI_IMAGE=docker.io/projectdiscovery/nuclei:latest
APACHE_IMAGE=localhost/apache2-study
MDB_IMAGE=localhost/mariadb-study
APACHE_DIR=../apache2-study

cd "$(dirname "$0")"
versions=${*:-$DEFAULT_VERSIONS}
mkdir -p reports

ctx=
container=
cleanup() {
    [ -n "$container" ] && podman rm -f "$container" >/dev/null 2>&1 || true
    [ -n "$ctx" ] && rm -rf "$ctx" || true
    podman network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

podman network create "$NET" >/dev/null 2>&1 || true

echo "==> updating nuclei templates (podman volume $VOL)"
podman volume create "$VOL" >/dev/null 2>&1 || true
podman run --rm -v "$VOL":/root/nuclei-templates:Z "$NUCLEI_IMAGE" -update-templates

failed=
for v in $versions; do
    container="mariadb-study-$(echo "$v" | tr '.' '-')"   # dots -> dashes for a clean DNS name
    report="reports/$v.txt"
    echo
    echo "==> $v"

    # Reuse the apache2-study image; build it only if it isn't already present.
    if ! podman image exists "$APACHE_IMAGE:$v"; then
        echo "    base $APACHE_IMAGE:$v missing — building via $APACHE_DIR/fetch.sh"
        if ! "$APACHE_DIR/fetch.sh" image "$v" >/dev/null; then
            echo "    BASE BUILD FAILED — skipping"
            failed="$failed $v"; continue
        fi
    fi

    # Layer the era's MariaDB on top. Unique context dir so concurrent runs don't clobber
    # each other. A build failure skips this version, not the batch.
    echo "    building $MDB_IMAGE:$v"
    ctx="$(mktemp -d "$PWD/.build-context.XXXXXX")"
    if ! podman build --format docker --build-arg "APACHE_IMAGE=$APACHE_IMAGE:$v" \
            -f Containerfile -t "$MDB_IMAGE:$v" "$ctx" >/dev/null; then
        echo "    MARIADB BUILD FAILED — skipping (diagnose: APACHE_IMAGE=$APACHE_IMAGE:$v)"
        rm -rf "$ctx"; ctx=; failed="$failed $v"; continue
    fi
    rm -rf "$ctx"; ctx=

    dbver=$(podman run --rm --entrypoint cat "$MDB_IMAGE:$v" /etc/mariadb-study-version 2>/dev/null || echo '?')

    podman rm -f "$container" >/dev/null 2>&1 || true
    if ! podman run -d --rm --name "$container" --network "$NET" "$MDB_IMAGE:$v" >/dev/null; then
        echo "    RUN FAILED — skipping"
        failed="$failed $v"; continue
    fi
    sleep 6   # let the database finish starting before the scan connects

    # Target the container's IP, not its name: under load rootless podman's DNS resolution
    # flakes and nuclei permanently drops the target. The scanner shares the network, so it
    # can reach the IP directly (the host cannot, in rootless mode). No http:// scheme — the
    # target is a database, scanned by nuclei's service templates.
    ip=$(podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container")

    echo "    scanning $ip:3306  (Apache $v + MariaDB $dbver) -> $report"
    podman run --rm --network "$NET" \
        -v "$VOL":/root/nuclei-templates:Z \
        -v ./reports:/reports:Z \
        "$NUCLEI_IMAGE" \
        -u "$ip" -o "/reports/$v.txt" \
        -pt javascript,tcp,ssl -duc -ni -nmhe -timeout 5 -retries 0 || true
        # -pt javascript,tcp,ssl: only service templates — the target has no web server, so
        #   the HTTP set would all fail (and, without -nmhe, trip the host-error limit and
        #   make nuclei skip the host before the MySQL templates run).
        # -nmhe: never skip the host on errors. -ni: no interactsh (no outbound network).
        # -timeout 5 / -retries 0: the target is a container on the same network.

    podman stop "$container" >/dev/null 2>&1 || true
    container=
    hits=$( [ -f "$report" ] && wc -l < "$report" || echo 0 )
    echo "    MariaDB $dbver — $hits findings"
done

echo
echo "==> done. Reports in reports/"
if [ -n "$failed" ]; then
    echo "==> versions that could not be built/scanned:$failed"
fi
