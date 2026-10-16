#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
CMURPHI=${CMURPHI:-$HOME/code/murphi/cmurphi}   # CMurphi 5.4.9 checkout (not vendored)
BUILD=${MURPHI_BUILD:-$HERE/build}
# run.sh NAME KNOB=VAL ... -- build a variant of rv64core_caches.m with the given knobs, check it
set -e
N=$1; shift
D=$BUILD/$N; mkdir -p $D
cp $HERE/rv64core_caches.m $D/$N.m
for kv in "$@"; do k=${kv%=*}; v=${kv#*=}; sed -i "s/^  $k: [0-9]*;/  $k: $v;/" $D/$N.m; grep -q "^  $k: $v;" $D/$N.m || { echo "knob $k not found"; exit 1; }; done
cd $D && $CMURPHI/src/mu $N.m > mu.log 2>&1 && g++ -O2 -w -o $N $N.cpp -I $CMURPHI/include
./$N -m4000 -tv -td > run.log 2>&1 || true
grep -E "^(Invariant|Error|Assertion|Deadlock)|failed|No error found|State Space Explored|states, |rules fired" run.log | head -6
