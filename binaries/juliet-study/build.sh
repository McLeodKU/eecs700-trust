#!/usr/bin/env bash
# build.sh — compile Juliet test cases into the stripped, bad-only binaries the LLM decompiles.
#
# Layout (relative to this script):
#   src/       the Juliet test case .c files
#   support/   Juliet's testcasesupport/ (io.c, std_testcase.h, std_testcase_io.h, ...)
#   bin/       output: one binary per test case, plus MANIFEST
#
# Each binary is the bad() path only (-DOMITGOOD), at -O0, with symbols stripped so the
# Juliet function names don't give the CWE away. Ubuntu's hardening defaults are turned
# off: _FORTIFY_SOURCE would turn memcpy/snprintf into __*_chk calls that abort, and the
# stack protector adds canary checks; both change what the decompiled code looks like.
#
# Usage:
#   ./build.sh            build every src/*.c
#   ./build.sh FILE...    build only these

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
SUPPORT_DIR="$SCRIPT_DIR/support"
BIN_DIR="$SCRIPT_DIR/bin"

CC="${CC:-gcc}"
CFLAGS=(-O0 -U_FORTIFY_SOURCE -fno-stack-protector -w -DINCLUDEMAIN -DOMITGOOD)

die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v "$CC" >/dev/null || die "$CC is not installed"
[[ -f "$SUPPORT_DIR/io.c" && -f "$SUPPORT_DIR/std_testcase.h" ]] \
    || die "Juliet support files not found in support/ (need testcasesupport/ from the suite)"

if [[ $# -gt 0 ]]; then srcs=("$@"); else srcs=("$SRC_DIR"/*.c); fi
[[ -e "${srcs[0]}" ]] || die "no .c files in src/"

mkdir -p "$BIN_DIR"
{
    echo "compiler: $("$CC" --version | head -1)"
    echo "flags:    ${CFLAGS[*]}  + strip"
    echo
} > "$BIN_DIR/MANIFEST"

failed=()
for src in "${srcs[@]}"; do
    name="$(basename "$src" .c)"
    out="$BIN_DIR/$name"
    if "$CC" "${CFLAGS[@]}" -I "$SUPPORT_DIR" -o "$out" "$src" "$SUPPORT_DIR/io.c"; then
        strip "$out"
        printf '  ok    %s\n' "$name"
        printf '%s  %s\n' "$(sha256sum "$out" | cut -d' ' -f1)" "$name" >> "$BIN_DIR/MANIFEST"
    else
        printf '  FAIL  %s\n' "$name"
        failed+=("$name")
    fi
done

echo
[[ ${#failed[@]} -eq 0 ]] || die "failed: ${failed[*]}"
echo "Built ${#srcs[@]} binaries in ${BIN_DIR#$SCRIPT_DIR/}/"
