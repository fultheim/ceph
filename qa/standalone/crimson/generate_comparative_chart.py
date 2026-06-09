#!/usr/bin/env python3
import os
import re
import sys
from datetime import datetime
from pathlib import Path

# Match line example:
# INFO  2026-05-10 18:54:45,614 [shard 0:main] seastore - SeaStore::Shard::log_waf_stats: \
# [WAF] osd.0 user_written=614408 device_written=1110016 waf=1.807
WAF_LINE_RE = re.compile(
    r"^\S+\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2}),\d+\s+\[shard\s+\d+:\S+\]\s+"
    r"seastore\s+-\s+SeaStore::Shard::log_waf_stats:\s+\[WAF\]\s+osd\.(\d+)\s+"
    r"user_written=(\d+)\s+device_written=(\d+)\s+waf=([0-9.]+)"
)

def parse_log(path: Path) -> list[tuple[float, float]]:
    samples = []
    if not path.exists():
        print(f"File not found: {path}", file=sys.stderr)
        return samples
    
    first_ts = None
    with path.open() as fh:
        for line in fh:
            m = WAF_LINE_RE.search(line)
            if not m:
                continue
            ts = datetime.strptime(f"{m.group(1)} {m.group(2)}", "%Y-%m-%d %H:%M:%S")
            waf = float(m.group(6))
            if first_ts is None:
                first_ts = ts
            elapsed_mins = (ts - first_ts).total_seconds() / 60.0
            samples.append((elapsed_mins, waf))
    return samples

def main():
    script_dir = Path(__file__).resolve().parent
    ceph_root = (script_dir / "../../..").resolve()
    results_dir = ceph_root / "build/dev_waf_results"
    
    scenarios = ["64M", "512M", "1G", "RBM"]
    
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ModuleNotFoundError:
        print("matplotlib not found", file=sys.stderr)
        return 1

    fig, ax = plt.subplots(figsize=(12, 6))
    
    for scenario in scenarios:
        if scenario == "RBM":
            log_path = results_dir / "rbm" / "osd.0.log"
            label = "RBM (RANDOM_BLOCK_SSD)"
        else:
            log_path = results_dir / f"segment_{scenario}" / "osd.0.log"
            label = f"Segment Size: {scenario}"
        print(f"Parsing {log_path}...")
        samples = parse_log(log_path)
        if not samples:
            print(f"No samples found for scenario: {scenario}", file=sys.stderr)
            continue
        xs = [x for x, _ in samples]
        ys = [y for _, y in samples]
        ax.plot(xs, ys, label=label, linewidth=2)
        
    ax.set_xlabel("Elapsed Time (Minutes)", fontsize=12)
    ax.set_ylabel("WAF (device_written / user_written)", fontsize=12)
    ax.set_title("Comparative SeaStore WAF over Time", fontsize=14, fontweight='bold')
    ax.grid(True, linestyle=":", alpha=0.6)
    ax.legend(loc="upper right", fontsize=10)
    ax.set_ylim(1, 7)
    
    # Save to build results dir
    plot_out = results_dir / "comparative_waf_plot.png"
    plt.tight_layout()
    plt.savefig(plot_out, dpi=150)
    print(f"Saved plot to {plot_out}")
    
    # Also save to artifact directory if it exists
    artifact_dir = Path("/home/shai/.gemini/antigravity-cli/brain/db919212-4556-49e4-81a2-ec0b60fc58bd")
    if artifact_dir.exists():
        artifact_plot_out = artifact_dir / "comparative_waf_plot.png"
        import shutil
        shutil.copy2(plot_out, artifact_plot_out)
        print(f"Copied plot to artifact path: {artifact_plot_out}")
        
    return 0

if __name__ == "__main__":
    sys.exit(main())
