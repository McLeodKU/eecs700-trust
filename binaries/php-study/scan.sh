#!/bin/sh
# Scan a spread of PHP versions (each paired with its era's Apache) with nuclei.
#
# For each version it builds a PHP image FROM the matching apache2-study image (adding the
# era's mod_php and an exposed /info.php), runs it on a private podman network with no
# published port, and scans it from the official nuclei container on that same network.
# The container is reachable only from the network, so nuclei's loopback is its own and the
# host's services are never touched.
#
# This reuses the apache2-study images and the shared nuclei-templates podman volume, so
# nothing depends on a nuclei install or templates in your home directory.
#
# Usage: ./scan.sh [apache-version ...]
#   With no arguments, scans the 10 apache2-study versions. The PHP version follows each
#   Apache version's Debian era (PHP 5.6 .. 8.4); reports land in reports/<version>.txt.
set -eu

# The same 10 versions as apache2-study; PHP follows each one's era.
DEFAULT_VERSIONS="2.4.9 2.4.16 2.4.23 2.4.29 2.4.37 2.4.43 2.4.49 2.4.53 2.4.59 2.4.69"

NET=apache2-study-net
VOL=apache2-study-nuclei-templates
NUCLEI_IMAGE=docker.io/projectdiscovery/nuclei:latest
APACHE_IMAGE=localhost/apache2-study
PHP_IMAGE=localhost/php-study
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
    container="php-study-$(echo "$v" | tr '.' '-')"   # dots -> dashes for a clean DNS name
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

    # Layer the era's PHP (mod_php + /info.php) on top. Unique context dir so concurrent
    # runs don't clobber each other. A build failure skips this version, not the batch.
    echo "    building $PHP_IMAGE:$v"
    ctx="$(mktemp -d "$PWD/.build-context.XXXXXX")"
    cp info.php "$ctx/"
    if ! podman build --format docker --build-arg "APACHE_IMAGE=$APACHE_IMAGE:$v" \
            -f Containerfile -t "$PHP_IMAGE:$v" "$ctx" >/dev/null; then
        echo "    PHP BUILD FAILED — skipping (diagnose: APACHE_IMAGE=$APACHE_IMAGE:$v)"
        rm -rf "$ctx"; ctx=; failed="$failed $v"; continue
    fi
    rm -rf "$ctx"; ctx=

    phpver=$(podman run --rm "$PHP_IMAGE:$v" cat /etc/php-study-version 2>/dev/null || echo '?')

    podman rm -f "$container" >/dev/null 2>&1 || true
    if ! podman run -d --rm --name "$container" --network "$NET" "$PHP_IMAGE:$v" >/dev/null; then
        echo "    RUN FAILED — skipping"
        failed="$failed $v"; continue
    fi
    sleep 2

    # Target the container's IP, not its name: under a full-template scan's concurrency,
    # rootless podman's DNS resolution flakes and nuclei permanently drops the target
    # ("no address found for host"), silently yielding 0 findings. The scanner shares the
    # network, so it can reach the IP directly (the host cannot, in rootless mode).
    ip=$(podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container")

    echo "    scanning http://$ip  (Apache $v + PHP $phpver) -> $report"
    podman run --rm --network "$NET" \
        -v "$VOL":/root/nuclei-templates:Z \
        -v ./reports:/reports:Z \
        "$NUCLEI_IMAGE" \
        -u "http://$ip" -o "/reports/$v.txt" \
        -duc -ni -timeout 5 -retries 0 || true
        # -ni: no interactsh. The container has no outbound network, so OAST callbacks can
        #   never arrive; without this nuclei polls the interactsh server at the end and the
        #   scan hangs for minutes after the last HTTP finding.
        # -timeout 5 / -retries 0: the target is a container on the same network (sub-ms
        #   responses), so trim the waits non-HTTP templates spend on closed service ports.

    podman stop "$container" >/dev/null 2>&1 || true
    container=
    hits=$( [ -f "$report" ] && wc -l < "$report" || echo 0 )
    echo "    PHP $phpver — $hits findings"
done

echo
echo "==> done. Reports in reports/"
if [ -n "$failed" ]; then
    echo "==> versions that could not be built/scanned:$failed"
fi
