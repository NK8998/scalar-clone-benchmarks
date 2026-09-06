# 02 — Why doesn't the background backfill start?

**Answer: `scalar clone` arms the maintenance timers *before* it tells Git which
repositories to maintain. The first tick fires against an empty list, does
nothing, and exits in ~19 ms. The next one is an hour later.**

Deferring history is only a win if the deferred work actually starts. It
doesn't — and the failure is silent, which is why it went unnoticed.

---

## The race

`scalar clone` registers the enlistment for maintenance, which does two things
in this order:

1. arms four systemd user timers (`git-maintenance@{hourly,daily,weekly}.timer`)
2. writes `maintenance.repo` into `~/.gitconfig`

If the timer fires between (1) and (2) it sees no repositories and returns
successfully having done nothing.

### Observed, twice

```
systemctl --user status git-maintenance@hourly.service
  Active: inactive (dead) since 12:13:52
  CPU: 19ms
  Mem peak: 2.2M

stat ~/.gitconfig
  maintenance.repo written 12:13:53.164
```

The service ran **1.16 s before** the config that would have given it work. A
19 ms / 2.2 MB run is not a backfill — it is a no-op.

Confirmation that nothing was fetched:

```bash
git for-each-ref 'refs/prefetch/**'     # → 0 refs
```

**Cost: up to 3600 s of idle before backfill begins.**

---

## Why you cannot just swap the two steps

The obvious fix is to write `maintenance.repo` first. It does not help the case
that matters.

systemd's `Persistent=true` catch-up — which re-runs a timer that was missed —
is **conditional on stamp state**. Tested directly with a dummy unit:

| stamp state | does the catch-up tick fire? |
|---|---|
| stale stamp exists | **yes** |
| no stamp at all (fresh machine) | **no** |

A first-ever clone on a fresh machine has no stamp. That is precisely the
scenario the whole effort is about. Reordering fixes the case that was already
survivable and does nothing for the case that hurts.

Hence an **explicit kickoff** after the clone, rather than a reordering.

---

## The kickoff

The fork adds `scalar clone --maintenance-now` (default on), which is again a
wrapper over a **stock git command**:

```c
run_git("maintenance", "run", "--schedule=hourly", "--detach", NULL);
```

Because it is stock, the same effect can be produced by any caller — a clone
wrapper, a setup script — without patching Git at all. Cells C and F of the
current experiment measure whether that is enough.

---

## Traps found along the way

Each of these silently produces a wrong answer rather than an error.

### `maintenance.strategy` must be set, or `--schedule` runs nothing

```bash
git maintenance run --schedule=hourly     # exits 0, runs ZERO tasks
```

With `maintenance.strategy` unset there are no tasks registered for any
schedule, so the command succeeds having done nothing. `scalar clone` sets it
during registration. **Any script invoking `maintenance run --schedule=…` must
verify it is set first** — the current harness does, and refuses to run cell E
without it.

### The schedule enum is inverted

```
WEEKLY = 1,  DAILY = 2,  HOURLY = 3
```

The task filter skips a task when `task.schedule < opts->schedule`. Because
hourly has the *highest* value, `--schedule=daily` and `--schedule=weekly` also
run the hourly tasks. Measured task sets:

| schedule | tasks actually run |
|---|---|
| hourly | prefetch, commit-graph |
| daily | + loose-objects, incremental-repack |
| weekly | + pack-refs, cache-local-objects |

**Consequence for the midx question:** `prefetch` runs *before*
`incremental-repack`. So on a first daily run, the midx is written **after** the
prefetch it was meant to accelerate. This is why cell E is expected to land near
the control, and why cell F forces the repack first.

### Don't use `--detach` from a wrapper

`daemonize()` unconditionally closes fds 0, 1 and 2, so any failure becomes
invisible. `--detach` is conditional in `builtin/gc.c`, and the background tasks
run either way — so a caller that is already detached from the user's terminal
should omit it and keep a log. Costs nothing, and turns a silent failure into a
diagnosable one.

### The maintenance lock is per *shared cache*, not per enlistment

The lock is taken over the object source path, which for a GVFS enlistment is
redirected to `gvfs.sharedCache`. Two enlistments sharing a cache therefore
serialise against each other — which is also why every experiment cell must use
its own `--local-cache-path`.

---

## Reproducing

```bash
# watch the race directly
systemctl --user status 'git-maintenance@hourly.service'   # CPU ~19ms => no-op
stat -c '%y %n' ~/.gitconfig                               # compare timestamps
git for-each-ref 'refs/prefetch/**' | wc -l                # 0 => never ran
```

End to end, cell **D** of the current experiment measures the resulting idle for
real:

```bash
cd ../../experiments/midx-vs-maintenance
./run.sh D
```

Note that D's idle depends on this box's stamp state, for the reason above. The
harness records `LastTriggerUSec` before the clone so the result can be
interpreted; report it alongside the number.
