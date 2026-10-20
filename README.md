# EECS 700 project: binary analysis with Ghidra MCP

This repo reverse-engineers binaries with headless Ghidra driven through
Claude Code, using [GhidraMCP](https://github.com/bethington/ghidra-mcp)
running in rootless Podman.

## Contents

| Path | What it is |
|---|---|
| `podman-ghidra-mcp.sh` | Builds and runs the Ghidra MCP containers and registers them with Claude Code |
| `ghidra-mcp/` | Upstream GhidraMCP source (git submodule), used to build the images |

Binaries (`binaries/`) and Ghidra project databases (`ghidra-projects/`) are
not tracked.

## Setup

Requirements: Podman (rootless), the `claude` CLI, and network access during the build.

```sh
git clone --recurse-submodules <this repo>
cd eecs700-project
./podman-ghidra-mcp.sh install    # build images, start the pod, register the MCP server
```

If you cloned without `--recurse-submodules`, `ghidra-mcp/` will be empty and
the build fails with "ghidra-mcp repo not found". Fetch it first:

```sh
git submodule update --init
```

You can also run the steps one at a time: `build`, `up`, `register`. Other
commands: `status`, `logs`, `down`. Add `--dry-run` before a command to print
what it would run without running it.

The pod has no network access (loopback only), so it is safe for untrusted
binaries. It does not start on its own after a reboot; run
`./podman-ghidra-mcp.sh up` again.

## Analyzing a binary - Claude code

1. Copy the file into `binaries/`. (Denote if obfuscation was applied or not)
2. Start Claude Code from this directory and check that `ghidra` shows as connected in `/mcp`.
3. Import the file by its **container** path, `/binaries/<name>`, not by the host path.

| Host | Container |
|---|---|
| `./binaries` | `/binaries` (read-only) |
| `./ghidra-projects` | `/projects` (read-write) |

## Analyzing a binary - Codex
TODO

## Dataset of vulnerable programs
TODO - using exploitdb
