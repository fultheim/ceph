#!/usr/bin/env bash
#
# spdk_nvmet_setup.sh — SIMULATION / TEST INFRA ONLY (do NOT merge to community).
#
# Stands up (or tears down) a RAM-backed NVMe-oF TCP target using SPDK's own
# nvmf_tgt with a malloc bdev, on TCP loopback. This gives the crimson SeaStore
# SPDK initiator (selected via seastore_spdk_transport_id) a real NVMe-oF
# controller to attach to with no NVMe hardware and no vfio.
#
# Why an SPDK target rather than the Linux kernel nvmet stack: using SPDK's own
# nvmf_tgt guarantees the target speaks the same protocol version as the
# initiator. Both ends now run the same system SPDK (>= 25.05); historically the
# bundled v20.07 fork and a modern kernel nvmet-tcp did not even complete the
# NVMe-oF/TCP init handshake, which is the other reason to drive our own. The
# target and the OSD are two separate SPDK/DPDK processes; they coexist via
# distinct DPDK --file-prefix values and a shared hugepage pool.
#
# Usage:
#   spdk_nvmet_setup.sh setup   [SIZE_GB]   # prints the SPDK transport id on stdout
#   spdk_nvmet_setup.sh teardown
#
set -euo pipefail

ACTION="${1:-setup}"
SIZE_GB="${2:-8}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Run the target on the SAME system SPDK that crimson-osd is built against
# (Phase 12: system SPDK >= 25.05). The bundled src/spdk fork (v20.07) is no
# longer built for WITH_CRIMSON+WITH_SPDK, and a v20.07 target against a 25.05
# initiator is a version skew we avoid by running both ends on 25.05. Override
# CRIMSON_SPDK_DIR / CRIMSON_SPDK_LIB if SPDK lives elsewhere.
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SPDK_DIR="${CRIMSON_SPDK_DIR:-$REPO_ROOT/src/spdk}"
NVMF_TGT="$SPDK_DIR/build/bin/nvmf_tgt"
RPC_PY="$SPDK_DIR/scripts/rpc.py"
# The build-tree nvmf_tgt's bdev plugin .so and libvfio-user are not on its
# rpath; point the loader at the install prefix's lib dirs.
SPDK_LIB="${CRIMSON_SPDK_LIB:-$SPDK_DIR/install/lib}"
export LD_LIBRARY_PATH="$SPDK_LIB:$SPDK_LIB/../lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

SOCK="/var/tmp/spdk_crimson_nvmf.sock"
PIDFILE="/var/tmp/spdk_crimson_nvmf.pid"
LOG="/var/tmp/spdk_crimson_nvmf.log"
NQN="nqn.2016-06.io.crimson-sim:nvmf1"
IP="127.0.0.1"
PORT="4420"
CORE_MASK="${CORE_MASK:-0x4}"   # default core 2, overridden dynamically
# Local transport: "tcp" (loopback nvmf-tcp, the Phase 11 baseline) or
# "vfiouser" (shared-memory, zero transport copies — the Phase 12.7 fix; the
# target DMAs straight from the OSD's hugepages, no TCP initiator on the
# reactor). vfiouser needs SPDK built --with-vfio-user (25.05).
TRANSPORT="${3:-${CRIMSON_SPDK_TRANSPORT:-tcp}}"
TRANSPORT="${TRANSPORT,,}"       # normalize case
# vfio-user endpoint is a directory; the target creates a "<dir>/cntrl" unix
# socket inside it and the initiator connects to the same path.
VFU_DIR="/var/tmp/spdk_crimson_vfu"

log() { echo "[spdk-nvmf] $*" >&2; }
# Run as the same (unprivileged) user as the OSD so both SPDK processes share
# one DPDK runtime-dir base and coexist; hugepages are world-writable (1777) and
# the TCP transport needs no root.
rpc() { python3 "$RPC_PY" -s "$SOCK" "$@"; }

setup() {
    if [ ! -x "$NVMF_TGT" ]; then
        log "ERROR: $NVMF_TGT not found - build with WITH_SPDK=ON"
        exit 1
    fi
    if [ "$SIZE_GB" -gt 60 ]; then
        log "ERROR: SIZE_GB=$SIZE_GB exceeds the RAM-backed target maximum (60)."
        log "DPDK 20.05 caps one process's 2MiB-hugepage memory at 64 GiB per"
        log "NUMA node (RTE_MAX_MEM_MB_PER_TYPE); the malloc bdevs plus the"
        log "transport pools must fit inside it."
        exit 1
    fi
    log "starting nvmf_tgt (core $CORE_MASK, malloc ${SIZE_GB}G RAM-backed)"
    # No --file-prefix: SPDK auto-derives a per-process prefix, so this target
    # and the OSD (separate PIDs) are independent DPDK primaries that coexist.
    "$NVMF_TGT" -r "$SOCK" -m "$CORE_MASK" --iova-mode va --num-trace-entries 1024 >"$LOG" 2>&1 &
    echo $! > "$PIDFILE"

    # Wait for the RPC server to come up.
    local ok=0
    for _ in $(seq 1 100); do
        if rpc spdk_get_version >/dev/null 2>&1; then ok=1; break; fi
        sleep 0.2
    done
    if [ "$ok" != 1 ]; then
        log "ERROR: nvmf_tgt RPC did not come up; see $LOG"
        sudo tail -5 "$LOG" >&2 || true
        exit 1
    fi

    # Maximize per-command size for the seastore SPDK write path:
    #  -i 2097152 (max_io_size 2 MiB): the driver packs each record's SGL into
    #     commands of <=max_sges segments with no byte cap, so a contiguous run
    #     up to 2 MiB rides a single NVMe command instead of being split by the
    #     controller's max transfer size. Segmented record writes can exceed
    #     1 MiB, hence >1 MiB here.
    #  -u 131072 (io_unit 128 KiB): keeps the buffer pool at 4096*128 KiB =
    #     512 MiB; a 2 MiB I/O uses 16 unit buffers (== SPDK_NVMF_MAX_SGL_ENTRIES).
    #  -c 131072: in-capsule data size, avoids the R2T round-trip for <=128 KiB
    #     writes. -n/-b size the shared/per-poll-group buffer pools.
    if [ "$TRANSPORT" = vfiouser ]; then
        # vfio-user is a shared-memory transport: no PDU framing and no TCP
        # tuning knobs (the -i/-u/-c/-n/-b above are TCP-only). The target maps
        # the initiator's hugepages and DMAs directly from them — zero transport
        # copies, no initiator running on the OSD reactor.
        rpc nvmf_create_transport -t VFIOUSER >/dev/null
    else
        rpc nvmf_create_transport -t TCP -i 2097152 -u 131072 -c 131072 -n 4096 -b 128 >/dev/null
    fi

    # DPDK 20.05 caps a single hugepage allocation at one memseg list, and with
    # 2 MiB pages a list holds at most RTE_MAX_MEMSEG_PER_LIST(8192) segments =
    # 16 GiB. A larger malloc bdev fails its one-piece spdk_zmalloc with
    # eal_memalloc "couldn't find suitable memseg_list", so build the device
    # from <=15 GiB malloc bdevs striped together with raid0. Total memory per
    # (page size, NUMA node) type is further capped at RTE_MAX_MEM_MB_PER_TYPE
    # (64 GiB) — on a single-NUMA host that bounds the whole RAM-backed device,
    # checked above.
    local ns_bdev chunks=$(( (SIZE_GB + 14) / 15 ))
    if [ "$chunks" -le 1 ]; then
        rpc bdev_malloc_create $((SIZE_GB * 1024)) 4096 -b Malloc0 >/dev/null
        ns_bdev=Malloc0
    else
        local i bases="" chunk_mb=$(( SIZE_GB * 1024 / chunks ))
        log "striping raid0 over $chunks x ${chunk_mb}MiB malloc bdevs"
        for i in $(seq 0 $((chunks - 1))); do
            rpc bdev_malloc_create "$chunk_mb" 4096 -b "Malloc$i" >/dev/null
            bases+="Malloc$i "
        done
        rpc bdev_raid_create -n Raid0 -z 128 -r 0 -b "${bases% }" >/dev/null
        ns_bdev=Raid0
    fi

    rpc nvmf_create_subsystem "$NQN" -a -s SPDK00000000000001 >/dev/null
    rpc nvmf_subsystem_add_ns "$NQN" "$ns_bdev" >/dev/null

    if [ "$TRANSPORT" = vfiouser ]; then
        # traddr is a directory; the target creates "$VFU_DIR/cntrl" inside it
        # and the initiator connects to that same path.
        mkdir -p "$VFU_DIR"
        rpc nvmf_subsystem_add_listener "$NQN" -t VFIOUSER -a "$VFU_DIR" -s 0 >/dev/null
        log "nvmf target ready at vfio-user $VFU_DIR/cntrl ($NQN)"
        echo "trtype:VFIOUSER traddr:$VFU_DIR subnqn:$NQN"
    else
        rpc nvmf_subsystem_add_listener "$NQN" -t tcp -a "$IP" -s "$PORT" >/dev/null
        log "nvmf target ready at $IP:$PORT ($NQN)"
        echo "trtype:TCP adrfam:IPv4 traddr:$IP trsvcid:$PORT subnqn:$NQN"
    fi
}

teardown() {
    log "tearing down nvmf_tgt"
    if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"
    fi
    pkill -f "nvmf_tgt.*spdk_crimson_nvmf.sock" 2>/dev/null || true
    # DPDK teardown can be slow; escalate to SIGKILL if it lingers.
    for _ in $(seq 1 20); do
        pgrep -f "nvmf_tgt.*spdk_crimson_nvmf.sock" >/dev/null || break
        sleep 0.5
    done
    pkill -9 -f "nvmf_tgt.*spdk_crimson_nvmf.sock" 2>/dev/null || true
    rm -f "$SOCK"
    rm -rf "$VFU_DIR"
    log "teardown complete"
}

case "$ACTION" in
    setup)    setup ;;
    teardown) teardown ;;
    *) echo "usage: $0 {setup [SIZE_GB] | teardown}" >&2; exit 2 ;;
esac
