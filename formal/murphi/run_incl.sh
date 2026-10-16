#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
CMURPHI=${CMURPHI:-$HOME/code/murphi/cmurphi}   # CMurphi 5.4.9 checkout (not vendored)
BUILD=${MURPHI_BUILD:-$HERE/build}
# run_incl.sh NAME KNOB=VAL ... -- check a variant of r9999_incl.m
#   MEM=MB (default 1000)  BIG=1 -> mu -b -c (bit + hash compaction; no traces)
set -e
N=$1; shift
D=$BUILD/$N; mkdir -p $D
cp $HERE/r9999_incl.m $D/$N.m
for kv in "$@"; do k=${kv%=*}; v=${kv#*=}; sed -i "s/^  $k: [0-9]*;/  $k: $v;/" $D/$N.m; grep -q "^  $k: $v;" $D/$N.m || { echo "knob $k not found"; exit 1; }; done
MUF=""; [ "${BIG:-0}" = 1 ] && MUF="-b -c"
cd $D && $CMURPHI/src/mu $MUF $N.m > mu.log 2>&1 && g++ -O2 -std=gnu++98 -w -o $N $N.cpp -I $CMURPHI/include
TV="-tv"; [ "${BIG:-0}" = 1 ] && TV=""
./$N -m${MEM:-1000} $TV > run.log 2>&1 || true
grep -E "^(Invariant|Error|Assertion|Deadlock)|failed|No error found|Too many|states, " run.log | head -4
