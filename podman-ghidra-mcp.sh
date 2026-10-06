#!/usr/bin/env bash
# podman-ghidra-mcp.sh — run GhidraMCP (bethington/ghidra-mcp) headless in rootless Podman
# and register it with Claude Code.
#
# Layout:
#   pod "ghidra-mcp"        --network none: loopback only. No internet, no host ports.
#     ghidra-mcp-server     headless Ghidra + plugin, HTTP on 127.0.0.1:8089 (pod-local)
#     (bridge, per session) Claude Code runs `podman run --rm -i --pod ghidra-mcp ...`
#                           and speaks MCP over stdio; the bridge reaches Ghidra via 127.0.0.1.
#
# Because the server binds loopback only, the plugin needs no auth token.
# Nothing in the pod can reach the network or your host, so it's safe to analyze
# untrusted binaries in it.
#
# Host directories (created if missing, next to this script):
#   ./binaries         -> /binaries  (read-only)  put the files you want to analyze here
#   ./ghidra-projects  -> /projects  (read-write) Ghidra projects persist here
#
# Usage:
#   ./podman-ghidra-mcp.sh build      Build both images from ./ghidra-mcp (downloads Ghidra + Maven deps)
#   ./podman-ghidra-mcp.sh up         Create the pod and start the server; wait until healthy
#   ./podman-ghidra-mcp.sh register   Add the 'ghidra' MCP server to Claude Code (local scope)
#   ./podman-ghidra-mcp.sh install    build + up + register
#   ./podman-ghidra-mcp.sh status|logs|down
#
# Options (before the command):  --dry-run   print commands without running them

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$SCRIPT_DIR/ghidra-mcp}"
BINARIES_DIR="${BINARIES_DIR:-$SCRIPT_DIR/binaries}"
PROJECTS_DIR="${PROJECTS_DIR:-$SCRIPT_DIR/ghidra-projects}"

POD="ghidra-mcp"
SERVER="ghidra-mcp-server"
SERVER_IMAGE="localhost/ghidra-mcp-headless:latest"
BRIDGE_IMAGE="localhost/ghidra-mcp-bridge:latest"
MCP_NAME="ghidra"
PORT=8089
MEMORY="6g"                       # container memory cap
JAVA_OPTS="-Xmx4g -XX:+UseG1GC"   # Ghidra heap; keep below MEMORY

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=1; shift; fi
CMD="${1:-}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { printf '  $ %s\n' "$*"; [[ $DRY_RUN -eq 1 ]] || "$@"; }

command -v podman >/dev/null || die "podman is not installed"

# ---------------------------------------------------------------------------
cmd_build() {
    [[ -f "$REPO_DIR/docker/Dockerfile" ]] || die "ghidra-mcp repo not found at $REPO_DIR"
    # The Dockerfiles use short names (eclipse-temurin, python), which Podman won't
    # resolve without unqualified-search-registries configured. Pull them fully
    # qualified so the build finds them in local storage instead.
    log "Pulling base images from Docker Hub"
    run podman pull docker.io/library/eclipse-temurin:21-jdk
    run podman pull docker.io/library/python:3.12-slim
    log "Building server image (downloads Ghidra 12.1.3 from GitHub + Maven deps; takes a while)"
    # --format docker keeps the Dockerfile's HEALTHCHECK (OCI format drops it).
    run podman build --format docker -f "$REPO_DIR/docker/Dockerfile" -t "$SERVER_IMAGE" "$REPO_DIR"
    log "Building bridge image"
    run podman build --format docker -f "$REPO_DIR/docker/Dockerfile.bridge" -t "$BRIDGE_IMAGE" "$REPO_DIR"
}

# ---------------------------------------------------------------------------
cmd_up() {
    podman image exists "$SERVER_IMAGE" || [[ $DRY_RUN -eq 1 ]] || die "image missing; run '$0 build' first"
    run mkdir -p "$BINARIES_DIR" "$PROJECTS_DIR"

    if podman pod exists "$POD"; then
        echo "  Pod '$POD' already exists"
    else
        log "Creating pod '$POD' (no network, your UID mapped to the container's ghidra user)"
        # keep-id: container uid 1000 (ghidra) == your host uid, so ./ghidra-projects
        # stays owned by you. The image's ghidra user is hard-coded to uid 1000.
        [[ "$(id -u)" == 1000 ]] || warn "your uid is $(id -u), not 1000; files in $PROJECTS_DIR may need chmod"
        run podman pod create --name "$POD" --network none --userns keep-id
    fi

    if podman container exists "$SERVER"; then
        log "Starting existing server container"
        run podman start "$SERVER"
    else
        log "Starting headless Ghidra server"
        run podman run -d --name "$SERVER" --pod "$POD" \
            --memory "$MEMORY" \
            --cap-drop ALL --security-opt no-new-privileges \
            -e GHIDRA_MCP_BIND_ADDRESS=127.0.0.1 \
            -e GHIDRA_MCP_PORT="$PORT" \
            -e JAVA_OPTS="$JAVA_OPTS" \
            -v "$BINARIES_DIR:/binaries:ro" \
            -v "$PROJECTS_DIR:/projects" \
            "$SERVER_IMAGE"
    fi

    [[ $DRY_RUN -eq 1 ]] && return
    log "Waiting for the server to become healthy (up to 3 min)"
    for _ in $(seq 1 90); do
        if podman exec "$SERVER" curl -sf "http://127.0.0.1:$PORT/mcp/health" >/dev/null 2>&1; then
            echo "  Healthy."
            return
        fi
        sleep 2
    done
    die "server did not become healthy; check: $0 logs"
}

# ---------------------------------------------------------------------------
cmd_register() {
    command -v claude >/dev/null || die "claude CLI not on PATH"
    log "Registering MCP server '$MCP_NAME' with Claude Code (local scope, $SCRIPT_DIR)"
    # local scope binds to the directory claude is run from.
    [[ $DRY_RUN -eq 1 ]] || cd "$SCRIPT_DIR"
    if claude mcp get "$MCP_NAME" >/dev/null 2>&1; then
        warn "An MCP server named '$MCP_NAME' already exists; replacing it"
        run claude mcp remove "$MCP_NAME" --scope local || true
    fi
    # Each Claude Code session gets its own throwaway bridge container in the pod.
    run claude mcp add --scope local "$MCP_NAME" -- \
        podman run --rm -i --pod "$POD" \
            --cap-drop ALL --security-opt no-new-privileges \
            -e GHIDRA_MCP_URL="http://127.0.0.1:$PORT" \
            "$BRIDGE_IMAGE" --transport stdio
}

# ---------------------------------------------------------------------------
cmd_status() {
    podman pod ps --filter name="^$POD\$"
    podman ps -a --pod --filter pod="$POD"
    podman exec "$SERVER" curl -sf "http://127.0.0.1:$PORT/mcp/health" && echo || echo "server not healthy"
}

cmd_down() {
    log "Stopping and removing pod '$POD' (images and ./ghidra-projects are kept)"
    run podman pod rm -f "$POD"
}

case "$CMD" in
    build)    cmd_build ;;
    up)       cmd_up ;;
    register) cmd_register ;;
    install)  cmd_build; cmd_up; cmd_register ;;
    status)   cmd_status ;;
    logs)     podman logs -f "$SERVER" ;;
    down)     cmd_down ;;
    *)        sed -n '2,27p' "$0"; exit 2 ;;
esac

if [[ "$CMD" == install || "$CMD" == up ]]; then
    cat <<EOF

Next steps:
  - Copy binaries to analyze into $BINARIES_DIR (seen as /binaries/<name> in the container).
  - In Claude Code (started from $SCRIPT_DIR), run /mcp and confirm '$MCP_NAME' is connected.
  - Ask Claude to create/open a project under /projects, then import /binaries/<name>.
  - The pod doesn't restart on reboot; run '$0 up' again.
EOF
fi
