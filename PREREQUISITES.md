# PREREQUISITES — read before running anything

Every number these experiments produce is a *comparison*. A comparison is only
worth having if the two cells differed in exactly the thing under test. This
file is the list of everything else that has to be held still.

**If you skip a step here, the run is void.** Not "slightly noisy" — void. Each
item below is here because it silently invalidated a real run at least once.

---

## 1. Access

You need working auth to the repository under test before you start, or the
first cell will fail 8 minutes in.

```bash
# Confirm you can reach the remote at all.
git ls-remote https://office.visualstudio.com/DefaultCollection/Office/_git/1JS HEAD
```

If that prompts or fails, fix credentials first. The harness sets
`credential.interactive=never` on purpose — an unattended run must never sit
waiting on a prompt — so a missing credential becomes a hard failure, not a
hang.

---

## 2. Background maintenance must be OFF

`scalar clone` registers the enlistment with `git maintenance` and arms four
systemd user timers. If those fire during a run they pull tens of GB in the
background — one observed `prefetch-*.pack` held 20.3 M objects / 23 GB — which
both **competes for bandwidth** with the cell you are timing and **inflates any
cache measurement** taken afterwards.

```bash
systemctl --user stop    'git-maintenance@*.timer'
systemctl --user disable 'git-maintenance@*.timer'
git config --global --unset-all maintenance.repo

# Verify. Both must print 0.
systemctl --user list-timers 'git-maintenance*' --no-legend | wc -l
git config --global --get-all maintenance.repo | wc -l
```

The harness calls this before **and** after every cell. Do it manually once
before you start, so you know the box was clean at the beginning.

### Clear the timer stamps too

Disabling the timers is not sufficient. The units carry `Persistent=true`, and
**`scalar clone` re-enables them during registration in every cell** — including
cells that passed `--no-maintenance-now`, because registration and kickoff are
separate steps. If a stamp from an earlier cell is still on disk, systemd
considers the timer overdue and fires a catch-up tick *the moment it is
enabled*, starting a background backfill that competes with the one you are
timing.

Measured with a probe unit:

| stamp state | catch-up fires on enable? |
|---|---|
| no stamp | **no** |
| stale stamp | **yes, immediately** |

```bash
rm -f "${XDG_DATA_HOME:-$HOME/.local/share}"/systemd/timers/stamp-git-maintenance@*.timer
```

The harness does this as part of every quiesce. It forces the fresh-machine
case, which is both interference-free and the situation a real first-time clone
is actually in.

> **Exception — cell D.** That cell exists specifically to measure how long the
> timer makes you wait, so it deliberately leaves the timers armed. Note that
> the hourly unit is `OnCalendar=*-*-* 1..23:52:00` — **hour 0 is excluded**, so
> a clone finishing after 23:52 waits until 01:52, nearly two hours rather than
> one. Every other cell requires the timers off.

### Kill leftover helpers

A killed run can leave `git-gvfs-helper` processes alive, still downloading.

```bash
pgrep -ax git-gvfs-helper        # expect no output
```

Kill any survivors **by numeric PID**. Do not use `pkill`/`killall` — on a
shared box you may not be the only user.

---

## 3. Each cell needs its own cold object cache

Scalar shares one object cache across enlistments by default
(`~/.cache/scalar`). If a cell reuses a warm cache, its "download" is a local
copy and the number is meaningless.

The harness passes `--local-cache-path` per cell and then **asserts** the
enlistment actually wired itself to it, by checking both `gvfs.sharedCache` and
`.git/objects/info/alternates`. Do not remove those assertions.

Also drop the OS page cache between cells, or the second cell reads the first
cell's files out of RAM:

```bash
sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
```

Without `sudo` the harness warns and continues; timings will be optimistic.

---

## 4. Disk

Each cell needs room for the enlistment **and** its private cache, and cells are
torn down only after they are recorded.

| item | approximate |
|---|---|
| working tree | 4.7 GB |
| cache at "usable" | 4.8 GB |
| cache after full backfill | 12.3 GB |
| **peak per cell** | **~13 GB** |

Keep **at least 40 GB free**. Traces are retained after teardown; enlistments
and caches are deleted.

```bash
df -h .
```

---

## 5. Pin the Git build — and prove it

This is the single most common way to void a run.

**Git resolves its helpers — notably `git-gvfs-helper` — through its
compiled-in exec-path, not through `PATH`.** A release `.deb` unpacked outside
`/usr/local` will happily run whatever `git-gvfs-helper` is installed
system-wide. Observed 2026-09-02: a `2.55.0.vfs.0.8-midx.2` git spawning a
January-2026 system helper, which stalled the clone at 5 KB for 8 minutes.

So `GIT_EXEC_PATH` must be exported and asserted:

```bash
export PATH="$PREFIX/bin:$PATH"
export GIT_EXEC_PATH="$PREFIX/lib/git-core"     # .deb layout
[ "$(git --exec-path)" = "$GIT_EXEC_PATH" ] || exit 1
[ -x "$GIT_EXEC_PATH/git-gvfs-helper" ]        || exit 1
```

The harness does this and dies if either check fails. Record the helper's mtime
in your run metadata so a stale helper is visible after the fact.

---

## 6. Config must travel through the *environment*

Two settings cannot be passed with `scalar -c`:

- **`gvfs.postThreads`** — it has to reach the `git-gvfs-helper` **children**
  that perform the transfers. `scalar -c` reaches scalar and git, not them.
- **`http.sslBackend`** — release `.deb` builds link **gnutls**; locally
  compiled builds link **OpenSSL**. If `~/.gitconfig` pins one and your build
  is the other, the clone fails in a confusing way.

Both must go through `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n`, appended to any
existing `GIT_CONFIG_COUNT` rather than overwriting it. The repository config
does not exist yet at clone time, so there is nowhere else to put them.

---

## 7. Arm the stall guard

`gvfs-helper` sets only `CURLOPT_CONNECTTIMEOUT_MS` — there is **no transfer
timeout**. A cache server that accepts a POST and then goes silent hangs the
clone *forever*. Observed 2026-08-26: an ESTABLISHED socket, `Recv-Q 0`, zero
bytes for 9 minutes, no `region_leave`.

```bash
export GIT_HTTP_LOW_SPEED_LIMIT=1000
export GIT_HTTP_LOW_SPEED_TIME=300
```

1000 B/s over 300 s trips only on a genuine stall — an order of magnitude below
the worst legitimate throughput observed (~350 KiB/s) — and lets gvfs-helper's
own retry logic recover instead of wedging the run.

---

## 8. Run cells back to back, on one box

Two independent reasons:

- **Time-of-day network variance is large.** Clone time measured **243–804 s**
  across otherwise identical configurations. All of that is network and host
  variance.
- **Hardware variance is larger still.** A second devbox indexed the same
  6.83 GB history pack **3.18x slower** (724 s vs 228 s). A number from another
  machine is not a valid baseline for yours.

**Therefore: always run the control cell on the same box, in the same session,
as the treatment cell.** Never compare against a published number from a
different machine. That is what the on-box control is for.

---

## 9. Record the environment

Fill in `ENVIRONMENT.md` before you start. Hardware, kernel, and whether you are
on WSL all matter for interpreting results later.

---

## Pre-flight checklist

```
[ ] git ls-remote against the target repo succeeds
[ ] systemctl --user list-timers 'git-maintenance*' → 0
[ ] git config --global --get-all maintenance.repo → 0 lines
[ ] pgrep -ax git-gvfs-helper → empty
[ ] ≥ 40 GB free on the work volume
[ ] git --version reports the pinned build
[ ] git --exec-path matches the pinned prefix
[ ] ENVIRONMENT.md filled in
```
