#!/usr/bin/env bash
# Collate every completed cell into one table, then compute the comparisons
# the experiment actually exists to answer.
set -euo pipefail

ROOT=${ROOT:-$HOME/scalar-tests}
RUNS="$ROOT/runs"
[ -d "$RUNS" ] || { echo "no runs directory at $RUNS"; exit 1; }

TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT

for f in "$RUNS"/*/result.txt; do
    [ -e "$f" ] || continue
    grep -q '^total_s=' "$f" || continue
    awk -F= '{v[$1]=$2} END{
        printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n",
        v["letter"], v["cell"], v["clone_s"], v["idle_s"], v["prep_s"]+0,
        v["backfill_s"], v["total_s"], v["midx_at_clone"], v["midx_bytes"],
        v["largest_pack_bytes"], v["payload_final_bytes"], v["commits"]}' "$f"
done | sort > "$TMP"

[ -s "$TMP" ] || { echo "no completed cells found under $RUNS"; exit 1; }

echo
echo "=== cells ==="
{
  echo "cell|run|clone_s|idle_s|prep_s|backfill_s|total_s|midx|midx_bytes|largest_pack|payload_final|commits"
  cat "$TMP"
} | column -s'|' -t

cat <<'NOTE'

  prep_s = time spent building the index before the backfill.
     cell A: the midx write, which happens INSIDE the clone and so is already
             counted in clone_s (recovered from the clone's trace2 stream).
     cell F: incremental-repack, which happens AFTER the clone and therefore
             adds to the wall clock.
  Without this split, A would hide its index cost inside clone_s while F
  carried its own inside backfill_s, and the two cells could not be compared
  in either direction.
NOTE

echo
echo "=== payload control ==="
echo "largest_pack_bytes must be IDENTICAL across every cell. If it is not, the"
echo "cells did not download the same thing and nothing below is valid."
cut -d'|' -f10 "$TMP" | sort -u | sed 's/^/  /'
n=$(cut -d'|' -f10 "$TMP" | sort -u | grep -c . || true)
if [ "$n" = 1 ]; then
    echo "  -> OK: one distinct value"
else
    echo "  -> *** WARNING: $n distinct values. Investigate before trusting anything. ***"
fi

get() { awk -F'|' -v l="$1" -v c="$2" '$1==l{print $c; exit}' "$TMP"; }

cmp_col() {  # <letterA> <letterB> <col> <label>
    local a=$1 b=$2 col=$3 label=$4 va vb
    va=$(get "$a" "$col"); vb=$(get "$b" "$col")
    [ -n "$va" ] && [ -n "$vb" ] || return 0
    [ "$va" -gt 0 ] 2>/dev/null || return 0
    [ "$vb" -gt 0 ] 2>/dev/null || return 0
    awk -v a="$va" -v b="$vb" -v A="$a" -v B="$b" -v L="$label" 'BEGIN{
        printf "  %-50s %s=%ds  %s=%ds   %+ds  (%.2fx)\n", L, A, a, B, b, a-b, b/a
    }'
}

echo
echo "=== backfill: prefetch phase only (col 6) ==="
cmp_col A B 6 "H1  midx vs no midx (the reference pair)"
cmp_col B C 6 "H2  control vs immediate-maintenance (expect ~equal)"
cmp_col A E 6 "H4  midx vs daily schedule"
cmp_col A F 6 "H5  midx vs repack-then-prefetch"

echo
echo "=== cost of building the index (col 5) ==="
awk -F'|' '$5+0>0{printf "  %-20s prep_s=%s\n", $2, $5}' "$TMP"
cmp_col A F 5 "H5  midx write vs incremental-repack"

echo
echo "=== all-in: what a developer actually waits (col 7) ==="
awk -F'|' '{printf "  %-20s clone %5ss + idle %6ss + prep %5ss + backfill %5ss = %6ss\n",
           $2,$3,$4,$5,$6,$7}' "$TMP"
cmp_col A F 7 "H5  all-in: midx vs stock maintenance  <-- the decision"
cmp_col A B 7 "H1  all-in: midx vs no midx"

echo
echo "=== idle ==="
awk -F'|' '{printf "  %-20s idle_s=%s\n", $2, $4}' "$TMP"
echo "  H2: cell C idle should be ~0."
echo "  H3: cell D idle is the real-world wait, and is the number nobody has measured."

echo
echo "Raw records: $RUNS/*/result.txt"
