#!/usr/bin/env bash
# =============================================================================
# midx vs. git-maintenance  --  deferred-backfill matrix
#
# One binary, six cells. The cells differ ONLY in the flags handed to
# `scalar clone` and in what drives the backfill afterwards.
#
#   A  midx-on       --midx    --no-maintenance-now   harness runs prefetch
#   B  midx-off      --no-midx --no-maintenance-now   harness runs prefetch      (control)
#   C  maint-now     --no-midx --maintenance-now      scalar starts it; we watch
#   D  timer         --no-midx --no-maintenance-now   NOTHING. timers left armed.
#   E  maint-daily   --no-midx --no-maintenance-now   harness runs --schedule=daily
#   F  repack-first  --no-midx --no-maintenance-now   harness runs repack, then prefetch
#
# Read PREREQUISITES.md before running. Every guard below is here because its
# absence voided a real run at least once.
#
#   ./run.sh A B          # the reference pair -- run these adjacently
#   ./run.sh C E F
#   ./run.sh D            # last: idles up to an hour by design
#
# Cells are resumable: a cell with a completed result.txt is skipped.
# =============================================================================
set -euo pipefail

# ---- configuration ----------------------------------------------------------
REPO_URL=${REPO_URL:-https://office.visualstudio.com/DefaultCollection/Office/_git/1JS}

# The new prefetch cache-server endpoint. The GUID is the 1JS repositoryId.
# Every cell must use this -- mixing endpoints across cells invalidates the
# comparison, so it is deliberately not per-cell configurable.
NEW_ENDPOINT=${NEW_ENDPOINT:-https://gitcache.microsoft.engineering/49b0c9f4-555f-4624-8157-a57e6df513b3}

VERSION=${VERSION:-2.55.0.vfs.0.8-midx.2}
PREFIX=${PREFIX:-$HOME/.1js/git/$VERSION}

POST_THREADS=${POST_THREADS:-8}
# Release .deb links gnutls; locally compiled builds link OpenSSL.
SSL_BACKEND=${SSL_BACKEND:-gnutls}

ROOT=${ROOT:-$HOME/scalar-tests}
RUNTAG=${RUNTAG:-$(date +%m%d)}
CELL_GAP=${CELL_GAP:-60}          # cooldown between cells, seconds

# Completion detection for the cells we observe rather than drive (C, D).
POLL_S=${POLL_S:-5}               # how often to sample
STABLE_S=${STABLE_S:-90}          # quiet period before declaring "done"
# Worst-case idle is one schedule period (~3600 s): the hourly unit covers hours
# 1-23 and the daily/weekly units cover hour 0, and because the schedule enum is
# inverted those runs include the hourly tasks too. 5400 s leaves headroom for a
# slow tick without letting a genuinely stuck cell run all night.
MAX_IDLE_S=${MAX_IDLE_S:-5400}    # give up waiting for backfill to START
MAX_RUN_S=${MAX_RUN_S:-10800}     # give up waiting for it to FINISH

STAMP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/systemd/timers"
SUMMARY="$ROOT/summary-$RUNTAG.csv"

CELLS=("$@")
[ ${#CELLS[@]} -gt 0 ] || CELLS=(A B)

log()  { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

# ---- cell definitions -------------------------------------------------------
cell_name() {
    case "$1" in
        A) echo midx-on ;;      B) echo midx-off ;;     C) echo maint-now ;;
        D) echo timer ;;        E) echo maint-daily ;;  F) echo repack-first ;;
        *) die "unknown cell '$1' (expected one of A B C D E F)" ;;
    esac
}
cell_label() {
    case "$1" in
        A) echo "midx written before backfill; harness triggers prefetch" ;;
        B) echo "no midx; harness triggers prefetch (control)" ;;
        C) echo "no midx; scalar kicks off maintenance immediately" ;;
        D) echo "no midx, no kickoff; wait for the systemd timer" ;;
        E) echo "no midx; harness runs the full daily schedule" ;;
        F) echo "no midx; harness runs incremental-repack then prefetch" ;;
    esac
}
# Extra flags beyond the common --no-prefetch.
cell_flags() {
    case "$1" in
        A)       echo "--midx --no-maintenance-now" ;;
        C)       echo "--no-midx --maintenance-now" ;;
        B|D|E|F) echo "--no-midx --no-maintenance-now" ;;
    esac
}
# Does the harness drive the backfill, or merely observe it?
cell_driven() {
    case "$1" in C|D) echo 0 ;; *) echo 1 ;; esac
}
# Does this cell need the systemd timers left armed?
cell_wants_timers() {
    case "$1" in D) echo 1 ;; *) echo 0 ;; esac
}

# ---- environment hygiene ----------------------------------------------------
quiesce() {
    disarm_timers
    clear_timer_stamps
    local p
    for p in $(pgrep -x git-gvfs-helper 2>/dev/null || true); do
        kill "$p" 2>/dev/null || true
    done
    local t r s
    t=$(systemctl --user list-timers 'git-maintenance*' --no-legend 2>/dev/null | wc -l)
    r=$(git config --global --get-all maintenance.repo 2>/dev/null | wc -l || true)
    s=$(ls "$STAMP_DIR"/stamp-git-maintenance@* 2>/dev/null | wc -l)
    echo "  quiesce: timers=$t maintenance.repo=$r stamps=$s" >&2
}

# ---------------------------------------------------------------------------
# Delete the systemd timer stamps.
#
# This is NOT housekeeping -- it is a correctness requirement, and leaving it
# out silently corrupts every cell after the first.
#
# The maintenance timers ship Persistent=true. `scalar clone` re-enables them
# during registration in EVERY cell, including cells that passed
# --no-maintenance-now, because registration and the kickoff are separate steps.
# If a stamp from a previous cell is lying around, systemd treats the timer as
# overdue and fires a catch-up tick THE MOMENT it is enabled -- launching a
# background `git maintenance run --schedule=hourly` that competes with the
# backfill we are trying to time.
#
# Measured directly with a probe unit on this box:
#
#     no stamp      -> catch-up does NOT fire
#     stale stamp   -> catch-up FIRES immediately on enable
#
# Clearing the stamps forces the first case, which is also the honest one: a
# developer's first-ever clone is on a machine that has never run maintenance
# and therefore has no stamp. Cell D depends on this outright -- with a stale
# stamp it would report a few seconds of idle instead of the real wait, which
# is a fabricated number that looks entirely plausible.
# ---------------------------------------------------------------------------
clear_timer_stamps() {
    rm -f "$STAMP_DIR"/stamp-git-maintenance@*.timer 2>/dev/null || true
}

# Stop the timers WITHOUT killing anything already running. `scalar clone`
# re-arms the timers during registration even when --no-maintenance-now was
# passed, so an hourly tick could otherwise fire mid-measurement and compete
# for bandwidth with the backfill we are timing. Cell D is the sole exception:
# the timer IS its subject.
disarm_timers() {
    systemctl --user stop    'git-maintenance@*.timer' >/dev/null 2>&1 || true
    systemctl --user disable 'git-maintenance@*.timer' >/dev/null 2>&1 || true
    git config --global --unset-all maintenance.repo   >/dev/null 2>&1 || true
}

drop_caches() {
    sync
    sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null \
        || echo "  note: could not drop page cache (needs sudo); timings will be optimistic"
}

# ---- build verification -----------------------------------------------------
[ -x "$PREFIX/bin/scalar" ] || die "no scalar at $PREFIX/bin/scalar -- see GIT-BUILDS.md"
[ -x "$PREFIX/bin/git" ]    || die "no git at $PREFIX/bin/git -- see GIT-BUILDS.md"

# Process substitution, not a pipe: under `set -o pipefail` a `grep -q` that
# exits early makes the producer die of SIGPIPE and the test reads as failure.
for opt in '--\[no-\]prefetch' '--\[no-\]midx' '--\[no-\]maintenance-now'; do
    grep -q -- "$opt" < <("$PREFIX/bin/scalar" clone -h 2>&1) \
        || die "$PREFIX/bin/scalar lacks $opt -- wrong build? see GIT-BUILDS.md"
done
grep -q -- '--prefetch-cache-server-url' < <("$PREFIX/bin/scalar" clone -h 2>&1) \
    || die "$PREFIX/bin/scalar lacks --prefetch-cache-server-url"

log "build: $("$PREFIX/bin/git" --version)   ($PREFIX)"

mkdir -p "$ROOT/runs"

# =============================================================================
# wait_for_backfill <cache-dir> <out-dir>
#
# For cells C and D the backfill runs detached, so there is no command to time.
# We infer it: growth in the object cache means it is running; a quiet period
# with no relevant process alive means it has stopped.
#
# Prints "<idle_s> <backfill_s>" on stdout.
# =============================================================================
wait_for_backfill() {
    local cache=$1 out=$2
    local t_zero=$SECONDS
    local started=0 t_start=0 last_change=0
    local prev=-1 cur quiet now

    : > "$out/watch.log"

    while :; do
        now=$((SECONDS - t_zero))
        cur=$(du -sb "$cache" 2>/dev/null | cut -f1 || echo 0)

        local alive=0
        pgrep -x git-gvfs-helper >/dev/null 2>&1 && alive=1
        pgrep -f 'maintenance run'  >/dev/null 2>&1 && alive=1
        pgrep -x git-index-pack  >/dev/null 2>&1 && alive=1
        pgrep -x git-multi-pack-index >/dev/null 2>&1 && alive=1

        echo "$now bytes=$cur alive=$alive started=$started" >> "$out/watch.log"

        if [ "$started" = 0 ]; then
            # Backfill has begun once the cache grows past a threshold that a
            # little metadata churn cannot reach, or a worker appears.
            if { [ "$prev" -ge 0 ] && [ "$cur" -gt $((prev + 50000000)) ]; } \
               || [ "$alive" = 1 ]; then
                started=1
                t_start=$now
                last_change=$now
                log "  backfill started after ${t_start}s idle"
            elif [ "$now" -gt "$MAX_IDLE_S" ]; then
                echo "-1 -1"
                return 0
            fi
        else
            if [ "$cur" != "$prev" ] || [ "$alive" = 1 ]; then
                last_change=$now
            fi
            quiet=$((now - last_change))
            if [ "$quiet" -ge "$STABLE_S" ] && [ "$alive" = 0 ]; then
                echo "$t_start $((last_change - t_start))"
                return 0
            fi
            if [ "$now" -gt "$MAX_RUN_S" ]; then
                echo "$t_start -1"
                return 0
            fi
        fi

        prev=$cur
        sleep "$POLL_S"
    done
}

# =============================================================================
run_cell() {
    local c=$1
    local name; name=$(cell_name "$c")
    local cell="$RUNTAG-$name"
    local out="$ROOT/runs/$cell"
    local enl="$ROOT/enl/$cell"
    local cache="$ROOT/cache/$cell"

    if [ -f "$out/result.txt" ] && grep -q '^total_s=' "$out/result.txt"; then
        log "cell $cell already complete, skipping"
        return 0
    fi

    log "cell $cell  ($(cell_label "$c"))"

    quiesce
    rm -rf "$out" "$enl" "$cache"
    mkdir -p "$out"
    drop_caches

    # Cell D depends on systemd stamp state: Persistent= catch-up fires when a
    # STALE stamp exists but not when there is NO stamp. Record it so the result
    # can be interpreted afterwards.
    systemctl --user show 'git-maintenance@hourly.timer' \
        -p LastTriggerUSec -p Persistent > "$out/timer-state.txt" 2>&1 || true

    (
        export PATH="$PREFIX/bin:$PATH"

        # Git resolves its helpers -- notably git-gvfs-helper -- via its
        # COMPILED-IN exec-path, NOT via PATH. A relocated build therefore
        # silently runs whatever helper is installed system-wide. Observed
        # 2026-09-02: a -midx.2 git spawning the Jan-2026 system helper, which
        # stalled the clone at 5 KB for 8 minutes. Pin it, then assert it.
        if   [ -d "$PREFIX/lib/git-core" ];     then export GIT_EXEC_PATH="$PREFIX/lib/git-core"
        elif [ -d "$PREFIX/libexec/git-core" ]; then export GIT_EXEC_PATH="$PREFIX/libexec/git-core"
        else die "no git-core dir under $PREFIX (looked in lib/ and libexec/)"
        fi
        [ -x "$GIT_EXEC_PATH/git-gvfs-helper" ] || die "no git-gvfs-helper in $GIT_EXEC_PATH"

        rs=$(command -v scalar || true); rg=$(command -v git || true)
        [ "$rs" = "$PREFIX/bin/scalar" ] || die "scalar resolves to '$rs', expected '$PREFIX/bin/scalar'"
        [ "$rg" = "$PREFIX/bin/git" ]    || die "git resolves to '$rg', expected '$PREFIX/bin/git'"
        rx=$(git --exec-path)
        [ "$rx" = "$GIT_EXEC_PATH" ] \
            || die "git --exec-path='$rx', expected '$GIT_EXEC_PATH' -- helpers would come from the wrong build"

        git_env_add() {
            local n=${GIT_CONFIG_COUNT:-0}
            export "GIT_CONFIG_KEY_$n=$1" "GIT_CONFIG_VALUE_$n=$2"
            export GIT_CONFIG_COUNT=$((n + 1))
        }
        # These must be in the ENVIRONMENT, not `scalar -c`: postThreads has to
        # reach the gvfs-helper CHILDREN, and the repo config does not exist yet
        # at clone time.
        git_env_add http.sslBackend       "$SSL_BACKEND"
        git_env_add gvfs.postThreads      "$POST_THREADS"
        git_env_add credential.interactive never

        # Stall guard. gvfs-helper sets only CONNECTTIMEOUT; http.c arms a
        # transfer timeout solely when both low-speed knobs are > 0, and they
        # default to -1. Without this, a cache-server POST that connects but
        # never answers hangs FOREVER (observed 2026-08-26: ESTAB socket,
        # Recv-Q 0, zero bytes for 9 min). 1000 B/s over 300 s trips only on a
        # true stall and lets gvfs-helper's own retry logic recover.
        export GIT_HTTP_LOW_SPEED_LIMIT=1000
        export GIT_HTTP_LOW_SPEED_TIME=300

        export GIT_TRACE2_EVENT_NESTING=10
        export GIT_TRACE2_PERF_BRIEF=1

        read -r -a extra <<< "$(cell_flags "$c")"
        clone=( --local-cache-path "$cache"
                --prefetch-cache-server-url="$NEW_ENDPOINT"
                --full-clone --no-prefetch "${extra[@]}" )

        {
            echo "cell=$cell"
            echo "letter=$c"
            echo "description=$(cell_label "$c")"
            echo "version=$("$PREFIX/bin/git" --version)"
            echo "prefix=$PREFIX"
            echo "clone_args=${clone[*]}"
            echo "driven=$(cell_driven "$c")"
            echo "timers_armed=$(cell_wants_timers "$c")"
            echo "gvfs.postThreads=$POST_THREADS"
            echo "http.sslBackend=$SSL_BACKEND"
            echo "endpoint=$NEW_ENDPOINT"
            echo "exec_path=$GIT_EXEC_PATH"
            echo "gvfs_helper_mtime=$(stat -c%y "$GIT_EXEC_PATH/git-gvfs-helper")"
            echo "http_low_speed=${GIT_HTTP_LOW_SPEED_LIMIT}B/s over ${GIT_HTTP_LOW_SPEED_TIME}s"
            echo "private_cache=$cache"
            echo "started=$(date -Is)"
        } | tee "$out/meta.txt"

        # ---- phase 1: clone --------------------------------------------------
        export GIT_TRACE2_EVENT="$out/clone.event.json"
        export GIT_TRACE2_PERF="$out/clone.perf.txt"
        t0=$SECONDS
        scalar clone "${clone[@]}" "$REPO_URL" "$enl" 2>&1 | tee "$out/clone.log"
        t_clone=$((SECONDS - t0))
        unset GIT_TRACE2_EVENT GIT_TRACE2_PERF

        wt="$enl/src"; [ -d "$wt" ] || wt="$enl"
        echo "$wt" > "$out/worktree.txt"

        # ---- verify the maintenance-now knob did what was asked -------------
        # Same reasoning as the midx assertion below: a silently ignored flag
        # would not fail, it would just quietly run a SECOND backfill alongside
        # the one being timed, contending for bandwidth and corrupting both the
        # duration and the byte counts.
        kick=0
        pgrep -f 'maintenance run'   >/dev/null 2>&1 && kick=1
        pgrep -x git-gvfs-helper     >/dev/null 2>&1 && kick=1
        if [ "$c" = C ]; then
            [ "$kick" = 1 ] || log "  note: --maintenance-now kickoff not yet visible; watcher will confirm"
        else
            [ "$kick" = 0 ] \
                || die "cell $c passed --no-maintenance-now but a maintenance/gvfs-helper process is running -- a second backfill would corrupt this measurement"
        fi
        echo "kickoff_observed=$kick" | tee "$out/kickoff.txt"

        # scalar re-arms the systemd timers during registration regardless of
        # --no-maintenance-now. Disarm them now so a scheduled tick cannot
        # compete with the backfill we are about to time. This does NOT kill
        # anything already running, so cell C's detached kickoff is untouched.
        if [ "$(cell_wants_timers "$c")" = 0 ]; then
            disarm_timers
        fi

        # ---- verify the private cache is real and wired ----------------------
        shared=$(git -C "$wt" config gvfs.sharedCache || true)
        case "$shared" in
            "$cache"/*|"$cache") ;;
            *) die "gvfs.sharedCache='$shared' is NOT inside private cache '$cache'" ;;
        esac
        alt="$wt/.git/objects/info/alternates"
        [ -s "$alt" ] || die "missing/empty $alt -- shared cache never consulted"
        grep -q "^$cache" "$alt" || die "alternates does not point at $cache: $(cat "$alt")"
        echo "cache_ok=$shared" | tee "$out/cache.txt"

        # ---- verify the midx knob actually did what was asked ----------------
        # This IS the experiment. A silently no-op'd flag would void the run.
        midx_file=$(ls "$cache"/*/pack/multi-pack-index 2>/dev/null | head -1 || true)
        if [ "$c" = A ]; then
            [ -n "$midx_file" ] || die "cell A asked for --midx but NO multi-pack-index exists in $cache"
            midx_bytes=$(stat -c%s "$midx_file")
        else
            [ -z "$midx_file" ] || die "cell $c asked for --no-midx but a multi-pack-index EXISTS at $midx_file"
            midx_bytes=0
        fi
        echo "midx_present=$([ "$midx_bytes" -gt 0 ] && echo 1 || echo 0) midx_bytes=$midx_bytes" \
            | tee "$out/midx.txt"

        payload_bytes() { du -sb "$wt/.git" "$cache" 2>/dev/null | awk '{s+=$1} END{print s+0}'; }
        all_packs()     { ls "$wt/.git/objects/pack/"*.pack "$cache"/*/pack/*.pack 2>/dev/null || true; }

        usable_bytes=$(payload_bytes)
        usable_packs=$(all_packs | wc -l)

        # ---- phase 2: backfill ----------------------------------------------
        export GIT_TRACE2_EVENT="$out/backfill.event.json"
        export GIT_TRACE2_PERF="$out/backfill.perf.txt"

        if [ "$(cell_driven "$c")" = 1 ]; then
            # `maintenance run --schedule=...` runs ZERO tasks and exits 0 when
            # maintenance.strategy is unset -- a silent no-op. scalar sets it
            # during registration; confirm before depending on it.
            strat=$(git -C "$wt" config maintenance.strategy || true)
            if [ "$c" = E ] && [ -z "$strat" ]; then
                die "maintenance.strategy is unset; --schedule=daily would run nothing"
            fi
            echo "maintenance_strategy=${strat:-<unset>}" | tee -a "$out/meta.txt"

            t2=$SECONDS
            case "$c" in
                E) git -C "$wt" maintenance run --schedule=daily 2>&1 | tee "$out/backfill.log" ;;
                F) git -C "$wt" maintenance run --task=incremental-repack 2>&1 | tee "$out/backfill.log"
                   git -C "$wt" maintenance run --task=prefetch          2>&1 | tee -a "$out/backfill.log" ;;
                *) git -C "$wt" maintenance run --task=prefetch          2>&1 | tee "$out/backfill.log" ;;
            esac
            t_backfill=$((SECONDS - t2))
            t_idle=0
        else
            # C: scalar already started it detached.
            # D: nothing started it; the systemd timer must.
            if [ "$(cell_wants_timers "$c")" = 1 ]; then
                log "  cell $c: leaving timers ARMED and waiting (up to $((MAX_IDLE_S / 60)) min)"
            else
                log "  cell $c: scalar kicked off maintenance; observing"
            fi
            read -r t_idle t_backfill < <(wait_for_backfill "$cache" "$out")
            [ "$t_idle"     != "-1" ] || log "  WARNING: backfill never started within ${MAX_IDLE_S}s"
            [ "$t_backfill" != "-1" ] || log "  WARNING: backfill did not finish within ${MAX_RUN_S}s"
        fi
        unset GIT_TRACE2_EVENT GIT_TRACE2_PERF

        # ---- record everything BEFORE teardown -------------------------------
        # NOTE: do NOT add a `rev-list --objects --all` census here. In a GVFS
        # repo it triggers on-demand fetching (observed: 402 MB at ~1.9 MB/s,
        # still climbing after 9 min) and inflates every byte count below.
        all_packs | xargs -r ls -lS 2>/dev/null | awk '{print $5, $9}' > "$out/pack-sizes.txt" || true

        packs=$(all_packs | wc -l)
        biggest=$(awk 'NR==1{print $1}' "$out/pack-sizes.txt" 2>/dev/null || echo 0)
        commits=$(git -C "$wt" rev-list --count --all 2>/dev/null || echo 0)
        final_midx=$(ls "$cache"/*/pack/multi-pack-index 2>/dev/null | head -1 || true)

        {
            echo "cell=$cell"
            echo "letter=$c"
            echo "midx_at_clone=$([ "$midx_bytes" -gt 0 ] && echo 1 || echo 0)"
            echo "midx_bytes=$midx_bytes"
            echo "midx_after_backfill=$([ -n "$final_midx" ] && echo 1 || echo 0)"
            echo "post_threads=$POST_THREADS"
            echo "clone_s=$t_clone"
            echo "idle_s=$t_idle"
            echo "backfill_s=$t_backfill"
            echo "time_to_usable_s=$t_clone"
            echo "total_s=$((t_clone + (t_idle > 0 ? t_idle : 0) + (t_backfill > 0 ? t_backfill : 0)))"
            echo "packs_at_usable=$usable_packs"
            echo "packs_final=$packs"
            echo "largest_pack_bytes=${biggest:-0}"
            echo "payload_at_usable_bytes=$usable_bytes"
            echo "payload_final_bytes=$(payload_bytes)"
            echo "cache_bytes=$(du -sb "$cache" 2>/dev/null | cut -f1)"
            echo "git_dir_bytes=$(du -sb "$wt/.git" 2>/dev/null | cut -f1)"
            echo "commits=$commits"
            echo "finished=$(date -Is)"
        } | tee "$out/result.txt"

        scalar unregister "$enl" >/dev/null 2>&1 || true
        git -C "$wt" maintenance unregister --force >/dev/null 2>&1 || true
    )

    log "tearing down $cell"
    rm -rf "$enl" "$cache"
    quiesce
}

# ---- main -------------------------------------------------------------------
log "matrix: cells=[${CELLS[*]}]  root=$ROOT  tag=$RUNTAG"
quiesce

first=1
for c in "${CELLS[@]}"; do
    if [ "$first" = 0 ] && [ "$CELL_GAP" -gt 0 ]; then
        log "cooldown ${CELL_GAP}s"
        sleep "$CELL_GAP"
    fi
    first=0
    run_cell "$c"
done

log "DONE -- traces retained under $ROOT/runs/ (enlistments and caches deleted)"
echo "Collate with: ./analyze.sh"
