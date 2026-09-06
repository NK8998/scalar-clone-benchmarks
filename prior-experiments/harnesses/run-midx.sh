#!/bin/bash
# =============================================================================
# run-midx.sh -- does writing a multi-pack-index before backfill speed it up?
#
#   bash ./run-midx.sh            # both cells: midx OFF (control) then ON
#   bash ./run-midx.sh on         # treatment only
#   bash ./run-midx.sh off        # control only
#
# Both cells are the C6 FULL STACK -- --no-prefetch + gvfs.postThreads=8 +
# new prefetch endpoint + --full-clone -- and both run the SAME binary
# ($ROOT/builds/midx, branch eval/midx-before-backfill). The only difference
# is `--no-midx`, so nothing but the multi-pack-index can explain a delta.
#
# Why an on-box control is mandatory: devbox B's c6 backfill was 795 s, but
# 724 s of that was `index-pack` on the single 6.83 GB history pack, and this
# box indexes that same pack 3.18x faster (227.62 s vs 724.36 s). Devbox B's
# 795 s is therefore NOT a valid baseline here. The control cell supplies one.
#
# The hypothesis under test: `index-pack` calls sha1_object() -> ODB lookup for
# every object written, and with ~100 packfiles and no midx each lookup is one
# binary search PER PACK. A controlled A/B (empty vs 220-pack ODB, order
# reversed) measured 50.5 s vs 113.3 s on an identical pack.
#
# Expected effect size is modest -- extrapolating that A/B to 17.5M objects
# over ~100 packs predicts roughly 60-100 s of the ~230 s backfill on this box,
# not the whole gap. A null result is still worth recording.
#
# Guarantees per cell, matching devbox-A.sh so numbers stay comparable:
#   * its OWN private object cache (--local-cache-path), asserted after clone
#   * full trace2 capture (event + perf) including gvfs-helper children
#   * every metric recorded BEFORE teardown
#   * enlistment AND cache deleted as soon as the cell is recorded
#   * background maintenance quiesced before and after
#
# Completed cells are skipped, so re-running after a failure is safe.
# =============================================================================
set -euo pipefail

VARIANTS=( "$@" )
[ ${#VARIANTS[@]} -eq 0 ] && VARIANTS=( off on )

ROOT="${ROOT:-$HOME/scalar-tests}"
PREFIX="${PREFIX:-$ROOT/builds/midx}"
BASE_PREFIX="${BASE_PREFIX:-$ROOT/builds/base}"
REPO_URL="${REPO_URL:-https://office.visualstudio.com/DefaultCollection/Office/_git/1JS}"
NEW_ENDPOINT="${NEW_ENDPOINT:-https://gitcache.microsoft.engineering/49b0c9f4-555f-4624-8157-a57e6df513b3}"
POST_THREADS="${POST_THREADS:-8}"
SSL_BACKEND="${SSL_BACKEND:-openssl}"
CELL_GAP="${CELL_GAP:-0}"
# Cells are named "$RUNTAG-$variant" so a repeat run never clobbers an old one.
RUNTAG="${RUNTAG:-c6midx}"
SUMMARY="$ROOT/summary-$RUNTAG.csv"

mkdir -p "$ROOT/runs" "$ROOT/enl" "$ROOT/cache"

log() { printf '\n\033[1m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

for v in "${VARIANTS[@]}"; do
    case "$v" in
        on|off|c2|c5) ;;
        *) die "unknown variant '$v' (expected: c2, c5, off, on)" ;;
    esac
done

# Per-variant test matrix. c2 is the reference config: the stock `base` build
# with inline prefetch and a single POST thread, pointed at the new endpoint.
# off/on are the c6 full stack (--no-prefetch, 8 POST threads, new endpoint)
# on ONE binary, differing only by --no-midx.
variant_build()   { case "$1" in c2) echo "$BASE_PREFIX" ;; *) echo "$PREFIX" ;; esac; }
variant_threads() { case "$1" in c2|c5) echo 1 ;; *) echo "$POST_THREADS" ;; esac; }
variant_label()   {
    case "$1" in
        c2)  echo "base build, inline prefetch, 1 POST thread, new endpoint" ;;
        c5)  echo "c6 full stack but 1 POST thread (serial blob POSTs), WITH multi-pack-index" ;;
        off) echo "c6 full stack, NO multi-pack-index (control)" ;;
        on)  echo "c6 full stack, WITH multi-pack-index" ;;
    esac
}

quiesce() {
    systemctl --user stop    'git-maintenance@*.timer' >/dev/null 2>&1 || true
    systemctl --user disable 'git-maintenance@*.timer' >/dev/null 2>&1 || true
    git config --global --unset-all maintenance.repo >/dev/null 2>&1 || true
    local p
    for p in $(pgrep -x git-gvfs-helper 2>/dev/null || true); do kill "$p" 2>/dev/null || true; done
    local t r
    t=$(systemctl --user list-timers 'git-maintenance*' --no-legend 2>/dev/null | wc -l)
    r=$(git config --global --get-all maintenance.repo 2>/dev/null | wc -l || true)
    echo "  quiesce: timers=$t maintenance.repo=$r"
}
drop_caches() {
    sync
    if sudo -n /usr/local/sbin/drop-caches 2>/dev/null; then return 0; fi
    sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null \
        || echo "  note: could not drop page cache (needs sudo); timings may be optimistic"
}

# --- verify each binary under test really is what we think it is -------------
need_midx_build=0; need_base_build=0
for v in "${VARIANTS[@]}"; do
    case "$v" in c2) need_base_build=1 ;; *) need_midx_build=1 ;; esac
done

if [ "$need_midx_build" = 1 ]; then
    [ -x "$PREFIX/bin/scalar" ] || die "no scalar at $PREFIX/bin/scalar -- build it first"
    # Process substitution, not a pipe: under `set -o pipefail` a `grep -q` that
    # exits early makes the producer die of SIGPIPE and the whole test read as fail.
    if ! grep -q -- '--\[no-\]midx' < <("$PREFIX/bin/scalar" clone -h 2>&1); then
        die "$PREFIX/bin/scalar has no --[no-]midx option; wrong build?"
    fi
    log "midx build:  $("$PREFIX/bin/git" --version)  ($PREFIX)"
fi

if [ "$need_base_build" = 1 ]; then
    [ -x "$BASE_PREFIX/bin/scalar" ] || die "no scalar at $BASE_PREFIX/bin/scalar"
    # The reference build must NOT know about --midx, or it isn't the baseline.
    if grep -q -- '--\[no-\]midx' < <("$BASE_PREFIX/bin/scalar" clone -h 2>&1); then
        die "$BASE_PREFIX unexpectedly HAS --[no-]midx; that is not the base build"
    fi
    log "base build:  $("$BASE_PREFIX/bin/git" --version)  ($BASE_PREFIX)"
fi

run_cell() {
    local variant=$1
    local cell="$RUNTAG-$variant"
    local out="$ROOT/runs/$cell"
    local enl="$ROOT/enl/$cell"
    local cache="$ROOT/cache/$cell"
    local vprefix vthreads
    vprefix=$(variant_build "$variant")
    vthreads=$(variant_threads "$variant")

    if [ -f "$out/result.txt" ] && grep -q '^total_s=' "$out/result.txt"; then
        log "cell $cell already complete, skipping"
        return 0
    fi

    log "cell $cell  ($(variant_label "$variant"))"

    quiesce
    rm -rf "$out" "$enl" "$cache"
    mkdir -p "$out"
    drop_caches

    (
        export PATH="$vprefix/bin:$PATH"

        # git resolves its helpers -- notably git-gvfs-helper -- via its
        # COMPILED-IN exec-path, NOT via PATH. A relocated build (e.g. a
        # release .deb unpacked outside /usr/local) therefore silently runs
        # whatever git-gvfs-helper is installed system-wide. Observed
        # 2026-09-02: a 2.55.0.vfs.0.8-midx.2 git spawning the Jan-2026 system
        # helper, which stalled the clone at 5 KB for 8 minutes. Pin and assert.
        if [ -d "$vprefix/libexec/git-core" ]; then
            export GIT_EXEC_PATH="$vprefix/libexec/git-core"   # autotools build
        elif [ -d "$vprefix/lib/git-core" ]; then
            export GIT_EXEC_PATH="$vprefix/lib/git-core"       # .deb layout
        else
            die "no git-core dir under $vprefix (looked in libexec/ and lib/)"
        fi
        [ -x "$GIT_EXEC_PATH/git-gvfs-helper" ] \
            || die "no git-gvfs-helper in $GIT_EXEC_PATH"

        rs=$(command -v scalar || true); rg=$(command -v git || true)
        [ "$rs" = "$vprefix/bin/scalar" ] || die "scalar resolves to '$rs', expected '$vprefix/bin/scalar'"
        [ "$rg" = "$vprefix/bin/git" ]    || die "git resolves to '$rg', expected '$vprefix/bin/git'"
        rx=$(git --exec-path)
        [ "$rx" = "$GIT_EXEC_PATH" ] \
            || die "git --exec-path='$rx', expected '$GIT_EXEC_PATH' -- helpers would come from the wrong build"

        git_env_add() {
            local n=${GIT_CONFIG_COUNT:-0}
            export "GIT_CONFIG_KEY_$n=$1" "GIT_CONFIG_VALUE_$n=$2"
            export GIT_CONFIG_COUNT=$((n + 1))
        }
        # ~/.gitconfig pins gnutls; locally-compiled builds link OpenSSL, but
        # the released .deb links gnutls. Must be in the ENVIRONMENT so it
        # reaches gvfs-helper children. Override with SSL_BACKEND=gnutls when
        # testing a release build.
        git_env_add http.sslBackend "$SSL_BACKEND"
        # The repo config does not exist yet at clone time, so postThreads must
        # also travel via the environment. `scalar -c` does NOT reach children.
        git_env_add gvfs.postThreads "$vthreads"
        git_env_add credential.interactive never

        # Stall guard. gvfs-helper sets only CONNECTTIMEOUT; http.c arms a
        # transfer timeout solely when both low-speed knobs are > 0, and they
        # default to -1. Without this a cache-server POST that connects but
        # never answers hangs FOREVER (observed 2026-08-26: ESTAB socket,
        # Recv-Q 0, zero bytes for 9 min, no region_leave). 1000 B/s for 300 s
        # only trips on a true stall -- an order of magnitude under the worst
        # legitimate ADO throughput seen (~350 KiB/s) -- and lets gvfs-helper's
        # existing retry logic recover instead of wedging the run.
        export GIT_HTTP_LOW_SPEED_LIMIT=1000
        export GIT_HTTP_LOW_SPEED_TIME=300

        export GIT_TRACE2_EVENT_NESTING=10
        export GIT_TRACE2_PERF_BRIEF=1

        clone=( --local-cache-path "$cache" --prefetch-cache-server-url="$NEW_ENDPOINT"
                --full-clone )
        case "$variant" in
            c2)  ;;                                    # inline prefetch, stock build
            c5)  clone+=( --no-prefetch ) ;;           # deferred, serial POSTs, midx on
            off) clone+=( --no-prefetch --no-midx ) ;; # deferred, control
            on)  clone+=( --no-prefetch ) ;;           # deferred, treatment
        esac

        {
            echo "cell=$cell"
            echo "variant=$variant"
            echo "description=$(variant_label "$variant")"
            echo "scope=full"
            echo "midx=$variant"
            case "$variant" in
                c2) echo "build=base"
                    echo "build_branch=stock"
                    echo "build_sha=$(awk -F= '$1=="sha"{print $2}' "$vprefix/BUILD-INFO.txt" 2>/dev/null || echo '?')" ;;
                *)  echo "build=midx"
                    echo "build_branch=eval/midx-before-backfill"
                    echo "build_sha=$(git -C /home/t-neilkainga/clone_tests/upstream/wt-midx rev-parse HEAD 2>/dev/null || echo '?')" ;;
            esac
            echo "prefix=$vprefix"
            echo "version=$("$vprefix/bin/git" --version)"
            echo "clone_args=${clone[*]}"
            echo "gvfs.postThreads=$vthreads"
            echo "http.sslBackend=$SSL_BACKEND"
            echo "exec_path=$GIT_EXEC_PATH"
            echo "gvfs_helper=$(ls -l "$GIT_EXEC_PATH/git-gvfs-helper" | awk '{print $6,$7,$8}')"
            echo "http_low_speed=${GIT_HTTP_LOW_SPEED_LIMIT}B/s over ${GIT_HTTP_LOW_SPEED_TIME}s"
            echo "private_cache=$cache"
            echo "started=$(date -Is)"
        } | tee "$out/meta.txt"

        # ---- phase 1: clone (includes the midx write when variant=on) -------
        export GIT_TRACE2_EVENT="$out/clone.event.json"
        export GIT_TRACE2_PERF="$out/clone.perf.txt"
        t0=$SECONDS
        scalar clone "${clone[@]}" "$REPO_URL" "$enl" 2>&1 | tee "$out/clone.log"
        t_clone=$((SECONDS - t0))
        unset GIT_TRACE2_EVENT GIT_TRACE2_PERF

        wt="$enl/src"; [ -d "$wt" ] || wt="$enl"
        echo "$wt" > "$out/worktree.txt"

        # ---- verify the private cache is real and wired ---------------------
        shared=$(git -C "$wt" config gvfs.sharedCache || true)
        case "$shared" in
            "$cache"/*|"$cache") ;;
            *) die "gvfs.sharedCache='$shared' is NOT inside private cache '$cache'" ;;
        esac
        alt="$wt/.git/objects/info/alternates"
        [ -s "$alt" ] || die "missing/empty $alt -- shared cache never consulted"
        grep -q "^$cache" "$alt" || die "alternates does not point at $cache: $(cat "$alt")"
        echo "cache_ok=$shared" | tee "$out/cache.txt"

        # ---- verify the midx knob actually did what was asked ---------------
        # This is the whole experiment; if it silently no-ops the run is void.
        midx_file=$(ls "$cache"/*/pack/multi-pack-index 2>/dev/null | head -1 || true)
        if [ "$variant" = on ] || [ "$variant" = c5 ]; then
            [ -n "$midx_file" ] || die "variant=$variant but NO multi-pack-index in $cache"
            midx_bytes=$(stat -c%s "$midx_file")
            echo "midx_present=1 midx_bytes=$midx_bytes" | tee "$out/midx.txt"
        else
            [ -z "$midx_file" ] || die "variant=$variant but a multi-pack-index EXISTS at $midx_file"
            midx_bytes=0
            echo "midx_present=0 midx_bytes=0" | tee "$out/midx.txt"
        fi

        # ---- phase 2: scope is a no-op for --full-clone ---------------------
        t_scope=0

        payload_bytes() { du -sb "$wt/.git" "$cache" 2>/dev/null | awk '{s+=$1} END{print s+0}'; }
        all_packs() { ls "$wt/.git/objects/pack/"*.pack "$cache"/*/pack/*.pack 2>/dev/null || true; }

        usable_bytes=$(payload_bytes)
        usable_packs=$(all_packs | wc -l)

        # ---- phase 3: deferred back-fill (the phase under test) -------------
        export GIT_TRACE2_EVENT="$out/backfill.event.json"
        export GIT_TRACE2_PERF="$out/backfill.perf.txt"
        t2=$SECONDS
        git -C "$wt" maintenance run --task=prefetch 2>&1 | tee "$out/backfill.log"
        t_backfill=$((SECONDS - t2))
        unset GIT_TRACE2_EVENT GIT_TRACE2_PERF

        # ---- record EVERYTHING before teardown ------------------------------
        all_packs | xargs -r ls -lS 2>/dev/null | awk '{print $5, $9}' > "$out/pack-sizes.txt" || true
        # NOTE: a `rev-list --objects --all` census used to run here. Its output
        # went to /dev/null, so it produced nothing, but in a GVFS repo it
        # triggers on-demand fetching (observed 2026-08-26: 402 MB at ~1.9 MB/s
        # and still climbing after 9 min) and it ran BEFORE packs_final /
        # payload_final_bytes / cache_bytes are computed below, inflating them
        # by ~460 MB. Removed: it cost ~10 min and bought nothing.

        packs=$(all_packs | wc -l)
        biggest=$(awk 'NR==1{print $1}' "$out/pack-sizes.txt" 2>/dev/null || echo 0)
        commits=$(git -C "$wt" rev-list --count --all 2>/dev/null || echo 0)

        {
            echo "cell=$cell"
            echo "variant=$variant"
            echo "scope=full"
            echo "midx=$variant"
            echo "midx_bytes=$midx_bytes"
            case "$variant" in
                c2) echo "build=base"; echo "no_prefetch=0" ;;
                *)  echo "build=midx"; echo "no_prefetch=1" ;;
            esac
            echo "post_threads=$vthreads"
            echo "new_endpoint=1"
            echo "clone_s=$t_clone"
            echo "scope_s=$t_scope"
            echo "time_to_usable_s=$((t_clone + t_scope))"
            echo "backfill_s=$t_backfill"
            echo "total_s=$((t_clone + t_scope + t_backfill))"
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

    if [ ! -f "$SUMMARY" ]; then
        echo "cell,midx,midx_bytes,clone_s,backfill_s,total_s,packs_at_usable,packs_final,largest_pack_bytes,payload_at_usable_bytes,payload_final_bytes,commits" > "$SUMMARY"
    fi
    awk -F= '{v[$1]=$2} END{
        printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
        v["cell"],v["midx"],v["midx_bytes"],v["clone_s"],v["backfill_s"],
        v["total_s"],v["packs_at_usable"],v["packs_final"],v["largest_pack_bytes"],
        v["payload_at_usable_bytes"],v["payload_final_bytes"],v["commits"]}' \
        "$out/result.txt" >> "$SUMMARY"
}

log "midx A/B  variants=[${VARIANTS[*]}]  root=$ROOT"
quiesce

first=1
for v in "${VARIANTS[@]}"; do
    if [ "$first" = 0 ] && [ "$CELL_GAP" -gt 0 ]; then
        log "cooldown ${CELL_GAP}s"
        sleep "$CELL_GAP"
    fi
    first=0
    run_cell "$v"
done

log "DONE"
echo "  results: $SUMMARY"
column -s, -t < "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
echo
echo "Traces retained under $ROOT/runs/ (enlistments and caches deleted)."
