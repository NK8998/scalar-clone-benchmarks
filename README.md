# scalar-clone-benchmarks

Reproducible experiments on **deferred history backfill** for large
GVFS-protocol monorepos cloned with `scalar clone`.

Everything here exists to answer one practical question:

> A full clone of the 1JS monorepo takes long enough that developers avoid it.
> If we fetch only what is needed to make the enlistment usable and pull the
> ~6.8 GB of history afterwards in the background — **how much does that
> actually help, and what makes the background phase fast?**

---

## The shape of the problem

A `scalar clone` of this repo splits into two very different costs:

```
scalar clone --no-prefetch     →  usable working tree     (developer waits)
git maintenance prefetch       →  ~6.8 GB of history      (background)
```

Neither phase is bandwidth-bound, which is the interesting part. The wins found
so far came from **removing a serialisation** and **removing a wait**, not from
moving bytes faster:

| finding | effect | where |
|---|---|---|
| Writing a multi-pack-index over the shared cache before backfill | backfill **2.64x faster** (891.5 s → 337.7 s mean) | `prior-experiments/01-midx-ab.md` |
| Backfill does not start until a systemd timer fires, and the first tick races registration and no-ops | up to **~7100 s** of pure idle | `prior-experiments/02-backfill-race.md` |

The open question — and the reason for the current experiment — is whether the
first of those needs a custom flag at all, or whether stock `git maintenance`
can be made to do the same thing.

---

## Layout

```
PREREQUISITES.md        read first — fairness rules for any run here
ENVIRONMENT.md          reference hardware, and how to record yours

experiments/
  midx-vs-maintenance/  ← the current experiment
    README.md             cells, hypotheses, how to run, how to read output
    GIT-BUILDS.md         exactly which Git to download, with links + checksums
    run.sh                the harness
    analyze.sh            collate results into a table

prior-experiments/      how to reproduce everything measured before this
  01-midx-ab.md           the multi-pack-index A/B
  02-backfill-race.md     the lost timer tick, and the idle it causes
  03-clone-phase.md       deferred prefetch and parallel POST
  harnesses/              the scripts those runs actually used

results/historical/     raw measurements from the reference box
```

---

## Start here

1. **`PREREQUISITES.md`** — background maintenance off, cold per-cell object
   cache, pinned build with `GIT_EXEC_PATH` asserted, stall guard armed. Every
   item on that list has voided a real run at least once. It is not boilerplate.
2. **`experiments/midx-vs-maintenance/GIT-BUILDS.md`** — one `.deb`, no
   compilation.
3. **`experiments/midx-vs-maintenance/README.md`** — the six cells and what each
   one is for.

```bash
cd experiments/midx-vs-maintenance
./run.sh A B        # the reference pair — your on-box control
./run.sh C E F
./run.sh D          # last; idles up to an hour by design
./analyze.sh
```

Budget roughly **4 hours** for the full matrix.

---

## Ground rules

These are the rules the existing results were produced under, and results
generated without them are not comparable to them.

- **Never compare across machines.** 3.18x hardware variance was measured on the
  same pack. Always run your own control.
- **One variable per cell.** `largest_pack_bytes` must come out identical
  everywhere; `analyze.sh` checks this and warns loudly if it does not. If the
  cells downloaded different things, nothing else in the output means anything.
- **Assert that flags did something.** The harness dies if `--midx` produced no
  multi-pack-index, or if `--no-midx` produced one. A silently no-op'd flag
  turns an experiment into noise that looks like data.
- **Label measured vs. composed.** A number obtained by adding a measured clone
  to a measured backfill plus an *assumed* idle gap is not a measurement.
  Several figures in circulation are compositions; cell D exists to replace the
  most important of them with something real.

---

## Status of the underlying Git changes

| capability | state |
|---|---|
| `--prefetch-cache-server-url` | in the latest official `microsoft/git` release |
| `--no-prefetch` | merged to `vfs-2.55.0` (PR #979, 2026-08-26) but **in no release yet** |
| `gvfs.postThreads` (parallel POST) | PR #980, **open, under review** |
| `--midx`, `--maintenance-now` | fork-local, not upstreamed |

Because of the middle two rows, these experiments require the fork build
described in `experiments/midx-vs-maintenance/GIT-BUILDS.md`. Re-check
<https://github.com/microsoft/git/releases/latest> before you start — if a newer
release now carries `--no-prefetch`, note it with your results.
