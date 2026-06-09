#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CEPH_ROOT="$(realpath "$SCRIPT_DIR/../../..")"
BASE_DIR="$CEPH_ROOT/build/dev"
RESULTS_ROOT="$CEPH_ROOT/build/dev_waf_results"

run_bench() {
    local seg_size="$1"
    local is_rbm=0
    local out_dir
    if [ "$seg_size" = "RBM" ] || [ "$seg_size" = "rbm" ]; then
        is_rbm=1
        out_dir="$RESULTS_ROOT/rbm"
        echo "=============================================================="
        echo "Starting benchmark for RBM (RANDOM_BLOCK_SSD)"
        echo "=============================================================="
    else
        out_dir="$RESULTS_ROOT/segment_$seg_size"
        echo "=============================================================="
        echo "Starting benchmark for segment size: $seg_size"
        echo "=============================================================="
    fi
    
    # 1. Cleanup
    echo "[prep] Cleaning up leftover state..."
    "$SCRIPT_DIR/stop_multi_osd.sh" "$BASE_DIR" >/dev/null 2>&1 || true
    rm -rf "$BASE_DIR"
    
    # 2. Start cluster
    echo "[prep] Starting multi-OSD cluster..."
    if [ "$is_rbm" = "1" ]; then
        "$SCRIPT_DIR/start_multi_osd.sh" --rbm=1G --rbm-meta=5G --no-balancer 1 90 "$BASE_DIR"
    else
        "$SCRIPT_DIR/start_multi_osd.sh" --segment-size "$seg_size" --no-balancer 1 90 "$BASE_DIR"
    fi
    
    # 3. Run test
    echo "[bench] Running benchmark..."
    # Disable exit-on-error temporarily in case test_multi_osd.sh fails (e.g. watchdog triggers)
    set +e
    "$SCRIPT_DIR/test_multi_osd.sh" --jobs 8 --size 63g --iosize 1800g --rw randwrite --no-teardown "$BASE_DIR"
    local rc=$?
    set -e
    echo "[bench] test_multi_osd.sh exited with code $rc"
    
    # 4. Generate plot
    echo "[plot] Generating WAF plot using waf_plot.py..."
    export WAF_NUM_OSDS=1
    export WAF_BASE_DIR="$BASE_DIR"
    export WAF_PLOT_OUT="$BASE_DIR/waf_bench/waf_over_time.png"
    python3 "$SCRIPT_DIR/waf_plot.py" || echo "[plot] WARNING: plotting failed"
    
    # 5. Archive results
    echo "[archive] Archiving results to $out_dir..."
    mkdir -p "$out_dir"
    if [ -d "$BASE_DIR/waf_bench" ]; then
        cp -r "$BASE_DIR/waf_bench"/* "$out_dir/"
    fi
    cp "$BASE_DIR/out/osd.0.log" "$out_dir/" 2>/dev/null || true
    cp "$BASE_DIR/out/mon.a.log" "$out_dir/" 2>/dev/null || true
    cp "$BASE_DIR/out/mgr.x.log" "$out_dir/" 2>/dev/null || true
    
    # 6. Teardown
    echo "[teardown] Stopping cluster..."
    "$SCRIPT_DIR/stop_multi_osd.sh" "$BASE_DIR" >/dev/null 2>&1 || true
    rm -rf "$BASE_DIR"
    
    echo "Finished scenario: $seg_size"
    echo "=============================================================="
}

mkdir -p "$RESULTS_ROOT"

# Run Run 1 (64M) - already completed
# run_bench "64M"

# Run Run 2 (512M) - already completed
# run_bench "512M"

# Run Run 3 (RBM)
run_bench "RBM"

# Regenerate comparative WAF plot including the new RBM run
echo "[plot] Generating comparative WAF plot..."
python3 "$SCRIPT_DIR/generate_comparative_chart.py" || echo "[plot] WARNING: comparative plotting failed"

echo "All benchmarks completed!"
