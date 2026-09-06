# midx-vs-maintenance — full six-cell matrix, 2026-09-06

Complete run of `experiments/midx-vs-maintenance` (cells A–F), one run per cell,
on a single box in one sitting. Every cell used the pinned fork build
`2.55.0.vfs.0.8-midx.2` and cloned **1JS** with `--full-clone --no-prefetch`.

**Headline: stock `git maintenance` reproduces the entire `--midx` speed-up, but
only if `incremental-repack` is ordered *before* `prefetch`.** The fork-local
`scalar clone --midx` flag is not needed to get the benefit.

## Read this in order

| # | file | what it gives you |
|---|---|---|
| 1 | `README.md` (this file) | findings, verdicts, caveats |
| 2 | `midx-vs-maintenance.csv` | every number, one row per cell |
| 3 | `analyze-output.txt` | verbatim `analyze.sh` output, incl. payload control |
| 4 | `trace-evidence/` | the causal proof, extracted from the traces |
| 5 | `cells/<L>-<name>/` | per-cell logs (`result.txt`, `meta.txt`, `clone.log`, …) |
| 6 | `void-runs/` | two discarded attempts + why they were discarded |
| 7 | `environment.txt` | the box, per `ENVIRONMENT.md` |
| 8 | `harness-console.log` | full console transcript of the whole matrix |
| 9 | `run.sh.patch` | two harness fixes this run required |

## Results

All six cells, `largest_pack_bytes` = **6,827,039,770** — byte-identical across
every cell and identical to `../historical/midx-ab.csv`. The payload control
holds, so the times are comparable.

| cell | name | clone_s | idle_s | backfill_s | total_s | midx during backfill |
|---|---|---:|---:|---:|---:|:--:|
| A | midx-on      | 708 |   0 | **329**  | 1037 | yes (`--midx`) |
| B | midx-off     | 595 |   0 | **931**  | 1526 | no |
| C | maint-now    | 449 |   0 | 1424 | 1873 | no |
| D | timer        | 338 | 217 | 1368 | 1923 | no |
| E | maint-daily  | 606 |   0 | 1415 | 2021 | written *after* the fetch |
| F | repack-first | 330 |   0 | **336**  |  666 | yes (stock maintenance) |

`clone_s` varies a lot cell-to-cell (330–708 s). That is network variance on a
shared, throttled link and is **not** the treatment — see "What not to conclude".

### Hypothesis verdicts

| | hypothesis | verdict |
|---|---|---|
| **H1** | a midx written before backfill speeds up backfill | **✓** 931 → 329 s, **2.83x** (historical: 2.64x) |
| **H2** | `--maintenance-now` moves the work into clone | **✓ partial** — `idle_s`=0 as predicted, but C's backfill is 1.53x *slower* than B, not equal |
| **H3** | the systemd timer fires within the idle window | **✗** — D idled only 217 s, and only because of a stale stamp (see caveats) |
| **H4** | `--schedule=daily` writes a usable midx | **✓** as written, but the midx lands too late to help *this* backfill |
| **H5** | stock maintenance can replace `--midx` | **✓** F 336 s vs A 329 s — **1.02x**. This is the decision. |

## The finding worth reporting upstream

Cell E runs `git maintenance run --schedule=daily`, which does write a
multi-pack-index — and still takes 1415 s, no better than doing nothing. Cell F
runs the *same tasks in a different order* and takes 336 s.

The difference is purely task ordering. From `trace-evidence/task-ordering.txt`
(line numbers into each cell's perf trace):

```
E:  fetch             @ line  19      <-- the expensive part runs first,
    multi-pack-index  @ line 445          against 102 loose packs
F:  multi-pack-index  @ line  19      <-- midx built first, in its own invocation
    fetch             @ line  99          then the fetch benefits from it
```

`index-pack` time is the apples-to-apples metric — same 6.83 GB payload, same
delta resolution, CPU/lookup bound (`trace-evidence/index-pack-and-midx-loads.txt`):

```
A  243.8 s   31 midx loads, 102 packs
F  257.2 s   35 midx loads, 102 packs
B  866.6 s    0 midx loads          <-- no midx at all
E  867.9 s    3 midx loads, 135 packs  <-- midx existed, but written after the fetch
```

E is the counterfactual that makes this airtight: the midx **existed**, and it
still didn't help, because it was built too late. So the mechanism is *ordering*,
not *existence*.

And the repack is nearly free. F's whole `incremental-repack` phase:

```
multi-pack-index write    0.263 s
multi-pack-index expire   0.004 s
multi-pack-index repack   3.730 s
-------------------------------
total                     4.33 s   ->  saves ~609 s   (~140x return)
```

### The two commands

```sh
git maintenance run --task=incremental-repack   # ~4 s, builds the midx
git maintenance run --task=prefetch             # the backfill, now 2.8x faster
```

This is why **F, not A, is the result to show a Git maintainer**: A asks them to
accept a new fork-local flag; F reports that stock Git already has the
capability and merely schedules it in an unhelpful order.

## Caveats — read before citing these numbers

- **One run per cell.** The experiment README recommends replicating the A/B
  pair (`RUNTAG=run2 ./run.sh A B`) before publishing. Not yet done. A/B is
  consistent with the historical 2.64x, which is reassuring but not replication.
- **Cell D's 217 s is not reproducible.** `Persistent=yes` and
  `LastTriggerUSec=2026-09-06 12:42:58` — a stamp from earlier in *this* session,
  so systemd fired almost immediately to catch up. A genuinely fresh machine
  still faces up to 3600 s. Do not quote 217 s as the expected idle window.
- **Cells C and D detach the work,** so their backfill does not appear in the
  harness's trace file. `0.0` in the index-pack table means "not observable",
  not "no work done".
- **`--full-clone` and `--no-prefetch` are orthogonal.** These runs took a *full
  working tree* with *deferred history*. Describe them that way; "full clone"
  alone makes the 5–12 minute clone times look impossible.
- **`commits` drifts** 527,402 → 527,414 across cells because 1JS advanced
  during the ~3 h matrix. Harmless: `largest_pack_bytes` is the control and it
  held byte-identical.
- **Shared, throttled network.** Absolute `clone_s` is not portable. The
  backfill comparison is sound because payload is byte-identical.

### What not to conclude

F's total (666 s) is the lowest partly because its clone happened to be fastest
(330 s). That is network luck, not treatment. **Compare `backfill_s`, not
`total_s`** — that is the only column the treatment actually acts on.

## Raw traces are deliberately not here

Each cell produced ~199 MB of `*.event.json` / `*.perf.txt`; **1.4 GB total**.
`.gitignore` excludes `runs/`, `*.event.json` and `*.perf.txt` by design
("results belong in `results/`"). Committing them would need `git add -f` and
almost certainly LFS.

Everything load-bearing has been extracted into `trace-evidence/`. The traces
themselves remain on the run box at `$HOME/scalar-tests/runs/0906-*/` and are
regenerable with `./run.sh A B C D E F`.

## Void runs

Two attempts were discarded before producing results. Both are kept because the
root causes are traps that will bite the next person.

- **`void-runs/midx-on-outage/`** — `POST /gvfs/objects` against the *only*
  advertised cache server (`wbp-adoprx`) accepted TLS then sent zero bytes,
  tripping `GIT_HTTP_LOW_SPEED_TIME` at exactly 300 s, backing off 8 s, and
  repeating. Reproducible with plain `curl` (`http=000`, **zero response
  headers** — no 429, no `Retry-After`), which points at client throttling rather
  than HTTP rejection. Origin was healthy throughout; `gitcache` is prefetch-only
  (404 on POST/objects). Waited for recovery, then re-ran. See `stall-evidence.txt`.

- **`void-runs/maint-now-masked-units/`** — **the important one.**
  `git-maintenance@{hourly,daily,weekly}.service` were symlinked to `/dev/null`
  (systemd *masked*) by an earlier experiment. Registration failed silently, so
  `maintenance.strategy` was never set, which corrupts cells **C, D and E**:

  ```
  systemd:  Refusing to start, unit git-maintenance@hourly.service to trigger not loaded
  git:      fatal: failed to set up maintenance schedule
            warning: could not toggle maintenance
  ```

  `git maintenance start` will **not** rewrite an existing unit file, so the mask
  survives it and the failure is easy to miss. Fix:
  `systemctl --user unmask git-maintenance@{hourly,daily,weekly}.service`, then
  let git regenerate the units.

  `PREREQUISITES.md` §2 says to `stop`/`disable` timers, never `mask` — worth
  stating explicitly there, plus a preflight check in `run.sh`.

## Harness fixes required (`run.sh.patch`)

Both were needed to run the matrix at all; neither changes what is measured.

1. **Build check could never pass.** The guard grepped the bare literal
   `--prefetch-cache-server-url`, but `scalar clone -h` renders it as
   `--[no-]prefetch-cache-server-url`, so it `die`d before cell A. The three
   adjacent checks already escape `[no-]`; this one was missed.

2. **`drop_caches()` now prefers a NOPASSWD helper.** This box grants
   `/usr/local/sbin/drop-caches` but not blanket `sudo sh -c`. Without this the
   page cache was never dropped and PREREQUISITES §3 was silently violated —
   it only prints a `note:` and continues. Verified dropping 808 → 287 MB.

Both are worth upstreaming independently of these results.

## Reproducing

```sh
# PREREQUISITES.md first -- especially §2 (timers), §3 (cold cache), §5 (exec-path)
systemctl --user unmask 'git-maintenance@*.service'   # see void run above
cd experiments/midx-vs-maintenance
./run.sh A B C D E F
./analyze.sh
```

`analyze.sh` globs **every** dir in `$ROOT/runs/`, including runs from older
experiments. Archive stale ones first or the payload control reports a false
mismatch.
