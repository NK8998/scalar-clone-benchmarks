# Getting the Git build

**All cells in this experiment use one single binary.** There is nothing to
compile. Download one `.deb`, unpack it, point at it.

Using one build across every cell is deliberate: it makes the comparison as
clean as it can be. The cells differ **only** in the command-line flags passed
to `scalar clone` and in what happens after the clone returns. No compiler
difference, no library difference, no version skew.

---

## The build

**`v2.55.0.vfs.0.8-midx.2`** — <https://github.com/NK8998/git/releases/tag/v2.55.0.vfs.0.8-midx.2>

A fork of `microsoft/git`, branched from `vfs-2.55.0`. It is the only build that
carries all four capabilities this matrix needs at once:

| capability | needed for | in latest official release? |
|---|---|---|
| `--prefetch-cache-server-url` | all cells | ✅ yes |
| `--no-prefetch` | all cells | ❌ **no** |
| `gvfs.postThreads` | all cells | ❌ no |
| `--[no-]midx` | cells A, B | ❌ no |
| `--[no-]maintenance-now` | cells C, D | ❌ no |

### Why not an official `microsoft/git` release?

Because none of them can run this matrix.

- `--no-prefetch` was merged to `vfs-2.55.0` in **PR #979 on 2026-08-26**, but
  the most recent official release, `v2.55.0.vfs.0.8`, was published
  **2026-08-11** — two weeks *earlier*. So `--no-prefetch` is currently in **no
  official release at all**. It is not on `main` either.
- `gvfs.postThreads` (parallel POST) is **PR #980**, still open and under
  review.
- `--midx` and `--maintenance-now` are fork-local.

Check whether that has changed before you start —
<https://github.com/microsoft/git/releases/latest>. If a newer release now
contains `--no-prefetch`, say so in your results; it does not change how you run
this matrix, but it is worth knowing.

---

## Install

Unpack the `.deb` into a **private prefix**. Do **not** `dpkg -i` it — that
would replace the system Git for everyone on the box and defeat the point of
pinning.

```bash
VER=2.55.0.vfs.0.8-midx.2
ARCH=amd64                       # or arm64
BASE=https://github.com/NK8998/git/releases/download/v$VER
PREFIX=$HOME/.1js/git/$VER

mkdir -p "$PREFIX" /tmp/gitdl && cd /tmp/gitdl
curl -fLO "$BASE/microsoft-git_${VER}_${ARCH}.deb"
curl -fLO "$BASE/SHA256SUMS"

# Verify before unpacking.
sha256sum -c --ignore-missing SHA256SUMS

dpkg-deb -x "microsoft-git_${VER}_${ARCH}.deb" "$PREFIX"
```

The `.deb` unpacks to a **`usr/local/`** tree, so the binaries land at
`$PREFIX/usr/local/bin` — not `$PREFIX/usr/bin`. Normalise that so the harness's
layout detection works:

```bash
[ -d "$PREFIX/usr/local" ] && cp -a "$PREFIX/usr/local/." "$PREFIX/" && rm -rf "$PREFIX/usr"
ls "$PREFIX/bin/git" "$PREFIX/bin/scalar" "$PREFIX/lib/git-core/git-gvfs-helper"
```

If you skip the normalisation, point `PREFIX` at `.../usr/local` instead. The
harness detects both `lib/git-core` (the `.deb` layout) and `libexec/git-core`
(an autotools build), but it will not go hunting through a `usr/local`
subdirectory for you.

### Expected checksums

Published in the release, reproduced here so you can verify without trusting
the download twice:

```
3cabead7c36b19d1f45f276529c98afd539799ff7286cc1015ff1347211c97d0  microsoft-git_2.55.0.vfs.0.8-midx.2_amd64.deb
d0c3e30bff7be7c674352764b94acb751735c86a2bf887ccae8b996d02eeb6c0  microsoft-git_2.55.0.vfs.0.8-midx.2_arm64.deb
```

---

## Verify the build is the right one

Run all four. The harness performs equivalent checks and refuses to start if any
fail, but check by hand once so you know the install is sound.

```bash
export PATH="$PREFIX/bin:$PATH"
export GIT_EXEC_PATH="$PREFIX/lib/git-core"

git --version
#   git version 2.55.0.vfs.0.8-midx.2

git --exec-path
#   must print $PREFIX/lib/git-core  — see PREREQUISITES.md §5

scalar clone -h 2>&1 | grep -E -- '--\[no-\](prefetch|midx|maintenance-now)'
#   must list all three

scalar clone -h 2>&1 | grep -- '--prefetch-cache-server-url'
#   must be present
```

> **`GIT_EXEC_PATH` is not optional.** Git finds `git-gvfs-helper` through its
> compiled-in exec-path, not `PATH`. A relocated build without this exported
> silently runs the *system* helper. This has already cost one run — see
> PREREQUISITES.md §5.

---

## Confirm the flags are real, not hardcoded

The entire matrix rests on `--midx` and `--maintenance-now` being genuinely
toggleable. Both default to **on** in this build, so if either were forced on
regardless of the flag, several cells would silently collapse into duplicates of
each other and still produce plausible-looking numbers.

They are not hardcoded. In `scalar.c` at the release tag both are ordinary
`OPT_BOOL` entries backing plain variables, and both call sites are gated:

```c
int ... midx = 1;
int maintenance_now = 1;

OPT_BOOL(0, "midx", &midx, ...),
OPT_BOOL(0, "maintenance-now", &maintenance_now, ...),

if (midx && write_shared_cache_midx())                  /* --no-midx skips */
if (maintenance && maintenance_now && start_maintenance_now())
```

Note the second one is gated on `maintenance` as well, so `--no-maintenance`
also suppresses the kickoff.

You can verify the shipped binary end to end in about a minute, against any
small public repo — `write_shared_cache_midx()` falls back to a plain
`multi-pack-index write` when `gvfs.sharedCache` is unset, so a non-GVFS repo
still exercises both paths:

```bash
W=$(mktemp -d)
probe() {
  local label=$1; shift
  GIT_TRACE2_EVENT="$W/$label.json" scalar clone "$@" \
      https://github.com/NK8998/scalar-clone-benchmarks.git "$W/$label" >/dev/null 2>&1
  echo "$label: midx-write=$(grep -qc '"multi-pack-index".*"write"' "$W/$label.json" && echo YES || echo NO)" \
       "kickoff=$(grep -q '"maintenance".*"run".*"--schedule=hourly"' "$W/$label.json" && echo YES || echo NO)"
  scalar unregister "$W/$label" >/dev/null 2>&1
}
probe OFF --no-midx --no-maintenance-now
probe ON  --midx    --maintenance-now
rm -rf "$W"
```

Measured on `2.55.0.vfs.0.8-midx.2`:

| flags | spawns `multi-pack-index write` | spawns `maintenance run --schedule=hourly` | midx on disk |
|---|---|---|---|
| `--no-midx --no-maintenance-now` | no | no | no |
| `--midx --maintenance-now` | yes | yes | yes |

If your build does not reproduce that table, **stop** — the matrix is not
measuring what it claims to.

---

## SSL backend

The release `.deb` links **gnutls**. Locally compiled builds link **OpenSSL**.
If `~/.gitconfig` pins `http.sslBackend`, it may not match.

The harness takes `SSL_BACKEND` as a variable and passes it through the
environment so it reaches `gvfs-helper` children. With the `.deb`:

```bash
SSL_BACKEND=gnutls ./run.sh
```

If you see TLS errors on the first cell, this is the first thing to change.

---

## If you would rather build from source

Not required, and not recommended for this matrix — but if you want a build with
*only* the upstream changes and none of the fork-local ones, note that you must
build from **`origin/vfs-2.55.0`**, not from a release tag, because
`--no-prefetch` is unreleased.

```bash
git clone https://github.com/microsoft/git
cd git && git checkout vfs-2.55.0
make -j"$(nproc)" prefix=$HOME/.1js/git/vfs-2.55.0-src NO_GETTEXT=1 all
make    prefix=$HOME/.1js/git/vfs-2.55.0-src NO_GETTEXT=1 install
```

Such a build has **no** `--midx` and **no** `--maintenance-now`, so it can only
run cell D. The autotools layout puts helpers in `libexec/git-core` rather than
`lib/git-core`; the harness detects both.
