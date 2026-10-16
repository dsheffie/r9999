#!/bin/bash
# sweep_dma.sh -- run every knob combination of r9999_dma.m in parallel; one line each
cd "$(dirname "$0")"
for s in 0 1 2 3; do for b in 0 1; do for w in 0 1; do for k in 0 1; do for p in 0 1; do for f in 0 1; do for t in 0 1; do for d in 0 1; do
  [ $s = 0 ] && [ $b = 1 -o $w = 1 ] && continue       # no snoop: ordering knobs moot
  echo "s${s}b${b}w${w}k${k}p${p}f${f}t${t}d${d} SNOOP=$s SNOOP_BEFORE=$b WAIT_DRAIN=$w IRIX_SKIP=$k SPEC_FILL=$p FWD_INDEX=$f L2_WT=$t SW_DRAINED=$d"
done; done; done; done; done; done; done; done |
xargs -P 16 -L 1 sh -c 'r=$(./run_dma.sh "$0" "$@" | head -1 | sed "s/^\s*//"); echo "$0 $r"' | sort
