#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
CMURPHI=${CMURPHI:-$HOME/code/murphi/cmurphi}   # CMurphi 5.4.9 checkout (not vendored)
BUILD=${MURPHI_BUILD:-$HERE/build}
# run_credits.sh NAME KNOB=VAL ... -- check a variant of rv64core_dma.m
set -e
N=$1; shift
D=$BUILD/$N; mkdir -p $D
cp $HERE/rv64core_dma.m $D/$N.m
for kv in "$@"; do k=${kv%=*}; v=${kv#*=}; sed -i "s/^  $k: [0-9]*;/  $k: $v;/" $D/$N.m; grep -q "^  $k: $v;" $D/$N.m || { echo "knob $k not found"; exit 1; }; done
cd $D && $CMURPHI/src/mu $N.m > mu.log 2>&1 && g++ -O0 -std=gnu++98 -w -o $N $N.cpp -I $CMURPHI/include
./$N -m12000 -tv > run.log 2>&1 || true
grep -E "^(Invariant|Error|Assertion|Deadlock)|failed|No error found|states, " run.log | head -4
