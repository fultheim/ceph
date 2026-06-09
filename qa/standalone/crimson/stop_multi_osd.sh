#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 <BASE_DIR>"
    exit 1
}

if [[ $# -ne 1 ]]; then
    usage
fi

# `realpath -m` does not require the path to exist — important because
# start_multi_osd.sh's preflight calls this with a BASE_DIR that may be
# absent (first-ever run, or already-archived by a prior teardown).
BASE_DIR="$(realpath -m "$1")"
# Capture script directory at the start
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Stop all crimson-osd instances using pid files
echo "Stopping all crimson-osd instances..."
pids=()
for pid_file in "$BASE_DIR"/osd*/crimson-osd.pid; do
    if [[ -f "$pid_file" ]]; then
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Sending SIGTERM to process $pid..."
            kill -15 "$pid" 2>/dev/null || true
            pids+=("$pid")
        fi
    fi
done

# Wait for them to exit with a timeout, then force kill if necessary
if [ ${#pids[@]} -gt 0 ]; then
    echo "Waiting for crimson-osd instances to exit..."
    TIMEOUT=15
    elapsed=0
    while [ $elapsed -lt $TIMEOUT ]; do
        still_running=()
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                still_running+=("$pid")
            fi
        done
        if [ ${#still_running[@]} -eq 0 ]; then
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    # Force kill any remaining processes
    for pid in "${pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "Process $pid did not exit after ${TIMEOUT}s, sending SIGKILL..."
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
fi

# Clean up pid files
for pid_file in "$BASE_DIR"/osd*/crimson-osd.pid; do
    if [[ -f "$pid_file" ]]; then
        rm -f "$pid_file"
    fi
done

# 2. Stop vstart cluster
CEPH_ROOT=$(realpath "$SCRIPT_DIR/../../..")
if [ -d "$CEPH_ROOT/build" ]; then
    echo "Stopping vstart MON/MGR cluster..."
    cd "$CEPH_ROOT/build"
    ../src/stop.sh || true
else
    echo "Skipping vstart stop ($CEPH_ROOT/build absent)"
fi

# 3. Teardown emulated block devices
echo "Tearing down emulated devices..."
"$SCRIPT_DIR/setup_osd_emul.sh" --teardown "$BASE_DIR"

# 4. Strip any netem qdisc that start_multi_osd.sh added to lo.
if tc qdisc show dev lo 2>/dev/null | grep -q netem; then
    sudo tc qdisc del dev lo root 2>/dev/null || true
    echo "Removed netem qdisc from lo"
fi

echo "Teardown complete."