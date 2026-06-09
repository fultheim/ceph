#!/bin/bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 [--backing=memory|file|auto] [--polled[=N]|--no-polled] <NUM_OSDS> <SIZE_GB> <BASE_DIR>
       $0 --teardown <BASE_DIR>

Options:
  --backing=auto    (default) memory if total <= 75% of MemTotal, else file
  --backing=memory  force null_blk memory-backed mode
  --backing=file    force loop device over sparse file
  --polled[=N]      enable polled null_blk completion queues (default ON for
                    memory backing, N=2 queues/device). Memory-backed only.
                    Removes IRQ-driven completion from the IO path; pairs
                    with io_uring IOPOLL on the consumer side.
                    Auto-disabled with a warning when effective backing is
                    file (loop devices don't expose polled queues).
  --no-polled       force IRQ-driven completion even on memory backing.
EOF
    exit 1
}

# ---- Argument parsing ----
BACKING="auto"
# Polled is the default for memory-backed runs; auto-falls back to non-polled
# when effective backing resolves to file (see below).
POLLED=1
POLL_QUEUES_PER_DEV=2
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --backing=*)
            BACKING="${1#--backing=}"
            shift
            ;;
        --backing)
            BACKING="${2:-}"
            shift 2 || usage
            ;;
        --polled)
            POLLED=1
            shift
            ;;
        --polled=*)
            POLLED=1
            POLL_QUEUES_PER_DEV="${1#--polled=}"
            shift
            ;;
        --no-polled)
            POLLED=0
            shift
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL[@]:-}"

case "$BACKING" in
    memory|file|auto) ;;
    *) echo "Error: --backing must be memory, file, or auto (got '$BACKING')" >&2; exit 1 ;;
esac

if [ "$POLLED" = "1" ]; then
    if ! [[ "$POLL_QUEUES_PER_DEV" =~ ^[0-9]+$ ]] || [ "$POLL_QUEUES_PER_DEV" -lt 1 ]; then
        echo "Error: --polled=N requires a positive integer (got '$POLL_QUEUES_PER_DEV')" >&2
        exit 1
    fi
fi

# ---- Teardown path ----
if [[ "${1:-}" == "--teardown" ]]; then
    if [[ $# -ne 2 ]]; then
        usage
    fi
    BASE_DIR="$2"
    echo "Teardown mode for BASE_DIR=$BASE_DIR"

    # Safety: refuse to rm -rf a directory that looks like a build root.
    # The final `rm -rf "$BASE_DIR"` below has no idea what it's pointed at;
    # if the caller passes the build root by mistake (e.g.
    # `stop_multi_osd.sh build/`), we'd wipe the entire compiled tree.
    # CMakeCache.txt + build.ninja are unambiguous build-root markers;
    # neither appears in any legitimate <build>/dev/<subdir> teardown target.
    for marker in CMakeCache.txt build.ninja; do
        if [ -e "$BASE_DIR/$marker" ]; then
            echo "Error: refusing teardown — BASE_DIR='$BASE_DIR' contains '$marker'," >&2
            echo "       which means it is a build root. Pass a dedicated subdirectory" >&2
            echo "       (e.g. <build>/dev or <build>/dev/<bench>) as BASE_DIR instead." >&2
            exit 1
        fi
    done

    OSD_HANDLED=0
    if [ -d "$BASE_DIR" ]; then
        for osd_dir in "$BASE_DIR"/osd*; do
            [ -d "$osd_dir" ] || continue
            OSD_HANDLED=$((OSD_HANDLED + 1))
            DEV_PATH=""
            [ -f "$osd_dir/device_path" ] && DEV_PATH=$(cat "$osd_dir/device_path")
            MODE=""
            [ -f "$osd_dir/backing_mode" ] && MODE=$(cat "$osd_dir/backing_mode")

            i="${osd_dir##*/osd}"

            # Infer mode from device path if marker is missing (legacy dirs).
            if [ -z "$MODE" ] && [ -n "$DEV_PATH" ]; then
                case "$DEV_PATH" in
                    /dev/nullb*) MODE="memory" ;;
                    /dev/loop*)  MODE="file" ;;
                esac
            fi

            # Smart mode inference if both mode and path markers are missing/corrupted
            if [ -z "$MODE" ] && [ -n "$i" ]; then
                if [ -f "$BASE_DIR/backing.img.$i" ]; then
                    MODE="file"
                elif [ -d "/sys/kernel/config/nullb/nullb$i" ]; then
                    MODE="memory"
                fi
            fi

            case "$MODE" in
                memory|memory-polled)
                    DEV_NAME=""
                    if [ -n "$DEV_PATH" ]; then
                        DEV_NAME=$(basename "$DEV_PATH")
                    elif [ -n "$i" ]; then
                        DEV_NAME="nullb$i"
                    fi
                    if [ -n "$DEV_NAME" ]; then
                        CONFIG_DIR="/sys/kernel/config/nullb/$DEV_NAME"
                        if [ -d "$CONFIG_DIR" ]; then
                            echo 0 | sudo tee "$CONFIG_DIR/power" >/dev/null
                            sudo rmdir "$CONFIG_DIR"
                            echo "Removed null_blk device $DEV_NAME"
                        fi
                    fi
                    ;;
                file)
                    img="$BASE_DIR/backing.img.$i"
                    # If DEV_PATH is missing/empty, attempt to find the loop device using losetup -j
                    if { [ -z "$DEV_PATH" ] || [ ! -b "$DEV_PATH" ]; } && [ -f "$img" ]; then
                        DEV_PATH=$(sudo losetup -j "$img" 2>/dev/null | awk -F: '{print $1}')
                    fi
                    if [ -n "$DEV_PATH" ] && [ -b "$DEV_PATH" ]; then
                        if sudo losetup -d "$DEV_PATH" 2>/dev/null; then
                            echo "Detached loop device $DEV_PATH"
                        fi
                    fi
                    if [ -f "$img" ]; then
                        rm -f "$img"
                        echo "Removed sparse file $img"
                    fi
                    ;;
                "")
                    echo "Warning: $osd_dir has no backing_mode and no device_path; skipping device cleanup" >&2
                    ;;
                *)
                    echo "Warning: $osd_dir has unknown backing_mode '$MODE'; skipping device cleanup" >&2
                    ;;
            esac
        done
    fi

    # Fallback sweep for orphaned devices. Triggered when BASE_DIR is missing
    # or has no recognizable osd* markers (e.g. a previous teardown wiped
    # the markers but the kernel-side null_blk device kept living, leaking
    # ~SIZE_GB of memory until next reboot). setup_osd_emul.sh starts the
    # null_blk module with `nr_devices=0`, so any nullb* present in configfs
    # was created by this harness — safe to sweep wholesale.
    if [ "$OSD_HANDLED" -eq 0 ]; then
        for cfg in /sys/kernel/config/nullb/nullb*; do
            [ -d "$cfg" ] || continue
            name=$(basename "$cfg")
            echo 0 | sudo tee "$cfg/power" >/dev/null
            sudo rmdir "$cfg"
            echo "[fallback] Removed orphaned null_blk device $name"
        done
        for d in $(losetup -a 2>/dev/null | awk -F: '/backing\.img/ {print $1}'); do
            sudo losetup -d "$d" 2>/dev/null && echo "[fallback] Detached orphaned loop device $d"
        done
    fi
    sudo modprobe -r null_blk 2>/dev/null || true

    # Preserve OSD/mon/mgr logs by renaming BASE_DIR instead of deleting.
    # Subsequent start_multi_osd.sh runs will create a fresh BASE_DIR of
    # the same name; the archived dir(s) sit alongside until the user
    # purges them manually.
    if [ -d "$BASE_DIR" ]; then
        ARCHIVE="$BASE_DIR.$(date +%Y%m%d-%H%M%S)"
        # Avoid collision if a teardown lands inside the same second.
        if [ -e "$ARCHIVE" ]; then
            ARCHIVE="$ARCHIVE.$$"
        fi
        mv "$BASE_DIR" "$ARCHIVE"
        echo "Archived $BASE_DIR -> $ARCHIVE"
    fi
    exit 0
fi

if [[ $# -ne 3 ]]; then
    usage
fi

NUM_OSDS="$1"
SIZE_GB="$2"
BASE_DIR="$3"

if ! [[ "$NUM_OSDS" =~ ^[0-9]+$ ]] || ! [[ "$SIZE_GB" =~ ^[0-9]+$ ]]; then
    echo "Error: NUM_OSDS and SIZE_GB must be integers." >&2
    exit 1
fi

# Empirical minimum: SeaStore's SegmentCleaner aborts under sustained
# writes (async_cleaner.cc: "device size setting is too small") when
# the per-OSD device is smaller than this. Bisected against a 90 s
# steady-state run of waf_bench.fio (4 KiB randwrite, iodepth=64,
# nrfiles=32, 4 OSDs):
#   -  3 GiB: passes one 90 s bench with HEALTH_OK
#   -  2 GiB: takes out 3 of 4 OSDs with out-of-space aborts
# We enforce 4 GiB rather than the bisected 3 GiB boundary to keep a
# small safety margin for slightly longer or heavier workloads. The
# threshold is the SAME for memory- and file-backed modes because the
# constraint is on segment headroom, not the backing technology.
MIN_SIZE_GB=4
if [ "$SIZE_GB" -lt "$MIN_SIZE_GB" ]; then
    cat <<EOF >&2
Error: SIZE_GB=$SIZE_GB is below the enforced minimum of $MIN_SIZE_GB GiB.

SeaStore's SegmentCleaner aborts mid-bench under sustained writes
when the per-OSD device is too small:
  src/crimson/os/seastore/async_cleaner.cc:
    abort(seastore device size setting is too small)

The minimum was bisected against a 90 s waf_bench.fio steady-state
run (4 KiB randwrite, iodepth=64, nrfiles=32, 4 OSDs):
  -  3 GiB: PASS (HEALTH_OK, no aborts)
  -  2 GiB: FAIL (3-of-4 OSDs aborted, HEALTH_WARN)
We round up from 3 to 4 GiB to keep a small safety margin.

Recommended: 20 GiB per OSD for comfortable headroom under longer
benches.
EOF
    exit 1
fi

# ---- Backing-mode selection ----
TOTAL_BYTES=$(( NUM_OSDS * SIZE_GB * 1024 * 1024 * 1024 ))
MEM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
MEM_BYTES=$(( MEM_KB * 1024 ))
MEM_THRESHOLD_BYTES=$(( MEM_BYTES * 3 / 4 ))

human() {
    awk -v b="$1" 'BEGIN {
        if (b >= 1024^4) printf "%.2f TiB", b/(1024^4);
        else if (b >= 1024^3) printf "%.1f GiB", b/(1024^3);
        else printf "%.0f MiB", b/(1024^2);
    }'
}

if [ "$BACKING" = "auto" ]; then
    if [ "$TOTAL_BYTES" -le "$MEM_THRESHOLD_BYTES" ]; then
        EFFECTIVE_BACKING="memory"
        REL_OP="<="
    else
        EFFECTIVE_BACKING="file"
        REL_OP=">"
    fi
else
    EFFECTIVE_BACKING="$BACKING"
    if [ "$TOTAL_BYTES" -le "$MEM_THRESHOLD_BYTES" ]; then
        REL_OP="<="
    else
        REL_OP=">"
    fi
fi

if [ "$POLLED" = "1" ] && [ "$EFFECTIVE_BACKING" != "memory" ]; then
    echo "[setup] WARNING: polled mode requires memory backing; effective backing is '$EFFECTIVE_BACKING' — falling back to non-polled." >&2
    POLLED=0
fi

echo "[setup] Backing: $EFFECTIVE_BACKING (total $(human $TOTAL_BYTES) $REL_OP 75% of $(human $MEM_BYTES) MemTotal = $(human $MEM_THRESHOLD_BYTES))"
if [ "$POLLED" = "1" ]; then
    echo "[setup] Polled mode: ON ($POLL_QUEUES_PER_DEV poll_queues per device, mq queue_mode)"
else
    echo "[setup] Polled mode: OFF"
fi

check_null_blk() {
    # Check if module is available
    if ! modinfo null_blk >/dev/null 2>&1; then
        cat <<EOF >&2
ERROR: null_blk kernel module is not available on this system.

This script requires null_blk to emulate block devices. To install:
  Ubuntu/Debian:  sudo apt install linux-modules-extra-\$(uname -r)
  RHEL/CentOS:    ensure kernel-modules-extra is installed
  Custom kernel:  rebuild with CONFIG_BLK_DEV_NULL_BLK=m

Then verify:
  sudo modprobe null_blk && lsmod | grep null_blk

This script does NOT fall back to alternative emulation backends.
Re-run after null_blk is installed and loadable.
EOF
        exit 1
    fi

    if ! grep -q "^null_blk" /proc/modules; then
        if ! sudo modprobe null_blk nr_devices=0 >/dev/null 2>&1; then
            cat <<EOF >&2
ERROR: null_blk kernel module is not available on this system.

This script requires null_blk to emulate block devices. To install:
  Ubuntu/Debian:  sudo apt install linux-modules-extra-\$(uname -r)
  RHEL/CentOS:    ensure kernel-modules-extra is installed
  Custom kernel:  rebuild with CONFIG_BLK_DEV_NULL_BLK=m

Then verify:
  sudo modprobe null_blk && lsmod | grep null_blk

This script does NOT fall back to alternative emulation backends.
Re-run after null_blk is installed and loadable.
EOF
            exit 1
        fi
    fi
}

check_losetup() {
    if ! command -v losetup >/dev/null 2>&1; then
        cat <<EOF >&2
ERROR: losetup not found (util-linux). File-backed mode requires losetup.
       Install util-linux and re-run.
EOF
        exit 1
    fi
    mkdir -p "$BASE_DIR"
    AVAIL_BYTES=$(df --output=avail -B1 "$BASE_DIR" | tail -n 1 | tr -d ' ')
    NEED_BYTES=$(( TOTAL_BYTES * 105 / 100 ))
    if [ "$AVAIL_BYTES" -lt "$NEED_BYTES" ]; then
        cat <<EOF >&2
ERROR: insufficient free space at $BASE_DIR for file-backed mode.
       required (with 5% headroom): $(human "$NEED_BYTES")
       available:                   $(human "$AVAIL_BYTES")
       Suggest: re-run with <BASE_DIR> on a larger filesystem.
EOF
        exit 1
    fi
    echo "[setup] Sparse file dir: $BASE_DIR (free: $(human "$AVAIL_BYTES"))"
}

if [ "$EFFECTIVE_BACKING" = "memory" ]; then
    check_null_blk
else
    check_losetup
fi

echo "Setting up $NUM_OSDS device(s) of ${SIZE_GB}GB ($EFFECTIVE_BACKING mode)..."

for ((i=0; i<NUM_OSDS; i++)); do
    OSD_DIR="$BASE_DIR/osd$i"
    mkdir -p "$OSD_DIR"

    if [ "$EFFECTIVE_BACKING" = "memory" ]; then
        DEV_NAME="nullb$i"
        DEV_PATH="/dev/$DEV_NAME"
        CONFIG_DIR="/sys/kernel/config/nullb/$DEV_NAME"

        # Clean up existing instance if any
        if [ -d "$CONFIG_DIR" ]; then
            echo 0 | sudo tee "$CONFIG_DIR/power" >/dev/null
            sudo rmdir "$CONFIG_DIR"
        fi

        sudo mkdir -p "$CONFIG_DIR"
        echo "$((SIZE_GB * 1024))" | sudo tee "$CONFIG_DIR/size" >/dev/null
        echo 4096 | sudo tee "$CONFIG_DIR/blocksize" >/dev/null
        if [ "$POLLED" = "1" ]; then
            # mq mode is required for polled completion queues. irqmode=1
            # (softirq) covers the non-polled queues; polled queues skip IRQs
            # entirely and complete only when the consumer polls.
            echo 2 | sudo tee "$CONFIG_DIR/queue_mode" >/dev/null
            echo 1 | sudo tee "$CONFIG_DIR/irqmode" >/dev/null
            echo "$POLL_QUEUES_PER_DEV" | sudo tee "$CONFIG_DIR/poll_queues" >/dev/null
        else
            echo 0 | sudo tee "$CONFIG_DIR/queue_mode" >/dev/null
            echo 0 | sudo tee "$CONFIG_DIR/irqmode" >/dev/null
        fi
        echo 1 | sudo tee "$CONFIG_DIR/memory_backed" >/dev/null
        echo 1 | sudo tee "$CONFIG_DIR/power" >/dev/null

        udevadm settle || sleep 1

        if [ ! -b "$DEV_PATH" ]; then
            echo "Error: Device $DEV_PATH was not created." >&2
            exit 1
        fi

        sudo chmod 666 "$DEV_PATH"
        dd if=/dev/zero of="$DEV_PATH" bs=1M count=100 conv=fsync
        echo "$DEV_PATH" > "$OSD_DIR/device_path"
        if [ "$POLLED" = "1" ]; then
            echo "memory-polled" > "$OSD_DIR/backing_mode"
        else
            echo "memory" > "$OSD_DIR/backing_mode"
        fi
        echo "Initialized $DEV_PATH for OSD $i in $OSD_DIR"
    else
        # File-backed: pre-allocated image + loop device with direct I/O.
        # Force a 4 KiB logical sector size — seastore aborts on mount
        # with "block_size >= laddr_t::UNIT_SIZE" (i.e. >= 4096) and
        # losetup defaults to 512.
        IMG="$BASE_DIR/backing.img.$i"
        fallocate -l "${SIZE_GB}G" "$IMG"
        DEV_PATH=$(sudo losetup --find --show --direct-io=on --sector-size 4096 "$IMG")
        if [ ! -b "$DEV_PATH" ]; then
            echo "Error: losetup did not return a usable device for $IMG" >&2
            exit 1
        fi
        sudo chmod 666 "$DEV_PATH"
        echo "$DEV_PATH" > "$OSD_DIR/device_path"
        echo "file" > "$OSD_DIR/backing_mode"
        echo "Initialized $DEV_PATH (pre-allocated $IMG) for OSD $i in $OSD_DIR"
    fi
done

echo "Setup complete."
