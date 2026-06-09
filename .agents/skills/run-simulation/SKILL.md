---
name: run-simulation
description: Build, run, and monitor the Crimson Ceph multi-OSD simulation benchmark.
---

# Run Crimson multi-OSD Simulation

This skill provides instructions on how to build, run, and monitor the Crimson Ceph multi-OSD simulation benchmark.

## Rules
- Never change the simulation script or benchmark parameters.
- Always Build before Run. Wait for build completion before starting the Run command.
- Start Monitor 15s after the Run command.

## Commands

### 0. Configure (skip if `build/CMakeCache.txt` already exists)
```bash
PATH=/usr/bin:/bin ARGS="-DWITH_CRIMSON=ON -DCMAKE_BUILD_TYPE=Release" ./do_cmake.sh
```

### 1. Build
Wait for build completion before starting the Run command.
```bash
PATH=/usr/bin:/bin ninja -C build -j$(nproc) vstart-base crimson-osd cython_rados
```

### 2. Run
Execute this in the background once the build completes successfully.
```bash
SIZE=90 && OSDS=1 && qa/standalone/crimson/start_multi_osd.sh --rbm --no-balancer $OSDS $((SIZE/OSDS)) build/dev && qa/standalone/crimson/test_multi_osd.sh --jobs 8 --size $((SIZE * 70 / 100))g --iosize $((SIZE * 20))g --rw randwrite --teardown
```

### 3. Monitor
Check the end of `build/dev/waf_bench/monitor.log` every 15 seconds and report progress.

## Workflow
1. Check if `build/CMakeCache.txt` exists. If not, execute the Configure command and wait for it to complete.
2. Execute the Build command.
3. Once the build finishes successfully, execute the Run command.
4. Wait 15 seconds.
5. Periodically (every 15 seconds) read the end of `build/dev/waf_bench/monitor.log` and report the progress.
6. Goal is to see if the run completes. If not, stop the run, teardown with `qa/standalone/crimson/stop_multi_osd.sh build/dev`, and wait for user instructions.
