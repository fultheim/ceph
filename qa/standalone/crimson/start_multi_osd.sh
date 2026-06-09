#!/bin/bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 [options] <NUM_OSDS> <SIZE_GB> <BASE_DIR>

Brings up an isolated crimson cluster end-to-end:
  0. preflight  — refuse to start if leftover state is present
  1. devices    — null_blk or loop-backed emulated devices
  2. vstart     — mon, mgr, N crimson-osds, wait for up+active
  3. pool       — pre-create a workload pool (size, pg_num configurable)
  4. balancer   — enable upmap balancer and wait for osd df to converge

Options:
  --backing=memory|file|auto   (default: auto; passed to setup_osd_emul.sh)
  --polled[=N]                 polled null_blk completion queues (default ON
                               for memory backing, N=2 queues/device).
                               Auto-falls back to non-polled with a warning
                               when effective backing is file.
  --no-polled                  force non-polled (IRQ-driven) completion.
  --crc-data                   enable ms_crc_data on the cluster (CRC over
                               payload bytes). Default is OFF — suitable
                               for KV-cache / regenerable-data simulation
                               and single-host latency benches. Set this
                               flag when simulating durable/persistent
                               workloads (training, EC pools, anything
                               not regenerable). See SIMULATION.md
                               ("Wire CRC and the --crc-data flag").
  --netem-delay-us=N           inject N microseconds of one-way latency
                               on the loopback interface (total RTT = 2N).
                               Models real DC-fabric wire latency on the
                               sim. Default is 0 (no delay). Typical
                               values: 5 for in-rack DPDK/RDMA, 25 for
                               in-rack kernel TCP. See SIMULATION.md
                               ("Simulation fidelity vs production").
  --segment-size=SIZE          override seastore_segment_size (default:
                               unset, uses Ceph default of 64M). Accepts
                               units (e.g. 256M, 1G). Hard upper bound
                               is ~2G (segment_off_t is int32_t); 1G is
                               the practical max. Larger segments reduce
                               SSD device-side WAF when matched to the
                               drive's erase-block / jumbo-block size.
  --rbm[=SIZE]                 enable RBM device backend (seastore_main_device_type=RANDOM_BLOCK_SSD)
                               and set journal size. SIZE can be percent (e.g. 5%) or bytes (e.g. 10G).
                               Default size is min(20GiB, 5% of volume size).
  --rbm-meta[=SIZE]            size of the RBM metadata pool (carved between the journal and the
                               data area; see seastore_rbm_metadata_size). SIZE accepts percent
                               (of the volume) or bytes. Default 1.5% of (volume - journal).
                               Pass 0 to keep the legacy single-pool layout. Only meaningful
                               together with --rbm.
  --crimson-smp N              number of crimson reactors per OSD (default: 2).
                               Forwarded to vstart.sh as --crimson-smp N.
                               When >1, also enables --crimson-balance-cpu osd
                               with --crimson-reactor-physical-only so the
                               OSD actually gets N cores (workaround for a
                               vstart quirk that otherwise pins to 1 CPU).
  --crimson-memory SIZE        set crimson_memory (seastar --memory). Accepts
                               integer-with-unit (e.g. 1536M, 4G). Fractional
                               values like "1.5G" are rejected by Ceph's
                               size parser; use 1536M. Default: unset (seastar
                               default ≈ all available RAM).
  --cachepin-pershard SIZE     set seastore_cachepin_size_pershard. Default:
                               unset (Ceph default of 2G per shard).
  --target-dirty-bytes SIZE    set seastore_target_journal_dirty_bytes. Caps
                               the per-shard dirty-extent cache footprint.
                               Default: unset (uses roll_size/3 for RBM).
  --no-preflight               skip step 0
  --no-pool                    skip step 3 (no workload pool is created)
  --pool NAME                  workload pool name (default: waf-test)
  --pool-pg N                  pool pg_num (default: 256)
  --pool-size N                pool replication size + min_size (default: 1)
  --no-balancer                skip step 4
  --balancer-timeout SECONDS   max time waiting for df convergence (default: 300)
  --balancer-interval SECONDS  poll interval (default: 5)
  --balancer-stable N          consecutive identical samples required (default: 3)

Exits 0 only after every requested stage completes — for the balancer
stage that means "osd df pg counts unchanged across --balancer-stable
consecutive samples." Returns non-zero on preflight failure, on
bring-up timeout, or on balancer-convergence timeout.
EOF
    exit 1
}

# ---- arg parsing ----
BACKING_ARG=""
POLLED_ARG=""
# Default: ms_crc_data OFF. Suits KV-cache simulation + single-host latency
# benches. Override with --crc-data for durable-workload simulations.
ENABLE_CRC_DATA=0
# netem one-way delay (microseconds) injected on loopback to model real
# DC wire latency. 0 = disabled. See SIMULATION.md "Simulation fidelity".
NETEM_DELAY_US=0
# Override seastore_segment_size (empty = use Ceph default).
SEGMENT_SIZE=""
RBM_ENABLED=0
RBM_SIZE_ARG=""
RBM_META_SIZE_ARG=""
CRIMSON_SMP=2
CRIMSON_MEMORY=""
CACHEPIN_PERSHARD=""
TARGET_DIRTY_BYTES=""
DO_PREFLIGHT=1
DO_POOL=1
DO_BALANCER=1
POOL_NAME=waf-test
POOL_PG=256
POOL_SIZE=1
BAL_TIMEOUT=300
BAL_INTERVAL=5
BAL_STABLE=3
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backing=*)              BACKING_ARG="$1"; shift ;;
        --backing)                BACKING_ARG="--backing=${2:-}"; shift 2 || usage ;;
        --polled)                 POLLED_ARG="--polled"; shift ;;
        --polled=*)               POLLED_ARG="$1"; shift ;;
        --no-polled)              POLLED_ARG="--no-polled"; shift ;;
        --crc-data)               ENABLE_CRC_DATA=1; shift ;;
        --netem-delay-us=*)       NETEM_DELAY_US="${1#--netem-delay-us=}"; shift ;;
        --netem-delay-us)         NETEM_DELAY_US="$2"; shift 2 ;;
        --segment-size=*)         SEGMENT_SIZE="${1#--segment-size=}"; shift ;;
        --segment-size)           SEGMENT_SIZE="$2"; shift 2 ;;
        --rbm|rbm)
            RBM_ENABLED=1
            if [[ $# -gt 1 && "$2" =~ ^([0-9]+%|[0-9]+[a-zA-Z]+)$ ]]; then
                RBM_SIZE_ARG="$2"
                shift 2
            else
                RBM_SIZE_ARG="default"
                shift 1
            fi
            ;;
        --rbm=*|rbm=*)            RBM_ENABLED=1; RBM_SIZE_ARG="${1#*=}"; shift ;;
        --rbm-meta)
            # Bare --rbm-meta (no value) means "use default 1.5%"; with a value
            # the next arg is the size if it parses as percent or bytes, else
            # we treat --rbm-meta itself as the default flag.
            if [[ $# -gt 1 && "$2" =~ ^([0-9]+%|[0-9]+[a-zA-Z]+|[0-9]+)$ ]]; then
                RBM_META_SIZE_ARG="$2"
                shift 2
            else
                RBM_META_SIZE_ARG="default"
                shift 1
            fi
            ;;
        --rbm-meta=*)             RBM_META_SIZE_ARG="${1#*=}"; shift ;;
        --crimson-smp)            CRIMSON_SMP="$2"; shift 2 ;;
        --crimson-smp=*)          CRIMSON_SMP="${1#*=}"; shift ;;
        --crimson-memory)         CRIMSON_MEMORY="$2"; shift 2 ;;
        --crimson-memory=*)       CRIMSON_MEMORY="${1#*=}"; shift ;;
        --cachepin-pershard)      CACHEPIN_PERSHARD="$2"; shift 2 ;;
        --cachepin-pershard=*)    CACHEPIN_PERSHARD="${1#*=}"; shift ;;
        --target-dirty-bytes)     TARGET_DIRTY_BYTES="$2"; shift 2 ;;
        --target-dirty-bytes=*)   TARGET_DIRTY_BYTES="${1#*=}"; shift ;;
        --no-preflight)           DO_PREFLIGHT=0; shift ;;
        --no-pool)                DO_POOL=0; shift ;;
        --pool)                   POOL_NAME="$2"; shift 2 ;;
        --pool-pg)                POOL_PG="$2"; shift 2 ;;
        --pool-size)              POOL_SIZE="$2"; shift 2 ;;
        --no-balancer)            DO_BALANCER=0; shift ;;
        --balancer-timeout)       BAL_TIMEOUT="$2"; shift 2 ;;
        --balancer-interval)      BAL_INTERVAL="$2"; shift 2 ;;
        --balancer-stable)        BAL_STABLE="$2"; shift 2 ;;
        -h|--help)                usage ;;
        --) shift; break ;;
        -*) echo "Unknown flag: $1" >&2; usage ;;
        *)  POSITIONAL+=("$1"); shift ;;
    esac
done
set -- "${POSITIONAL[@]:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CEPH_ROOT="$(realpath "$SCRIPT_DIR/../../..")"
CEPH_BUILD="$CEPH_ROOT/build"

do_cleanup() {
    # Phase 1: graceful teardown via stop_multi_osd.sh — single source of
    # truth for cluster shutdown. It SIGTERMs crimson-osd via pidfiles,
    # stops vstart, and calls setup_osd_emul.sh --teardown, which now
    # archives BASE_DIR (instead of rm -rf) and sweeps orphaned null_blk
    # /loop devices when markers are missing.
    if [ -x "$SCRIPT_DIR/stop_multi_osd.sh" ]; then
        echo "[cleanup] Invoking stop_multi_osd.sh on $BASE_DIR..."
        "$SCRIPT_DIR/stop_multi_osd.sh" "$BASE_DIR" 2>&1 | sed 's/^/[stop] /' || true
    fi

    # Phase 2: defensive process sweep. stop_multi_osd.sh kills via
    # pidfiles, which can be lost (e.g. a previous BASE_DIR was wiped or
    # a daemon was manually spawned). Broad pgrep -x as a safety net.
    # Match by exact process name (-x), not by full command line —
    # pkill -f would otherwise match wrapper scripts that just *mention*
    # these names in their argv (including this very script when invoked
    # from a sweep harness whose cmdline contains "test_multi_osd").
    local patterns='^(crimson-osd|ceph-osd|ceph-mon|ceph-mgr|ceph-mds|ceph-run|fio)$'
    if pgrep -x "$patterns" >/dev/null 2>&1; then
        echo "[cleanup] Killing leftover Ceph/bench processes..."
        local attempt=0
        while pgrep -x "$patterns" >/dev/null 2>&1; do
            pkill -9 -x "$patterns" || true
            sudo pkill -9 -x "$patterns" 2>/dev/null || true
            attempt=$((attempt + 1))
            if [ "$attempt" -ge 10 ]; then
                echo "[cleanup] WARNING: processes still present after $attempt SIGKILL attempts:" >&2
                pgrep -ax "$patterns" | head -5 >&2
                break
            fi
            sleep 1
        done
    fi

    # Phase 3: netem qdisc — not owned by stop_multi_osd.sh.
    if tc qdisc show dev lo 2>/dev/null | grep -q netem; then
        sudo tc qdisc del dev lo root 2>/dev/null || true
        echo "[cleanup] Removed netem qdisc from lo"
    fi

    # Phase 4: vstart APPENDS to ceph.conf and keyring rather than
    # rewriting them, so stale entries from prior runs (different
    # segment_size, different device paths, etc.) survive and silently
    # override the current run's settings. Wipe both so each run starts
    # from a fresh config.
    for f in "$CEPH_BUILD/ceph.conf" "$CEPH_BUILD/keyring" "$CEPH_BUILD/ceph.client.admin.keyring"; do
        if [ -f "$f" ]; then
            rm -f "$f"
            echo "[cleanup] Removed stale $f"
        fi
    done
    echo "[cleanup] Done."
}

if [[ $# -ne 3 ]]; then usage; fi

NUM_OSDS="$1"
SIZE_GB="$2"
BASE_DIR="$(realpath -m "$3")"

# Every invocation starts from a clean slate. do_cleanup needs BASE_DIR
# so it can delegate to stop_multi_osd.sh.
do_cleanup

if [ "$RBM_ENABLED" = "1" ]; then
    vol_bytes=$(( SIZE_GB * 1024 * 1024 * 1024 ))
    if [ -n "$RBM_SIZE_ARG" ] && [ "$RBM_SIZE_ARG" != "default" ]; then
        if [[ "$RBM_SIZE_ARG" =~ ^[0-9]+%$ ]]; then
            pct="${RBM_SIZE_ARG%\%}"
            RBM_SIZE_BYTES=$(( vol_bytes * pct / 100 ))
        else
            num=$(echo "$RBM_SIZE_ARG" | tr -dc '0-9')
            if [ -z "$num" ]; then
                echo "Invalid RBM size format: $RBM_SIZE_ARG" >&2
                exit 1
            fi
            unit=$(echo "$RBM_SIZE_ARG" | tr -dc 'a-zA-Z')
            case "${unit^^}" in
                G|GB|GIB) RBM_SIZE_BYTES=$(( num * 1024 * 1024 * 1024 )) ;;
                M|MB|MIB) RBM_SIZE_BYTES=$(( num * 1024 * 1024 )) ;;
                K|KB|KIB) RBM_SIZE_BYTES=$(( num * 1024 )) ;;
                "")        RBM_SIZE_BYTES="$num" ;;
                *)
                    echo "Unknown RBM size unit: $unit" >&2
                    exit 1
                    ;;
            esac
        fi
    fi

    # Resolve --rbm-meta similarly.
    if [ -n "$RBM_META_SIZE_ARG" ] && [ "$RBM_META_SIZE_ARG" != "default" ]; then
        if [[ "$RBM_META_SIZE_ARG" =~ ^[0-9]+%$ ]]; then
            pct="${RBM_META_SIZE_ARG%\%}"
            RBM_META_SIZE_BYTES=$(( vol_bytes * pct / 100 ))
        else
            num=$(echo "$RBM_META_SIZE_ARG" | tr -dc '0-9')
            if [ -z "$num" ]; then
                echo "Invalid RBM metadata size format: $RBM_META_SIZE_ARG" >&2
                exit 1
            fi
            unit=$(echo "$RBM_META_SIZE_ARG" | tr -dc 'a-zA-Z')
            case "${unit^^}" in
                G|GB|GIB) RBM_META_SIZE_BYTES=$(( num * 1024 * 1024 * 1024 )) ;;
                M|MB|MIB) RBM_META_SIZE_BYTES=$(( num * 1024 * 1024 )) ;;
                K|KB|KIB) RBM_META_SIZE_BYTES=$(( num * 1024 )) ;;
                "")        RBM_META_SIZE_BYTES="$num" ;;
                *)
                    echo "Unknown RBM metadata size unit: $unit" >&2
                    exit 1
                    ;;
            esac
        fi
    fi
fi

# ---- step 0: preflight ----
preflight() {
    local bad=()

    # Use exact-name match (-x) for all daemon names to avoid matching wrapper
    # scripts whose argv contains these names (e.g. a sweep harness whose bash
    # cmdline mentions "crimson-osd" in a pkill pattern).
    if pgrep -x crimson-osd >/dev/null 2>&1; then
        bad+=("crimson-osd process(es) running: $(pgrep -ax crimson-osd | head -3 | sed 's/^/      /')")
    fi
    if pgrep -x ceph-mon >/dev/null 2>&1; then
        bad+=("ceph-mon process(es) running")
    fi
    if pgrep -x ceph-mgr >/dev/null 2>&1; then
        bad+=("ceph-mgr process(es) running")
    fi
    if pgrep -x ceph-run >/dev/null 2>&1; then
        bad+=("ceph-run wrapper(s) running")
    fi
    if pgrep -x fio >/dev/null 2>&1; then
        bad+=("fio process(es) running")
    fi

    if [ -d /sys/kernel/config/nullb ]; then
        local nullbs
        nullbs=$(find /sys/kernel/config/nullb -mindepth 1 -maxdepth 1 -type d ! -name features -printf '%f ' 2>/dev/null)
        if [ -n "$nullbs" ]; then
            bad+=("leftover null_blk devices: $nullbs")
        fi
    fi

    # Any loop device pointing at a 'backing.img' under the build tree is
    # a leftover from a prior file-backed run.
    local loops
    loops=$(losetup -a 2>/dev/null | grep -E "/dev/loop[0-9]+:.*backing\.img" || true)
    if [ -n "$loops" ]; then
        bad+=("leftover loop device(s): $(echo "$loops" | head -3 | tr '\n' ';')")
    fi

    if [ -e "$BASE_DIR" ]; then
        bad+=("BASE_DIR already exists: $BASE_DIR")
    fi

    if [ ${#bad[@]} -gt 0 ]; then
        echo "[preflight] FAIL: refusing to start with stale state present:" >&2
        local b
        for b in "${bad[@]}"; do
            echo "  - $b" >&2
        done
        cat >&2 <<EOF

This indicates the unconditional cleanup at the top of $0 failed to
remove some residue. Investigate manually, then re-run.
Or re-run with --no-preflight to bypass these checks (not recommended).
EOF
        exit 1
    fi

    echo "[preflight] OK — no leftover processes, devices, or BASE_DIR."
}

# ---- step 4 helpers: balancer + DF convergence ----
osd_df_signature() {
    # Compact, deterministic representation of per-OSD PG counts. Used as
    # the convergence key — when this string is stable across $BAL_STABLE
    # samples, we declare the balancer done.
    "$CEPH_BUILD/bin/ceph" -c "$CEPH_BUILD/ceph.conf" osd df -f json 2>/dev/null \
        | jq -c '.nodes | map(select(.type=="osd")) | map({id, pgs}) | sort_by(.id)'
}

wait_for_df_convergence() {
    local timeout="$1" interval="$2" need_stable="$3"
    local prev="" cur stable=0 elapsed=0
    echo "[balancer] waiting for osd df pg counts to converge"
    echo "[balancer]   timeout=${timeout}s  interval=${interval}s  need_stable=${need_stable}"

    while [ "$elapsed" -lt "$timeout" ]; do
        cur=$(osd_df_signature)
        if [ -z "$cur" ] || [ "$cur" = "null" ]; then
            sleep "$interval"; elapsed=$((elapsed + interval))
            continue
        fi
        if [ "$cur" = "$prev" ]; then
            stable=$((stable + 1))
            echo "[balancer]   stable ${stable}/${need_stable}: ${cur}"
            if [ "$stable" -ge "$need_stable" ]; then
                echo "[balancer] converged after ${elapsed}s — exiting cleanly."
                return 0
            fi
        else
            stable=1
            echo "[balancer]   sample: ${cur}"
        fi
        prev="$cur"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    echo "[balancer] FAIL: pg counts did not converge within ${timeout}s." >&2
    echo "          Last sample: ${prev:-<none>}" >&2
    return 1
}

capture_build_provenance() {
    # Record what this run was built from so the dev.<DATE>-<TIME> archive
    # (teardown moves all of BASE_DIR aside) is self-describing: git HEAD,
    # the full uncommitted working-tree diff, and the crimson-osd binary
    # fingerprint (the binary may predate the working tree). Best-effort —
    # a capture failure must never abort the run.
    local prov_dir="$BASE_DIR/provenance"
    local txt="$prov_dir/build_provenance.txt"
    local diff="$prov_dir/working_tree.diff"
    local osd_bin="$CEPH_BUILD/bin/crimson-osd"

    if ! mkdir -p "$prov_dir" 2>/dev/null; then
        echo "[provenance] WARN: could not create $prov_dir; skipping"
        return 0
    fi

    {
        echo "# build provenance — captured by start_multi_osd.sh at simulation start"
        echo "captured_at: $(date -Is 2>/dev/null)"
        echo "host:        $(hostname 2>/dev/null)"
        echo "repo:        $CEPH_ROOT"
        echo "branch:      $(git -C "$CEPH_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
        echo "HEAD:        $(git -C "$CEPH_ROOT" rev-parse HEAD 2>/dev/null)"
        echo "describe:    $(git -C "$CEPH_ROOT" describe --always --dirty --tags 2>/dev/null)"
        echo
        echo "## crimson-osd binary"
        if [ -e "$osd_bin" ]; then
            echo "path:   $osd_bin"
            echo "stat:   $(stat -c '%y  %s bytes' "$osd_bin" 2>/dev/null)"
            echo "sha256: $(sha256sum "$osd_bin" 2>/dev/null | awk '{print $1}')"
        else
            echo "path:   $osd_bin (not found)"
        fi
        echo
        echo "## git status --short --branch"
        git -C "$CEPH_ROOT" status --short --branch 2>/dev/null || true
        echo
        echo "## git log --oneline -n 100"
        git -C "$CEPH_ROOT" log --oneline -n 100 2>/dev/null || true
    } > "$txt" 2>/dev/null || echo "[provenance] WARN: failed writing $txt"

    # Full uncommitted delta vs HEAD (staged + unstaged) so the tree is reproducible.
    git -C "$CEPH_ROOT" diff HEAD > "$diff" 2>/dev/null || echo "[provenance] WARN: failed writing $diff"

    echo "[provenance] wrote $txt and $diff"
}

# =========================================================================
# Step 0 — preflight (refuse to start on stale state)
# =========================================================================
if [ "$DO_PREFLIGHT" = "1" ]; then
    preflight
else
    echo "[preflight] skipped (--no-preflight)"
fi

# =========================================================================
# Step 1 — devices (setup_osd_emul.sh) + vstart cluster bring-up
# =========================================================================
SETUP_ARGS=()
[ -n "$BACKING_ARG" ] && SETUP_ARGS+=("$BACKING_ARG")
[ -n "$POLLED_ARG" ]  && SETUP_ARGS+=("$POLLED_ARG")
"$SCRIPT_DIR/setup_osd_emul.sh" "${SETUP_ARGS[@]}" "$NUM_OSDS" "$SIZE_GB" "$BASE_DIR"

export CEPH_DEV_DIR="$BASE_DIR"
export CEPH_OUT_DIR="$BASE_DIR/out"

cd "$CEPH_BUILD"

# Snapshot the device_path / backing_mode markers — vstart's OSD mkfs
# step wipes $BASE_DIR/osd$i out from under us; we restore them after
# bring-up so the teardown path can still find them.
declare -a SNAP_DEV SNAP_MODE
DEVS=""
for i in $(seq 0 $((NUM_OSDS - 1))); do
    SNAP_DEV[$i]=$(cat "$BASE_DIR/osd$i/device_path")
    if [ -f "$BASE_DIR/osd$i/backing_mode" ]; then
        SNAP_MODE[$i]=$(cat "$BASE_DIR/osd$i/backing_mode")
    else
        SNAP_MODE[$i]=""
    fi
    if [ -z "$DEVS" ]; then DEVS="${SNAP_DEV[$i]}"; else DEVS="$DEVS,${SNAP_DEV[$i]}"; fi
done

echo "[vstart] starting MON/MGR + $NUM_OSDS crimson-osd"
mkdir "$CEPH_OUT_DIR"
VSTART_EXTRA=()
if [ "$ENABLE_CRC_DATA" = "1" ]; then
    echo "[crc] leaving ms_crc_data at default (--crc-data)"
else
    echo "[crc] setting ms_crc_data=false in ceph.conf (default; pass --crc-data to enable)"
    VSTART_EXTRA+=(-o "ms_crc_data = false")
fi
if [ "$RBM_ENABLED" = "1" ]; then
    echo "[seastore] RBM enabled: setting seastore_main_device_type=RANDOM_BLOCK_SSD"
    VSTART_EXTRA+=(-o "seastore_main_device_type = RANDOM_BLOCK_SSD")
    if [ -n "${RBM_SIZE_BYTES:-}" ]; then
        echo "[seastore] RBM journal size: $RBM_SIZE_BYTES bytes"
        VSTART_EXTRA+=(-o "seastore_cbjournal_size = $RBM_SIZE_BYTES")
    else
        echo "[seastore] RBM journal size: default"
    fi
    if [ -n "${RBM_META_SIZE_BYTES:-}" ]; then
        echo "[seastore] RBM metadata pool size: $RBM_META_SIZE_BYTES bytes"
        VSTART_EXTRA+=(-o "seastore_rbm_metadata_size = $RBM_META_SIZE_BYTES")
    else
        echo "[seastore] RBM metadata pool size: default"
    fi
    if [ -n "$SEGMENT_SIZE" ]; then
        echo "[seastore] WARNING: --segment-size override ignored when RBM is enabled"
    fi
else
    if [ -n "$SEGMENT_SIZE" ]; then
        echo "[seastore] setting seastore_segment_size=$SEGMENT_SIZE in ceph.conf"
        VSTART_EXTRA+=(-o "seastore_segment_size = $SEGMENT_SIZE")
    fi
fi
if [ -n "$CRIMSON_MEMORY" ]; then
    echo "[mem] setting crimson_memory=$CRIMSON_MEMORY"
    VSTART_EXTRA+=(-o "crimson_memory = $CRIMSON_MEMORY")
fi
if [ -n "$CACHEPIN_PERSHARD" ]; then
    echo "[mem] setting seastore_cachepin_size_pershard=$CACHEPIN_PERSHARD"
    VSTART_EXTRA+=(-o "seastore_cachepin_size_pershard = $CACHEPIN_PERSHARD")
fi
if [ -n "$TARGET_DIRTY_BYTES" ]; then
    echo "[mem] setting seastore_target_journal_dirty_bytes=$TARGET_DIRTY_BYTES"
    VSTART_EXTRA+=(-o "seastore_target_journal_dirty_bytes = $TARGET_DIRTY_BYTES")
fi

VSTART_SMP_ARGS=(--crimson-smp "$CRIMSON_SMP")
if [ "$CRIMSON_SMP" -gt 1 ]; then
    # Without --crimson-balance-cpu, vstart hardcodes crimson_cpu_set=<osd_id>
    # to one CPU and seastar derives smp=1 from --cpuset, ignoring --crimson-smp.
    # Enabling balance-cpu makes vstart populate crimson_cpu_set via the
    # assign_crimson_cores helper so each OSD gets CRIMSON_SMP cores.
    VSTART_SMP_ARGS+=(--crimson-balance-cpu osd --crimson-reactor-physical-only)
fi
MON=1 MGR=1 OSD="$NUM_OSDS" MDS=0 ../src/vstart.sh -n -x --without-dashboard \
    --crimson --seastore --seastore-devs "$DEVS" --seastore-device-size "${SIZE_GB}G" \
    "${VSTART_SMP_ARGS[@]}" \
    --reactor-backend io_uring "${VSTART_EXTRA[@]}" >> "$CEPH_OUT_DIR/vstart.log" 2>&1

for i in $(seq 0 $((NUM_OSDS - 1))); do
    OSD_DIR="$BASE_DIR/osd$i"
    mkdir -p "$OSD_DIR"
    echo "${SNAP_DEV[$i]}" > "$OSD_DIR/device_path"
    if [ -n "${SNAP_MODE[$i]}" ]; then
        echo "${SNAP_MODE[$i]}" > "$OSD_DIR/backing_mode"
    fi
done

echo "[vstart] capturing OSD pids"
for i in $(seq 0 $((NUM_OSDS - 1))); do
    OSD_DIR="$BASE_DIR/osd$i"
    T=60
    while [ ! -f "$CEPH_OUT_DIR/osd.$i.pid" ] && [ $T -gt 0 ]; do
        sleep 1
        T=$((T - 1))
    done
    if [ -f "$CEPH_OUT_DIR/osd.$i.pid" ]; then
        cp "$CEPH_OUT_DIR/osd.$i.pid" "$OSD_DIR/crimson-osd.pid"
        echo "[vstart]   osd.$i pid=$(cat "$OSD_DIR/crimson-osd.pid")"
    else
        echo "[vstart]   WARN: osd.$i pid file not found"
    fi
done

echo "[vstart] waiting for all OSDs up+active"
TIMEOUT=120
while [[ $TIMEOUT -gt 0 ]]; do
    STATUS=$(./bin/ceph -c ceph.conf osd stat -f json)
    UP=$(echo "$STATUS" | jq '.num_up_osds')
    IN=$(echo "$STATUS" | jq '.num_in_osds')
    TOTAL=$(echo "$STATUS" | jq '.num_osds')
    echo "[vstart]   total=$TOTAL up=$UP in=$IN"
    if [[ "$UP" -eq "$NUM_OSDS" ]] && [[ "$IN" -eq "$NUM_OSDS" ]]; then
        echo "[vstart] all OSDs up+active"
        break
    fi
    sleep 2
    TIMEOUT=$((TIMEOUT - 2))
done
if [[ $TIMEOUT -le 0 ]]; then
    echo "[vstart] FAIL: timeout waiting for OSDs to become up+active" >&2
    exit 1
fi

# =========================================================================
# Record build provenance (git + binary) into BASE_DIR for the archive
# =========================================================================
capture_build_provenance

# =========================================================================
# Optional: inject loopback latency to model DC wire (netem)
# =========================================================================
if [ "$NETEM_DELAY_US" != "0" ]; then
    if ! [[ "$NETEM_DELAY_US" =~ ^[0-9]+$ ]]; then
        echo "[netem] ERROR: --netem-delay-us must be a non-negative integer (got '$NETEM_DELAY_US')" >&2
        exit 1
    fi
    # Ensure sch_netem is loaded; tc add fails with "Specified qdisc kind is
    # unknown" otherwise.
    if ! lsmod | grep -q '^sch_netem'; then
        if ! sudo modprobe sch_netem 2>/dev/null; then
            echo "[netem] ERROR: sch_netem kernel module not available; cannot inject loopback latency." >&2
            echo "[netem]   Install kernel-modules-extra (or equivalent) and re-run." >&2
            exit 1
        fi
    fi
    echo "[netem] adding ${NETEM_DELAY_US}us one-way delay on lo (RTT = $((2 * NETEM_DELAY_US))us)"
    sudo tc qdisc add dev lo root netem delay "${NETEM_DELAY_US}us"
    tc qdisc show dev lo | sed 's/^/[netem]   /'
fi

# =========================================================================
# Step 3 — pool create + size override
# =========================================================================
if [ "$DO_POOL" = "1" ]; then
    echo "[pool] creating '$POOL_NAME' (pg_num=$POOL_PG, size=$POOL_SIZE)"
    ./bin/ceph -c ceph.conf osd pool create "$POOL_NAME" "$POOL_PG" "$POOL_PG" replicated >/dev/null
    ./bin/ceph -c ceph.conf osd pool set    "$POOL_NAME" size     "$POOL_SIZE" --yes-i-really-mean-it >/dev/null
    ./bin/ceph -c ceph.conf osd pool set    "$POOL_NAME" min_size "$POOL_SIZE" >/dev/null
    # Surface the effective parameters so the operator can see them.
    local_size=$(./bin/ceph -c ceph.conf osd pool get "$POOL_NAME" size      2>&1 | awk '/^size:/{print $2}')
    local_min=$(./bin/ceph -c ceph.conf osd pool get  "$POOL_NAME" min_size  2>&1 | awk '/^min_size:/{print $2}')
    local_pg=$(./bin/ceph -c ceph.conf osd pool get   "$POOL_NAME" pg_num    2>&1 | awk '/^pg_num:/{print $2}')
    echo "[pool]   $POOL_NAME: size=$local_size min_size=$local_min pg_num=$local_pg"
else
    echo "[pool] skipped (--no-pool)"
fi

# =========================================================================
# Step 4 — balancer + wait for osd df convergence
# =========================================================================
if [ "$DO_BALANCER" = "1" ]; then
    echo "[balancer] enabling upmap mode"
    ./bin/ceph -c ceph.conf balancer mode upmap >/dev/null 2>&1 || true
    ./bin/ceph -c ceph.conf balancer on        >/dev/null 2>&1 || true

    if ! wait_for_df_convergence "$BAL_TIMEOUT" "$BAL_INTERVAL" "$BAL_STABLE"; then
        exit 1
    fi
else
    echo "[balancer] skipped (--no-balancer)"
fi

echo ""
echo "[done] cluster ready."
./bin/ceph -c ceph.conf osd df 2>/dev/null | grep -v -E "^\*\*\*|WARNING|^$" || true
