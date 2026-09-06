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
        printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n",
        v["letter"], v["cell"], v["clone_s"], v["idle_s"], v["backfill_s"],
        v["total_s"], v["midx_at_clone"], v["midx_bytes"],
        v["largest_pack_bytes"], v["payload_final_bytes"], v["commits"]}' "$f"
done | sort > "$TMP"

[ -s "$TMP" ] || { echo "no completed cells found under $RUNS"; exit 1; }

echo
echo "=== cells ==="
{
  echo "cell|run|clone_s|idle_s|backfill_s|total_s|midx|midx_bytes|largest_pack|payload_final|commits"
  cat "$TMP"
} | column -s'|' -t

echo
echo "=== payload control ==="
echo "largest_pack_bytes must be IDENTICAL across every cell."
echo "If it is not, the cells did not download the same thing and no"
echo "comparison below is valid."
n=$(cut -d'|' -f9 "$TMP" | sort -u | grep -c . || true)
cut -d'|' -f9 "$TMP" | sort -u | sed 's/^/  /'
if [ "$n" = 1 ]; then echo "  -> OK: one distinct value"
else echo "  -> *** WARNING: $n distinct values. Investigate before trusting anything. ***"; fi

get() { awk -F'|' -v l="$1" -v c="$2" '$1==l{print $c; exit}' "$TMP"; }

cmp_cells() {  # <letter> <letter> <label>
    local a=$1 b=$2 label=$3
    local ba bb
    ba=$(get "$a" 5); bb=$(get "$b" 5)
    [ -n "$ba" ] && [ -n "$bb" ] || return 0
    [ "$ba" -gt 0 ] && [ "$bb" -gt 0 ] || return 0
    awk -v a="$ba" -v b="$bb" -v A="$a" -v B="$b" -v L="$label" 'BEGIN{
        printf "  %-52s %s=%ds  %s=%ds   %+ds  (%.2fx)\n", L, A, a, B, b, a-b, b/a
    }'
}

echo
echo "=== backfill comparisons ==="
cmp_cells A B "H1  midx vs no midx (the reference pair)"
cmp_cells A C "H2  midx vs immediate-maintenance"
cmp_cells B C "H2  control vs immediate-maintenance (expect ~equal)"
cmp_cells A E "H4  midx vs daily schedule"
cmp_cells A F "H5  midx vs repack-then-prefetch  <-- the decision"

echo
echo "=== idle ==="
printf '  %-18s %s\n' cell idle_s
awk -F'|' '{printf "  %-18s %s\n", $2, $4}' "$TMP"
echo
echo "  H2: cell C idle should be ~0."
echo "  H3: cell D idle is the real-world wait nobody has measured before."

echo
echo "=== end-to-end ==="
awk -F'|' '{printf "  %-18s clone %5ss + idle %6ss + backfill %5ss = %6ss\n", $2,$3,$4,$5,$6}' "$TMP"

echo
echo "Raw records: $RUNS/*/result.txt"
