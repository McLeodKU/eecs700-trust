#!/usr/bin/env bash
#WARNING: CLAUDE SLOP

# check.sh — check one C source file (original Juliet or LLM-decompiled) for memory bugs
# with the Clang Static Analyzer and AddressSanitizer, and write both results to one report.
#
#   1. Static:  clang --analyze, the analyzer scan-build runs, with text output instead of
#               HTML. Default checkers (use-after-free, double free, NULL dereference, ...)
#               plus the array-bounds and string-function checkers, which are off by default.
#   2. Dynamic: compile with -fsanitize=address at -O0, run once with the given stdin, and
#               record what ASan reports. ASan only sees the path that actually runs, so for
#               a test case that reads stdin, pass an input that reaches the bug (-i 10).
#
# A file that includes "std_testcase.h" is treated as a Juliet test case: it is built with
# support/ and -DINCLUDEMAIN -DOMITGOOD, like build.sh. Anything else is built on its own;
# pass --support if a decompiled file calls Juliet's printLine() etc. without defining them.
#
# Usage:
#   ./check.sh [options] FILE.c
#
# Options:
#   -i TEXT      stdin for the ASan run (a newline is added); default: empty stdin
#   -o REPORT    report path (default: reports/<file name>.txt)
#   --support    link Juliet's support/io.c even if the file doesn't include std_testcase.h
#   --timeout N  seconds before the ASan run is killed (default: 10)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT_DIR="$SCRIPT_DIR/support"

CC="${CC:-clang}"
ANALYZER="${ANALYZER:-clang}"
# Off-by-default checkers relevant to memory bugs. Names differ between clang versions,
# so only the ones this clang knows are enabled.
EXTRA_CHECKERS=(
    security.ArrayBound alpha.security.ArrayBoundV2 alpha.security.ReturnPtrRange
    alpha.unix.cstring.OutOfBounds alpha.unix.cstring.BufferOverlap
    alpha.unix.cstring.NotNullTerminated alpha.unix.cstring.UninitializedRead
)

die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

INPUT="" HAVE_INPUT=0 REPORT="" FORCE_SUPPORT=0 TIMEOUT=10 FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i)        [[ $# -ge 2 ]] || die "-i needs a value"; INPUT="$2"; HAVE_INPUT=1; shift ;;
        -o)        [[ $# -ge 2 ]] || die "-o needs a value"; REPORT="$2"; shift ;;
        --support) FORCE_SUPPORT=1 ;;
        --timeout) [[ $# -ge 2 ]] || die "--timeout needs a value"; TIMEOUT="$2"; shift ;;
        -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        -*)        die "unknown option $1" ;;
        *)         [[ -z "$FILE" ]] || die "give one file"; FILE="$1" ;;
    esac
    shift
done
[[ -n "$FILE" ]] || die "usage: ./check.sh [options] FILE.c"
[[ -f "$FILE" ]] || die "not found: $FILE"
command -v "$ANALYZER" >/dev/null || die "clang is not installed (sudo apt install clang clang-tools)"
command -v "$CC" >/dev/null || die "$CC is not installed"

name="$(basename "$FILE" .c)"
REPORT="${REPORT:-$SCRIPT_DIR/reports/$name.txt}"
mkdir -p "$(dirname "$REPORT")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Juliet test case, or standalone?
defs=() support=()
if grep -q '#include *"std_testcase.h"' "$FILE" || [[ $FORCE_SUPPORT -eq 1 ]]; then
    [[ -f "$SUPPORT_DIR/io.c" ]] || die "Juliet support files not found in support/"
    defs=(-I "$SUPPORT_DIR" -DINCLUDEMAIN -DOMITGOOD)
    support=("$SUPPORT_DIR/io.c")
fi

# --- 1. Static analysis ------------------------------------------------------
known="$("$ANALYZER" -cc1 -analyzer-checker-help 2>/dev/null; "$ANALYZER" -cc1 -analyzer-checker-help-alpha 2>/dev/null)" || true
checkers=() enabled=()
for c in "${EXTRA_CHECKERS[@]}"; do
    if grep -qE "^ +$c( |$)" <<<"$known"; then
        checkers+=(-Xclang -analyzer-checker="$c"); enabled+=("$c")
    fi
done
# Only FILE is analyzed, not support/io.c.
set +e
"$ANALYZER" --analyze --analyzer-output text "${checkers[@]}" "${defs[@]}" \
    -o /dev/null "$FILE" > "$work/static.txt" 2>&1
static_rc=$?
set -e
static_warnings="$(grep -E ': warning: ' "$work/static.txt" | grep -v '\[-W' || true)"
static_count="$(grep -c . <<<"$static_warnings" || true)"

# --- 2. AddressSanitizer -----------------------------------------------------
set +e
"$CC" -O0 -g -fno-omit-frame-pointer -fsanitize=address -w "${defs[@]}" \
    -o "$work/asan" "$FILE" "${support[@]}" > "$work/compile.txt" 2>&1
compile_rc=$?
run_rc="-"
if [[ $compile_rc -eq 0 ]]; then
    if [[ $HAVE_INPUT -eq 1 ]]; then
        printf '%s\n' "$INPUT" | ASAN_OPTIONS=detect_leaks=1 timeout "$TIMEOUT" "$work/asan" > "$work/run.txt" 2>&1
    else
        ASAN_OPTIONS=detect_leaks=1 timeout "$TIMEOUT" "$work/asan" < /dev/null > "$work/run.txt" 2>&1
    fi
    run_rc=$?
fi
set -e

if [[ $compile_rc -ne 0 ]]; then
    asan_result="did not compile"
elif grep -q 'ERROR: AddressSanitizer' "$work/run.txt"; then
    asan_result="$(grep -m1 -oE 'ERROR: AddressSanitizer: [^ ]+' "$work/run.txt" | sed 's/^ERROR: //')"
    asan_access="$(grep -m1 -oE '^(READ|WRITE) of size [0-9]+' "$work/run.txt" || true)"
    asan_where="$(grep -m1 -E '^ *#0 ' "$work/run.txt" | sed -E 's/^ *#0 0x[0-9a-f]+ (in )?//' || true)"
    [[ -z "$asan_access" ]] || asan_result+=" ($asan_access)"
    [[ -z "$asan_where" ]] || asan_result+="  at $asan_where"
elif grep -q 'ERROR: LeakSanitizer' "$work/run.txt"; then
    asan_result="LeakSanitizer: memory leak"
elif [[ "$run_rc" == 124 ]]; then
    asan_result="no report (timed out after ${TIMEOUT}s, waiting for input?)"
else
    asan_result="no report (exit code $run_rc)"
fi

# --- Report ------------------------------------------------------------------
{
    echo "file:     $FILE"
    echo "sha256:   $(sha256sum "$FILE" | cut -d' ' -f1)"
    echo "date:     $(date -Is)"
    echo "mode:     $([[ ${#support[@]} -gt 0 ]] && echo 'Juliet (support/ linked, -DINCLUDEMAIN -DOMITGOOD)' || echo standalone)"
    if [[ $HAVE_INPUT -eq 1 ]]; then echo "stdin:    $(printf '%q' "$INPUT")"; else echo "stdin:    (empty)"; fi
    echo "analyzer: $("$ANALYZER" --version | head -1)"
    echo "asan cc:  $("$CC" --version | head -1)"
    echo
    echo "== SUMMARY =="
    echo "static:   $static_count warning(s)$([[ $static_rc -ne 0 ]] && echo "  (analyzer exit code $static_rc, see below)")"
    [[ -z "$static_warnings" ]] || sed 's/^/          /' <<<"$static_warnings"
    echo "asan:     $asan_result"
    echo
    echo "== STATIC ANALYSIS (clang --analyze) =="
    echo "extra checkers: ${enabled[*]:-(none available)}"
    echo
    cat "$work/static.txt"
    echo
    echo "== ASAN: COMPILE =="
    if [[ -s "$work/compile.txt" ]]; then cat "$work/compile.txt"; else echo "(ok)"; fi
    if [[ $compile_rc -eq 0 ]]; then
        echo
        echo "== ASAN: RUN (exit code $run_rc) =="
        cat "$work/run.txt"
    fi
} > "$REPORT"

sed -n '/^== SUMMARY ==/,/^$/p' "$REPORT"
echo "Report: $REPORT"
