# 03 — Shortening the foreground clone

The developer-visible wait is `scalar clone`. Two changes target it. Both are
**upstream** work (not fork-local), and neither is in a shipping release yet —
which is the main practical blocker for this whole effort.

---

## `--no-prefetch` — defer history out of the clone

By default `scalar clone` fetches history inline. `--no-prefetch` skips it,
leaving the ~6.8 GB to a background `git maintenance` prefetch. This is the flag
every cell in the current experiment depends on; without it there is no
"deferred backfill" to measure.

### Effect

Comparing the inline-prefetch reference cell against a deferred one, same
harness, same box (`../results/historical/midx-ab.csv`):

| cell | prefetch | clone_s | backfill_s |
|---|---|---|---|
| `aug27-c2` | inline | 982 | 9 |
| `aug27-off` | deferred | 604 | 869 |
| `aug27-on` | deferred + midx | 804 | 335 |

Read this cautiously. It **does** show the work moving out of the clone —
`backfill_s` of 9 s in the inline cell means there was nothing left to fetch.
It **does not** cleanly size the clone saving, because `clone_s` varies 243–982 s
on network conditions alone across these runs. The reliable statement is
structural: the history cost moves from the phase the developer waits on to a
phase they don't.

### Status

Merged to `vfs-2.55.0` in **PR #979, 2026-08-26**. The most recent official
release, `v2.55.0.vfs.0.8`, was published **2026-08-11** — two weeks *earlier*.

**So `--no-prefetch` is currently in no official release at all**, and is not on
`main` either. Any reproduction needs either the fork build or a source build of
`vfs-2.55.0`. See `../experiments/midx-vs-maintenance/GIT-BUILDS.md`.

---

## `gvfs.postThreads` — parallel POST

`git-gvfs-helper` requests objects from the cache server over POST. Serially, by
default. The blob fetch that populates a sparse checkout is a large number of
these requests, so parallelising them targets the other half of the clone.

The experiments here run `gvfs.postThreads=8` throughout.

> **This must travel through the environment**, not `scalar -c`. The setting has
> to reach the `git-gvfs-helper` **child processes**, and `scalar -c` does not
> propagate to them. Use `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n`, appending to
> any existing `GIT_CONFIG_COUNT`. The repository config does not exist yet at
> clone time, so there is nowhere else to put it.

### Status

**PR #980, open and under review** — not merged, not released. It is the last
piece needed before the full deferred-clone story can run on stock Git.

---

## A hazard worth knowing about

`gvfs-helper` sets only `CURLOPT_CONNECTTIMEOUT_MS`. There is **no transfer
timeout**, and `http.c` arms one only when both low-speed knobs are greater than
zero — they default to `-1`.

So a cache server that accepts a POST and then goes silent hangs the clone
**forever**. Observed 2026-08-26: an ESTABLISHED socket, `Recv-Q 0`, zero bytes
transferred for 9 minutes, and the trace2 region never closing. The documented
`--fallback` path does not fire either, because it is gated on the request
actually failing.

Every harness here arms a guard:

```bash
export GIT_HTTP_LOW_SPEED_LIMIT=1000
export GIT_HTTP_LOW_SPEED_TIME=300
```

1000 B/s over 300 s trips only on a genuine stall — an order of magnitude below
the worst legitimate throughput observed (~350 KiB/s) — and lets gvfs-helper's
own retry logic recover instead of wedging the run.

### Diagnosing a suspected stall

Sample the helper's read counter and the interface counter together:

```bash
awk '/^rchar/' /proc/<gvfs-helper-pid>/io
cat /sys/class/net/eth0/statistics/rx_bytes
```

**Frozen `rchar` means a stall, not throttling.** Observed during one such hang:
`rchar` unchanged across six 5-second samples while the shared cache stayed at
8 KB and the interface moved 0.05 MB in 10 s — with 16 idle cores and 21 GB of
free RAM. Nothing was slow; something was stuck.
