# EECS 700 project: binary analysis with Ghidra MCP

This repo reverse-engineers binaries with headless Ghidra driven through
Claude Code, using [GhidraMCP](https://github.com/bethington/ghidra-mcp)
running in rootless Podman.

## Contents

| Path | What it is |
|---|---|
| `podman-ghidra-mcp.sh` | Builds and runs the Ghidra MCP containers and registers them with Claude Code |
| `ghidra-mcp/` | Upstream GhidraMCP source (git submodule), used to build the images |
| `getscore.c` | C code rebuilt from the `getscore` binary |

Binaries (`binaries/`) and Ghidra project databases (`ghidra-projects/`) are
not tracked.

## Setup

Requirements: Podman (rootless), the `claude` CLI, and network access during the build.

```sh
git clone --recurse-submodules <this repo>
cd eecs700-project
./podman-ghidra-mcp.sh install    # build images, start the pod, register the MCP server
```

You can also run the steps one at a time: `build`, `up`, `register`. Other
commands: `status`, `logs`, `down`. Add `--dry-run` before a command to print
what it would run without running it.

The pod has no network access (loopback only), so it is safe for untrusted
binaries. It does not start on its own after a reboot; run
`./podman-ghidra-mcp.sh up` again.

## Analyzing a binary - Claude code

1. Copy the file into `binaries/`.
2. Start Claude Code from this directory and check that `ghidra` shows as connected in `/mcp`.
3. Import the file by its **container** path, `/binaries/<name>`, not by the host path.

| Host | Container |
|---|---|
| `./binaries` | `/binaries` (read-only) |
| `./ghidra-projects` | `/projects` (read-write) |

## getscore

`getscore.c` is a C version of `binaries/getscore`, a 32-bit x86 ELF built
with GCC 3.2 that is meant to run setuid. It runs `getscore name SSN`, finds
`name:SSN:score:` in `score.txt`, and prints the score. Buffer sizes are
inferred from the stack layout.

Known vulnerabilities:

- **Stack overflow:** `get_score` copies `name` and `SSN` into a 128-byte
  buffer with `strcpy`/`strcat`, with no length check.
- **Command injection:** a failed lookup passes `name` and `SSN` into a shell
  command run by `system()`.
- **Unbounded copy:** the score field is copied until the next `:`, with no
  size limit.

## Analyzing a binary - Codex
TODO
