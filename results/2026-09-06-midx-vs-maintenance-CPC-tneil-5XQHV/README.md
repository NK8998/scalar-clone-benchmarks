# midx-vs-maintenance - full six-cell matrix, 2026-09-06

Complete run of `experiments/midx-vs-maintenance` (cells A-F), one run per
cell, on host `CPC-tneil-5XQHV`. Every cell used the pinned fork build
`2.55.0.vfs.0.8-midx.2` and cloned 1JS with
`--full-clone --no-prefetch`.

**Headline: stock `git maintenance` reproduced the multi-pack-index speed-up
when `incremental-repack` ran before `prefetch`.** Cell F completed the
backfill in 336 seconds, versus 375 seconds for the fork-local `--midx` path
and 899 seconds without a multi-pack-index.

## Read this in order

| # | file | what it gives you |
|---|---|---|
| 1 | `README.md` | findings, H1-H5 verdicts, and caveats |
| 2 | `midx-vs-maintenance.csv` | all six result rows |
| 3 | `analyze-output.txt` | verbatim `analyze.sh` output and payload control |
| 4 | `trace-evidence/` | index-pack totals and the E/F ordering proof |
| 5 | `cells/<L>-<name>/` | per-cell logs, metadata, pack census, and result |
| 6 | `void-runs/` | discarded attempts and why they were discarded |
| 7 | `environment.txt` | machine and pinned Git configuration |
| 8 | `harness-console.log` | complete retained console transcript |
| 9 | `run.sh.patch` | the two harness fixes required on this box |

## Results

`largest_pack_bytes` is **6,827,039,770** in every cell. The history payload
control therefore passes.

| cell | name | clone_s | idle_s | prep_s | backfill_s | total_s | midx during backfill |
|---|---|---:|---:|---:|---:|---:|:--:|
| A | midx-on | 452 | 0 | 0 | **375** | 827 | yes (`--midx`) |
| B | midx-off | 254 | 0 | 0 | **899** | 1153 | no |
| C | maint-now | 257 | 0 | 0 | 1552 | 1809 | no |
| D | timer | 371 | **2384** | 0 | 1294 | **4049** | no |
| E | maint-daily | 424 | 0 | 0 | 1415 | 1839 | written after fetch |
| F | repack-first | 386 | 0 | **7** | **336** | **729** | yes (stock maintenance) |

`clone_s` varies from 254 to 452 seconds because of network conditions. The
treatment acts on backfill, so `backfill_s` and the trace-derived index-pack
times are the useful comparisons.

### Hypothesis verdicts

| | hypothesis | verdict |
|---|---|---|
| **H1** | a midx written before backfill speeds up backfill | **Confirmed:** 899 -> 375 seconds, **2.40x** |
| **H2** | immediate maintenance removes idle; work should resemble B | **Partial:** idle was 0, but detached backfill was 1552 seconds |
| **H3** | the timer baseline is dominated by real idle | **Confirmed:** 2384 seconds idle and 4049 seconds total |
| **H4** | daily maintenance writes the midx too late to help its first fetch | **Confirmed by trace ordering:** E's index-pack total stayed near B |
| **H5** | stock maintenance can replace `--midx` when correctly ordered | **Confirmed:** F backfill 336 seconds versus A 375 seconds |

## Decision result: Cell F

Cell F ran:

```sh
scalar clone --full-clone --no-prefetch --no-midx --no-maintenance-now ...
git -C <worktree> maintenance run --task=incremental-repack
git -C <worktree> maintenance run --task=prefetch
```

The harness measured the first maintenance command separately:

```text
incremental-repack:   7 s wall clock
prefetch:           336 s
```

The trace resolves the repack work more precisely:

```text
multi-pack-index write    0.287 s
multi-pack-index expire   0.007 s
multi-pack-index repack   6.032 s
```

Cell A's clone-time multi-pack-index write took 0.209 seconds in Trace2. The
harness records whole seconds, so `prep_s=0` is expected after rounding.

The CPU/lookup-bound index-pack totals over the identical payload were:

```text
A  319.3 s   34 midx loads
B  827.5 s    0 midx loads
E  849.1 s    5 midx loads, all after its fetch
F  259.5 s   40 midx loads
```

E and F make the ordering result explicit:

```text
E: fetch at trace line 19; multi-pack-index begins at line 475
F: multi-pack-index begins at line 19; fetch begins at line 99
```

Stock maintenance already has the required capability. The important part is
running `incremental-repack` before the first deferred prefetch.

## Cell D: real timer baseline

Cell D finished cloning at approximately 15:29 UTC and waited for the hourly
timer scheduled at minute 09:

```text
clone:      371 s
idle:      2384 s  (39m 44s)
backfill:  1294 s  (21m 34s)
total:     4049 s  (1h 07m 29s)
```

Unlike a composed estimate, this is a measured end-to-end timer run. Timer
stamps were cleared before the cell, so it represents the fresh-machine case.

## Caveats

- There is one completed run per cell. Replicating A/B and F remains useful
  before making an upstream performance claim.
- The box did not provide non-interactive sudo for dropping the Linux page
  cache. The harness logged this before every cell, so timings may be
  optimistic. Every cell still used a separate cold Scalar object-cache path.
- A completed before an interrupted B attempt. The retained B result came from
  a clean restart about 20 minutes later, so A/B were not as tightly adjacent
  as intended.
- C and D ran maintenance detached. Their backfill work is not present in the
  harness-owned backfill Trace2 stream, so no index-pack attribution is
  available for those cells.
- C's 1552-second and E's 1415-second wall times show substantial network
  variance. Their causal comparison to B is better represented by E's
  trace-derived index-pack time: 849.1 seconds versus B's 827.5 seconds.
- 1JS advanced during the matrix (`commits` 527412 -> 527424). The
  6,827,039,770-byte history pack remained identical and is the payload
  control.

## Raw traces

The large `*.event.json` and `*.perf.txt` files are intentionally not committed.
They remain on the run box at:

```text
$HOME/scalar-tests/runs/0906-*/
```

The load-bearing facts extracted from them are committed under
`trace-evidence/`. Per-cell logs and pack inventories are under `cells/`.

## Void runs

- `void-runs/harness-preflight/`: the initial harness failed before cell A
  because the cache-server option check did not match Scalar's rendered help,
  then exited on an empty timer-stamp glob under `set -o pipefail`.
- `void-runs/maint-daily-outage/`: the first E attempt repeatedly hit the
  300-second low-speed timeout against `POST /gvfs/objects`. It was discarded
  and restarted with a new private enlistment and cache.

## Reproducing

```sh
cd experiments/midx-vs-maintenance
./run.sh A B
./run.sh C E F
./run.sh D
./analyze.sh
```

Read `PREREQUISITES.md` first. In particular, clear timer stamps, use a private
cache for every cell, pin `GIT_EXEC_PATH`, and keep the low-speed guard enabled.
