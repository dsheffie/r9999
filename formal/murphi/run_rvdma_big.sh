#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
CMURPHI=${CMURPHI:-$HOME/code/murphi/cmurphi}   # CMurphi 5.4.9 checkout (not vendored)
BUILD=${MURPHI_BUILD:-$HERE/build}
# run_rvdma_big.sh NAME KNOB=VAL ... -- rv64core_dma.m with hash compaction (no traces), 40 GB
set -e
N=$1; shift
D=$BUILD/$N; mkdir -p $D
cp $HERE/rv64core_dma.m $D/$N.m
for kv in "$@"; do k=${kv%=*}; v=${kv#*=}; sed -i "s/^  $k: [0-9]*;/  $k: $v;/" $D/$N.m; grep -q "^  $k: $v;" $D/$N.m || { echo "knob $k not found"; exit 1; }; done
cd $D && $CMURPHI/src/mu -b -c $N.m > mu.log 2>&1 && g++ -O0 -std=gnu++98 -w -o $N $N.cpp -I $CMURPHI/include
./$N -m40000 > run.log 2>&1 || true
grep -E "^(Invariant|Error|Assertion|Deadlock)|failed|No error found|states, " run.log | head -4
