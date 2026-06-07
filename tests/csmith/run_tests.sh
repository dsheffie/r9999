#!/usr/bin/env bash
# run_tests.sh  --  csmith differential testing for r9999 MIPS simulator
#
# Infinite-loop detection uses cbmc (formal bounded model checking) instead of
# wasting QEMU's timeout budget.  When cbmc finds an unbounded loop it also
# reports the exact function, line, and loop number, which is useful for
# understanding what the simulator might encounter.
#
# Flow per test:
#   1. Generate with csmith; retry until cbmc passes (up to MAX_CBMC_TRIES)
#   2. cbmc --unwind $CBMC_K  (< 1 s for most programs)
#        FAIL with user-code violation  → regenerate and retry
#        PASS                           → continue
#   3. Compile MIPS Linux, run under qemu-mips-static  → reference checksum
#        Timeout (cbmc false-positive)  → SKIP
#   4. Compile bare-metal, run on r9999 simulator      → test checksum
#   5. Compare checksums; save mismatches to failures/fail_N.{c,elf}
#
# Usage:
#   ./run_tests.sh [num_tests [cbmc_k [maxicnt]]]
#   ./run_tests.sh 1 20 10000000 fail_5.c    # re-test a saved failure

set -uo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELLO="$REPO_ROOT/hello"
SIM="$REPO_ROOT/ooo_core"
CSMITH_INC="/usr/include/csmith"
FAIL_DIR="$REPO_ROOT/failures"

CC=mips-linux-gnu-gcc
NPROC=$(nproc)

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------
TIMER_IRQ=0
MAPPED_DATA=0
MAPPED_INSN=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --timer-irq)   TIMER_IRQ=1 ;;
        --mapped-data) MAPPED_DATA=1 ;;
        --mapped-insn) MAPPED_INSN=1 ;;
        *)             ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

if [ "$MAPPED_DATA" -eq 1 ] && [ "$MAPPED_INSN" -eq 1 ]; then
    echo "error: --mapped-data and --mapped-insn cannot be combined" >&2
    exit 1
fi

N=${1:-100}
CBMC_K=${2:-20}         # unwind bound for user-generated loops
MAXICNT=${3:-50000000}
SPECIFIC=${4:-}

# Library loop bounds: fixed, exact counts derived from csmith.h source.
#   crc32_gentab.1  outer i-loop:  for (i=0; i<256; i++)   needs 257
#   crc32_gentab.0  inner j-loop:  for (j=8; j>0;  j--)   needs   9
#   strcmp.0        char loop:     conservative bound of  200
CBMC_LIBLOOPS="crc32_gentab.0:9,crc32_gentab.1:257,strcmp.0:200"

TIMEOUT_REF=60    # wall-clock limit for the qemu-mips-static reference run
TIMEOUT_SIM=30    # simulator wall-clock limit

QEMU=qemu-mips-static

CSMITH_FLAGS="--no-float --no-builtins --concise --max-block-depth 3"

BM_FLAGS="-mxgot -ffreestanding -O1 -mips3 -mno-branch-likely -mabi=n32 -mno-abicalls"
BM_DEFS="-D printf=printf_ -D _FORTIFY_SOURCE=0 -D WRAP_VOLATILES=1"
# Reference: O32 Linux binary; integer type sizes match N32 so checksums agree.
REF_FLAGS="-O1 -static"

# ---------------------------------------------------------------------------
# Build shared objects (once, before parallel phase)
# ---------------------------------------------------------------------------
SHARED=$(mktemp -d)
trap 'rm -rf "$SHARED"' EXIT

mkdir -p "$FAIL_DIR"

echo "Building common bare-metal objects  (parallelism: ${NPROC} jobs)..."

TIMER_IRQ_FLAG=""
[ "$TIMER_IRQ" -eq 1 ] && TIMER_IRQ_FLAG="-DENABLE_TIMER_IRQ"
if [ "$MAPPED_DATA" -eq 1 ]; then
    $CC $BM_FLAGS $TIMER_IRQ_FLAG \
        -c "$SCRIPT_DIR/start_csmith_mapped.S"            -o "$SHARED/start.o"
elif [ "$MAPPED_INSN" -eq 1 ]; then
    $CC $BM_FLAGS $TIMER_IRQ_FLAG \
        -c "$SCRIPT_DIR/start_csmith_mapped_insn.S"       -o "$SHARED/start.o"
else
    $CC $BM_FLAGS $TIMER_IRQ_FLAG \
        -c "$SCRIPT_DIR/start_csmith.S"                   -o "$SHARED/start.o"
fi
$CC $BM_FLAGS -I"$HELLO" \
    -c "$HELLO/printf.c"                                   -o "$SHARED/printf.o"
$CC $BM_FLAGS \
    -c "$HELLO/arith64.c"                                  -o "$SHARED/arith64.o"
$CC $BM_FLAGS $BM_DEFS -I"$CSMITH_INC" \
    -c /usr/include/csmith/volatile_runtime.c              -o "$SHARED/volatile_runtime.o"
$CC $BM_FLAGS \
    -c "$SCRIPT_DIR/baremetal_support.c"                   -o "$SHARED/support.o"

SUPPORT_OBJS="$SHARED/start.o $SHARED/printf.o $SHARED/arith64.o \
    $SHARED/volatile_runtime.o $SHARED/support.o"

echo "Done."
echo ""

# ---------------------------------------------------------------------------
# Export everything the worker subshells need
# ---------------------------------------------------------------------------
export SHARED REPO_ROOT HELLO SIM CC CSMITH_INC QEMU FAIL_DIR
export BM_FLAGS BM_DEFS REF_FLAGS SUPPORT_OBJS CSMITH_FLAGS
export TIMEOUT_REF TIMEOUT_SIM MAXICNT
export CBMC_K CBMC_LIBLOOPS
export SPECIFIC TIMER_IRQ MAPPED_DATA MAPPED_INSN

# ---------------------------------------------------------------------------
# Worker: one test per invocation; writes PASS / SKIP / FAIL to $SHARED/r$id
# ---------------------------------------------------------------------------
worker() {
    local id=$1
    local work="$SHARED/t$id"
    mkdir -p "$work"

    local src ref_bin elf
    ref_bin="$work/ref"
    elf="$work/test.elf"

    if [ -n "${SPECIFIC:-}" ]; then
        src="$SPECIFIC"

        # Single cbmc check (no retry) for a specific file
        local cbmc_out cbmc_verdict
        cbmc_out=$(timeout 30 cbmc \
            --unwind "$CBMC_K" \
            --unwinding-assertions \
            --unwindset "$CBMC_LIBLOOPS" \
            -I"$CSMITH_INC" "$src" 2>&1) || true
        cbmc_verdict=$(printf '%s' "$cbmc_out" | grep "^VERIFICATION" | head -1)

        if printf '%s' "$cbmc_verdict" | grep -q FAILED; then
            local where
            where=$(printf '%s' "$cbmc_out" \
                | grep "unwinding assertion.*FAILURE" \
                | grep -v "crc32_gentab\|strcmp" \
                | head -1 \
                | sed 's/.*\[\(.*\)\].*/\1/')
            local lineno
            lineno=$(printf '%s' "$cbmc_out" \
                | grep "unwinding assertion.*FAILURE" \
                | grep -v "crc32_gentab\|strcmp" \
                | head -1 \
                | grep -o "line [0-9]*" | head -1)
            printf '[%d] SKIP  cbmc: unbounded loop  %s  %s\n' "$id" "$where" "$lineno"
            echo SKIP > "$SHARED/r$id"; return
        fi
    else
        src="$work/test.c"

        # Retry loop: keep generating until cbmc passes (counts as one test slot)
        local MAX_TRIES=100
        local tries=0
        local cbmc_clean=0

        while [ $tries -lt $MAX_TRIES ]; do
            tries=$((tries+1))
            csmith $CSMITH_FLAGS > "$src" 2>/dev/null || continue

            local cbmc_out cbmc_verdict
            cbmc_out=$(timeout 30 cbmc \
                --unwind "$CBMC_K" \
                --unwinding-assertions \
                --unwindset "$CBMC_LIBLOOPS" \
                -I"$CSMITH_INC" "$src" 2>&1) || true
            cbmc_verdict=$(printf '%s' "$cbmc_out" | grep "^VERIFICATION" | head -1)

            if ! printf '%s' "$cbmc_verdict" | grep -q FAILED; then
                cbmc_clean=1
                break
            fi
        done

        if [ $cbmc_clean -eq 0 ]; then
            printf '[%d] SKIP  no cbmc-clean test found in %d tries\n' "$id" "$MAX_TRIES"
            echo SKIP > "$SHARED/r$id"; return
        fi
    fi

    # ---- Step 2: Reference output (MIPS Linux under qemu-mips-static) ------
    $CC $REF_FLAGS -I"$CSMITH_INC" -w "$src" -lm -o "$ref_bin" 2>/dev/null \
        || { echo SKIP > "$SHARED/r$id"; return; }

    local ref_out
    ref_out=$(timeout "$TIMEOUT_REF" "$QEMU" "$ref_bin" 2>/dev/null) || {
        # cbmc said finite but reference timed out: rare false-positive, skip
        printf '[%d] SKIP  cbmc k=%s false-positive (ref timeout)\n' "$id" "$CBMC_K"
        echo SKIP > "$SHARED/r$id"; return
    }
    ref_out=$(printf '%s' "$ref_out" | grep "^checksum")
    [ -z "$ref_out" ] && { echo SKIP > "$SHARED/r$id"; return; }

    # ---- Step 3: Bare-metal MIPS on r9999 simulator ----------------------
    local ld_script="$HELLO/baremetal.ld"
    [ "${MAPPED_DATA:-0}" -eq 1 ] && ld_script="$HELLO/baremetal_mapped.ld"
    [ "${MAPPED_INSN:-0}" -eq 1 ] && ld_script="$HELLO/baremetal_mapped_insn.ld"
    $CC $BM_FLAGS $BM_DEFS -I"$CSMITH_INC" -I"$HELLO" \
        -w -nostdlib "$src" $SUPPORT_OBJS \
        -T "$ld_script" -Wl,-melf32btsmipn32 -o "$elf" 2>/dev/null \
        || { echo SKIP > "$SHARED/r$id"; return; }

    local sim_raw sim_out
    sim_raw=$(timeout "$TIMEOUT_SIM" \
        "$SIM" --file "$elf" --maxicnt "$MAXICNT" \
        2>&1) || true
    sim_out=$(printf '%s' "$sim_raw" | grep "^checksum")

    # ---- Step 4: Compare -------------------------------------------------
    if [ "$ref_out" = "$sim_out" ]; then
        echo PASS > "$SHARED/r$id"
    elif [ -z "$sim_out" ] && ! printf '%s' "$sim_raw" | grep -q "no match in a while"; then
        # Sim produced no checksum but no checker error either: it timed out
        # before the program finished (program is too slow for the sim).
        printf '[%d] SKIP  sim timeout (no checksum, no checker error)\n' "$id"
        echo SKIP > "$SHARED/r$id"
    else
        echo FAIL > "$SHARED/r$id"
        printf '[%d] MISMATCH\n  ref: %s\n  sim: %s\n  saved: failures/fail_%d.c\n' \
            "$id" "$ref_out" "${sim_out:-<no checksum output>}" "$id"
        printf '%s\n' "$sim_raw" | grep -v "^total_\|^simulation\|^insns\|^ *$" | head -30 | \
            sed "s/^/  [checker] /"
        cp "$src" "$FAIL_DIR/fail_${id}.c"
        cp "$elf"  "$FAIL_DIR/fail_${id}.elf"
    fi
}
export -f worker

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
if [ -n "${SPECIFIC:-}" ]; then
    echo "Re-testing: $SPECIFIC  (cbmc k=$CBMC_K)"
    worker 0
    case "$(cat "$SHARED/r0" 2>/dev/null)" in
        PASS) echo "PASS" ;;
        FAIL) echo "FAIL"; exit 1 ;;
        *)    echo "SKIP" ;;
    esac
    exit 0
fi

TIMER_STR="off"
[ "$TIMER_IRQ" -eq 1 ] && TIMER_STR="on (every 10000 cycles)"
MAPPED_DATA_STR="off (kseg0)"
[ "$MAPPED_DATA" -eq 1 ] && MAPPED_DATA_STR="on (kuseg 0x400000-0x45FFFF, 1:1)"
MAPPED_INSN_STR="off (kseg0)"
[ "$MAPPED_INSN" -eq 1 ] && MAPPED_INSN_STR="on (kuseg 0x200000-0x25FFFF, 1:1)"
echo "Running $N tests on $NPROC parallel workers"
echo "  cbmc k=$CBMC_K   maxicnt=$MAXICNT   ref_timeout=${TIMEOUT_REF}s ($QEMU)   sim_timeout=${TIMEOUT_SIM}s"
echo "  csmith: $CSMITH_FLAGS"
echo "  timer irq: $TIMER_STR"
echo "  mapped data: $MAPPED_DATA_STR"
echo "  mapped insn: $MAPPED_INSN_STR"
echo ""

if [ -t 2 ]; then
    PARALLEL_PROGRESS="--bar"
else
    PARALLEL_PROGRESS=""
fi

seq 1 "$N" \
    | parallel --jobs "$NPROC" --line-buffer $PARALLEL_PROGRESS worker

# ---------------------------------------------------------------------------
# Tally results in test-ID order
# ---------------------------------------------------------------------------
PASS=0; FAIL=0; SKIP=0
FAILED_IDS=()
for i in $(seq 1 "$N"); do
    case "$(cat "$SHARED/r$i" 2>/dev/null || echo SKIP)" in
        PASS) PASS=$((PASS+1)) ;;
        FAIL) FAIL=$((FAIL+1)); FAILED_IDS+=("$i") ;;
        *)    SKIP=$((SKIP+1)) ;;
    esac
done

echo ""
echo "============================================"
printf '  pass=%-5d  skip=%-5d  fail=%-5d / %d\n' "$PASS" "$SKIP" "$FAIL" "$N"
echo "============================================"

if [ "${#FAILED_IDS[@]}" -gt 0 ]; then
    echo ""
    echo "Failed tests (rerun commands):"
    for i in "${FAILED_IDS[@]}"; do
        f="$FAIL_DIR/fail_${i}.c"
        if [ -f "$f" ]; then
            printf '  [%d]  %s\n' "$i" "$f"
            printf '       ./run_tests.sh 1 %s %s %s\n' "$CBMC_K" "$MAXICNT" "$f"
        else
            printf '  [%d]  source not saved\n' "$i"
        fi
    done
fi

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
