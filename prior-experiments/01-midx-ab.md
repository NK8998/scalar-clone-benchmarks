# 01 — Does a multi-pack-index speed up the backfill?

**Answer: yes. 2.64x — 891.5 s → 337.7 s mean, a 553.8 s saving.**

This is the strongest result the project has, and it is the finding the current
experiment is trying to reproduce without a custom flag.

---

## The idea

With `--no-prefetch`, `scalar clone` leaves the shared object cache holding many
packs (117–124 in these runs). The backfill then has to resolve objects against
all of them. A **multi-pack-index** gives Git a single sorted index across every
pack in the object directory, so lookups stop scaling with pack count.

The fork adds `scalar clone --midx`, which is a thin wrapper over a **stock git
command** run at the end of the clone:

```c
run_git("multi-pack-index", "write", "--object-dir", shared_cache, NULL);
```

Placement is the whole trick: the midx must exist **before** the backfill runs,
otherwise it accelerates nothing.

---

## How it was run

`harnesses/run-midx.sh`, one variant per cell:

```bash
./run-midx.sh off      # scalar clone --no-prefetch --no-midx
./run-midx.sh on       # scalar clone --no-prefetch          (midx defaults on)
```

Both cells then ran the identical backfill:

```bash
git -C "$worktree" maintenance run --task=prefetch
```

Constants across every cell: `--full-clone`, the new prefetch cache-server
endpoint, `gvfs.postThreads=8`, a private `--local-cache-path`, timers
quiesced, page cache dropped.

---

## Results

Full table in `../results/historical/midx-ab.csv`.

| cell | date | midx | clone_s | **backfill_s** | packs |
|---|---|---|---|---|---|
| `c6midx-off` | 08-26 | off | 497 | **914** | 123 |
| `c6midx-on.run1` | 08-26 | on | 353 | **342** | 123 |
| `c6midx-on` | 08-26 | on | 243 | **336** | 124 |
| `aug27-off` | 08-27 | off | 604 | **869** | 117 |
| `aug27-on` | 08-27 | on | 804 | **335** | 117 |

```
OFF   869, 914          mean 891.5 s
ON    335, 342, 336     mean 337.67 s
                        2.64x, −553.8 s
```

The groups do not overlap. The **slowest** ON run beats the **fastest** OFF run
by **527 s** — more than an entire ON run takes.

---

## Why this is a real effect and not noise

Three independent controls:

1. **Identical payload.** `largest_pack_bytes` = **6,827,039,770** in every
   single cell. Each run downloaded byte-identical history, so nothing here is
   explained by one cell fetching less.
2. **The size difference is exactly the midx.** On the cleanest pair
   (`aug27-on`/`aug27-off` — same day, adjacent runs) the entire final-payload
   difference is **15,047,596 B**, and the midx file is **15,012,724 B**. There
   is no other material difference between the two enlistments.
3. **Clone time moved the wrong way and it didn't matter.** On 08-27 the ON cell
   cloned *slower* (804 s vs 604 s); on 08-26 it cloned *faster* (243 s vs
   497 s). Backfill stayed tightly grouped regardless. A confound large enough
   to fake a 2.64x backfill effect would have to survive the clone phase moving
   in opposite directions on the two dates.

---

## What this does **not** prove

- **Nothing about clone time.** `clone_s` ranges 243–982 s across these runs.
  That is time of day, not configuration. Writing the midx does add work to the
  clone, but this data cannot size it.
- **Nothing about other hardware.** A second devbox indexed the same pack
  **3.18x slower**. Re-run the control locally.
- **Nothing about whether the custom flag is necessary.** `git maintenance`
  already writes a midx during `incremental-repack`. Whether stock maintenance
  can deliver the same win — and therefore whether `--midx` should exist at all
  — is exactly what the current experiment tests, in cells E and F.

---

## Reproducing it today

The current harness supersedes this one. Cells **A** and **B** of
`../../experiments/midx-vs-maintenance/` are the same comparison with better
instrumentation:

```bash
cd ../../experiments/midx-vs-maintenance
./run.sh A B
./analyze.sh
```

`harnesses/run-midx.sh` is retained so the published numbers stay traceable to
the code that produced them.
