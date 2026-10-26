#!/bin/sh
# Scan a spread of Apache httpd versions with nuclei.
#
# For each version it builds the apache2-study image (via fetch.sh), runs it on a
# private podman network with no published port, and scans it from an official nuclei
# container on that same network. The container is reachable only from the network, so
# nuclei's loopback is its own and the host's services are never touched.
#
# Portable: templates and the nuclei image come from projectdiscovery, not the host's
# home directory. Templates download once into a podman volume and are reused.
#
# Usage: ./scan.sh [version ...]
#   With no arguments, scans 10 versions spread from 2.4.9 to the current release.
#   Reports land in reports/<version>.txt.
set -eu

# 10 versions spread across the range fetch.sh offers (2.4.9 .. 2.4.69).
# (2.4.53, not 2.4.54: the usr-merge-transition builds ~2.4.54..2.4.58 fail in a rootless
# container — usrmerge's postinst can't convert the unmerged bullseye base.)
DEFAULT_VERSIONS="2.4.9 2.4.16 2.4.23 2.4.29 2.4.37 2.4.43 2.4.49 2.4.53 2.4.59 2.4.69"

NET=apache2-study-net
VOL=apache2-study-nuclei-templates
NUCLEI_IMAGE=docker.io/projectdiscovery/nuclei:latest

cd "$(dirname "$0")"
versions=${*:-$DEFAULT_VERSIONS}
mkdir -p reports

cleanup() {
    [ -n "${container:-}" ] && podman rm -f "$container" >/dev/null 2>&1 || true
    podman network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

podman network create "$NET" >/dev/null 2>&1 || true

# Download templates once into the volume; reused (and refreshed) on every run.
echo "==> updating nuclei templates (podman volume $VOL)"
podman volume create "$VOL" >/dev/null 2>&1 || true
podman run --rm -v "$VOL":/root/nuclei-templates:Z "$NUCLEI_IMAGE" -update-templates

failed=
for v in $versions; do
    container="apache2-study-$(echo "$v" | tr '.' '-')"   # dots -> dashes for a clean DNS name
    report="reports/$v.txt"
    echo
    echo "==> $v"

    # One version failing to build (e.g. the usrmerge transition ~2.4.54) must not abort
    # the batch: record it and move on.
    echo "    building localhost/apache2-study:$v"
    if ! ./fetch.sh image "$v" >/dev/null; then
        echo "    BUILD FAILED — skipping (diagnose with: ./fetch.sh image $v)"
        failed="$failed $v"
        continue
    fi

    podman rm -f "$container" >/dev/null 2>&1 || true
    if ! podman run -d --rm --name "$container" --network "$NET" "localhost/apache2-study:$v" >/dev/null; then
        echo "    RUN FAILED — skipping"
        failed="$failed $v"
        continue
    fi
    sleep 2

    # Target the container's IP, not its name: under a full-template scan's concurrency,
    # rootless podman's DNS resolution flakes and nuclei permanently drops the target
    # ("no address found for host"), silently yielding 0 findings. The scanner shares the
    # network, so it can reach the IP directly (the host cannot, in rootless mode).
    ip=$(podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container")

    echo "    scanning http://$ip -> $report"
    podman run --rm --network "$NET" \
        -v "$VOL":/root/nuclei-templates:Z \
        -v ./reports:/reports:Z \
        "$NUCLEI_IMAGE" \
        -u "http://$ip" -o "/reports/$v.txt" \
        -duc -ni -timeout 5 -retries 0 || true
        # -ni: no interactsh. The container has no outbound network, so OAST callbacks
        #   can never arrive; without this nuclei polls the interactsh server at the end
        #   and the scan hangs for minutes after the last HTTP finding.
        # -timeout 5 / -retries 0: the target is a container on the same network (sub-ms
        #   responses), so trim the waits non-HTTP templates spend on closed service ports.

    podman stop "$container" >/dev/null 2>&1 || true
    container=
    hits=$( [ -f "$report" ] && wc -l < "$report" || echo 0 )
    echo "    $hits findings"
done

echo
echo "==> done. Reports in reports/"
if [ -n "$failed" ]; then
    echo "==> versions that could not be built/scanned:$failed"
fi
