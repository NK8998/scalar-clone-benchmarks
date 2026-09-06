# Experiment: does the multi-pack-index matter, and can `git maintenance` replace it?

## Background

Cloning the 1JS monorepo over the GVFS protocol is slow enough that developers
avoid it. The strategy under investigation is: **fetch the minimum needed to
make the enlistment usable, hand the developer a working tree, and pull the
~6.8 GB of history afterwards in the background.**

That splits total time into two phases we can optimise separately:

```
scalar clone --no-prefetch      →  usable working tree      (foreground)
git maintenance prefetch        →  full history backfill    (background)
```

An earlier A/B found that writing a **multi-pack-index over the shared object
cache before the backfill runs** made the backfill **2.64x faster** — 891.5 s →
337.7 s mean, a 554 s saving. See `../../prior-experiments/01-midx-ab.md` for
the raw data.

That result raises the question this experiment exists to answer:

> **The midx is a fork-local `scalar clone --midx` flag. But `git maintenance`
> already writes a multi-pack-index as part of its `incremental-repack` task.
> Can we get the same speed-up out of stock maintenance, and drop the custom
> flag?**

And a second question the earlier work never actually measured:

> **How long does a developer really wait if we change nothing?** Every "total
> time" figure quoted so far *composes* a measured clone with a measured
> backfill and an *assumed* idle gap. Nobody has ever sat and timed the real
> thing end to end.

---

## The two knobs

Both are fork-local flags on `scalar clone`, and both are thin wrappers over
**stock git commands** — that matters, because it means the behaviour can be
moved out of Scalar and into a caller without reimplementing anything.

| flag | default | what it runs |
|---|---|---|
| `--midx` | on | `git multi-pack-index write --object-dir <shared-cache>` |
| `--maintenance-now` | on | `git maintenance run --schedule=hourly --detach` |

`--maintenance-now` exists because of a **race**: `scalar clone` arms the
systemd maintenance timers *before* writing `maintenance.repo` to
`~/.gitconfig`. The first timer tick therefore fires against an empty repo
list, does nothing, and exits in ~19 ms. The next tick is an hour later — so
backfill can idle for up to **3600 s** before it even begins.

Reordering the two operations does not fix it: systemd's `Persistent=` catch-up
is conditional on stamp state, and on a **fresh machine with no stamp it does
not fire at all**. A first-ever clone — exactly the case we care about — gets no
catch-up. Hence an explicit kickoff.

---

## Cells

One binary throughout: `v2.55.0.vfs.0.8-midx.2`. See `GIT-BUILDS.md`.

Every cell passes `--no-prefetch` (deferred history) and **must** use the new
prefetch cache-server endpoint. Cells differ only in flags and in what happens
after `scalar clone` returns.

| # | cell | extra clone flags | after clone | question it answers |
|---|---|---|---|---|
| **A** | `midx-on` | `--midx --no-maintenance-now` | harness runs `maintenance run --task=prefetch` | backfill **with** a midx — the treatment |
| **B** | `midx-off` | `--no-midx --no-maintenance-now` | harness runs `maintenance run --task=prefetch` | backfill **without** a midx — the control |
| **C** | `maint-now` | `--no-midx --maintenance-now` | **scalar** starts it; harness only observes | does the built-in kickoff remove the idle gap? |
| **D** | `timer` | `--no-midx --no-maintenance-now` | **nothing.** Timers stay armed. Wait. | the **true** end-to-end wait, idle included |
| **E** | `maint-daily` | `--no-midx --no-maintenance-now` | harness runs `maintenance run --schedule=daily` | does the daily schedule's own repack match A? |
| **F** | `repack-first` | `--no-midx --no-maintenance-now` | harness runs `incremental-repack`, **then** `prefetch` | can stock maintenance match A if we reorder it? |

A and B are the reference pair. **Run them adjacently** — they are the on-box
control for everything else.

### What each cell is really testing

**A vs B** reproduces the original midx result on your hardware. If it does not
reproduce, stop: nothing downstream is interpretable.

**C** is about *idle*, not throughput. Note carefully: C runs
`--schedule=hourly` with no midx, which is the same work B does. **Its backfill
duration should come out ≈ B, not ≈ A.** What should change is `idle_s`,
which should drop to roughly zero. If you find yourself expecting C to be fast,
re-read this paragraph — the expected win is the wait, not the work.

**D** is the honest baseline. Every "2h43m" style figure quoted to date is a
composition of measured parts plus an *assumed* idle. This cell measures it for
real. Expect it to be dominated by idle.

> D is the one cell where the flags need explaining. "Change nothing" sounds
> like it should mean "pass no flags" — but on this build **both `--midx` and
> `--maintenance-now` default to *on***, so passing nothing would kick the
> backfill off immediately and measure no idle at all, which is the opposite of
> the point. D therefore switches both **off** explicitly and leaves the systemd
> timers **armed**. That combination is what reproduces today's shipping
> behaviour: no midx, no kickoff, wait for the timer.

**E** tests whether the stock daily schedule gets the midx benefit for free. It
probably does **not**, and for a specific reason: maintenance runs tasks in a
fixed order, and **`prefetch` runs before `incremental-repack`**. So on a first
run the midx is written *after* the prefetch it was supposed to accelerate. E
should therefore land near B, with the midx only helping a *subsequent* run.

**F** is the cell that actually answers the headline question. It forces the
repack *first*, then prefetches — the same ordering `--midx` produces, but built
entirely from stock `git maintenance` tasks. **If F ≈ A, the custom `--midx`
flag is unnecessary and can be replaced with stock maintenance calls.** If F is
meaningfully slower than A, the flag is earning its keep.

---

## Hypotheses

State them before you run, so the result can disagree with you.

| | prediction |
|---|---|
| H1 | A is materially faster than B at backfill (prior: 2.64x) |
| H2 | C's `idle_s` ≈ 0; C's `backfill_s` ≈ B's, **not** A's |
| H3 | D is dominated by idle and is the slowest cell end to end |
| H4 | E ≈ B on a first run, because prefetch precedes incremental-repack |
| H5 | F ≈ A — stock maintenance can match the flag once ordering is fixed |

H5 is the decision-relevant one.

---

## Running it

Read `../../PREREQUISITES.md` first. It is not boilerplate; every item in it
has voided a real run at least once.

```bash
cd experiments/midx-vs-maintenance

# Core pair first — this is your on-box control.
./run.sh A B

# Then the rest.
./run.sh C E F

# D last: it can idle for up to an hour by design.
./run.sh D

./analyze.sh
```

Cells are resumable — a cell with a completed `result.txt` is skipped, so an
interrupted run can be restarted with the same command.

### Time budget

| cell | rough wall-clock |
|---|---|
| A | clone + ~6 min backfill |
| B | clone + ~15 min backfill |
| C | clone + ~15 min backfill |
| D | clone + **up to 60 min idle** + ~15 min |
| E | clone + ~15–20 min |
| F | clone + ~10–15 min |

Clone itself has been measured anywhere from 243 s to 804 s depending on network
conditions. Budget around **4 hours** for the full matrix.

### Repeat the pair

Network variance across time of day is large enough to swamp a single
comparison. If you have time for only one thing beyond the first pass, **run A
and B a second time**, interleaved:

```bash
RUNTAG=run2 ./run.sh A B
```

---

## Reading the output

Each cell writes `$ROOT/runs/<tag>-<cell>/`:

| file | contents |
|---|---|
| `result.txt` | the measurements — `clone_s`, `idle_s`, `backfill_s`, `total_s`, pack census |
| `meta.txt` | exact build, flags, exec-path, config actually in force |
| `clone.log`, `backfill.log` | command output |
| `*.event.json`, `*.perf.txt` | trace2, for per-phase attribution |
| `pack-sizes.txt` | every pack and its size |
| `midx.txt` | whether a midx existed, and how large |

`analyze.sh` collates every `result.txt` into one table.

### The control that makes it trustworthy

`largest_pack_bytes` is the size of the history pack — the actual payload. **It
must be identical across every cell.** In the original A/B it was
`6,827,039,770` bytes in all five runs. If it varies between your cells, the
cells did not download the same thing and the comparison is invalid.

The harness also *asserts* that the midx knob did what was asked: it dies if
`--midx` produced no `multi-pack-index`, or if `--no-midx` produced one. A
silently no-op'd flag would otherwise turn the whole experiment into noise.

---

## Known caveats

- **Cell D is stamp-dependent.** systemd `Persistent=` catch-up fires if a
  *stale* stamp exists but not if there is *no* stamp. So D's idle depends on
  whether this box has ever run `git maintenance`. The harness records
  `LastTriggerUSec` before the clone — report it alongside the result. On a
  genuinely fresh machine, expect the full hour.
- **C and D are observed, not driven.** Their backfill runs detached, so the
  harness detects completion by watching for byte growth to stabilise while no
  relevant process is alive. That is inherently fuzzier than timing a command
  you invoked. `STABLE_S` controls the quiet period.
- **E and F depend on `maintenance.strategy`.** Without it,
  `maintenance run --schedule=…` runs **zero tasks and exits 0** — a silent
  no-op. `scalar clone` sets it during registration; the harness verifies it is
  present before relying on it.
- **Do not compare across machines.** A second devbox indexed the same pack
  **3.18x slower**. Only on-box, same-session comparisons mean anything.
