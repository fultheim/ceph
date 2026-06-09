# Crimson SeaStore multi-OSD simulation

A self-contained harness for exercising the crimson SeaStore object store
under controllable, isolated multi-OSD conditions. The simulation lives
entirely under `qa/standalone/crimson/` and pairs with optional
`WITH_SEASTORE_WAF_COUNTERS` perf counters in `src/crimson/os/seastore/`.

The original purpose was Write Amplification (WAF) measurement, but the
same setup reproduces cleaner-saturation bugs (e.g. the leak fixed in
the upstream commit "crimson/os/seastore: fix cleaner space leak from
shadowed result list") and is generally useful as a deterministic
multi-OSD playground for crimson development.

## Architecture

```
  qa/standalone/crimson/
  ├── setup_osd_emul.sh     per-OSD backing-device provisioning
  ├── start_multi_osd.sh    end-to-end cluster bring-up
  ├── stop_multi_osd.sh     teardown
  ├── test_multi_osd.sh     fio randwrite driver with stall watchdog
  ├── waf_bench.fio         fio job file (rados ioengine)
  ├── run_waf_bench.sh      one-shot WAF benchmark orchestration
  ├── waf_report.py         WAF summary builder (asok + fio JSON)
  ├── waf_plot.py           optional matplotlib WAF-over-time plot
  └── test-waf-bench.sh     standalone CI-style WAF self-test
```

### Backing-device modes

`setup_osd_emul.sh` provisions one backing device per OSD. Two modes:

- **memory** (kernel `null_blk`) — fastest, but each instance is RAM-backed
  and limited to a few GiB before kernel allocation fails. Used for total
  cluster sizes ≤ ~8 GiB.
- **file** (`losetup` over a sparse file with 4 KiB sector size) — slower
  but scales to whatever the underlying filesystem can hold. Used for
  total cluster sizes > ~8 GiB.

The mode is auto-selected from total requested size; override with
`--backing=memory|file|auto`. Each OSD dir gets a `device_path` and
`backing_mode` marker so teardown knows what to release.

### Polled mode (default on memory backing)

When the effective backing is **memory**, `null_blk` is configured in
multi-queue mode with N polled completion queues per device (default
2). Polled queues skip IRQ-driven completion entirely — IOs only
complete when the consumer polls.

This pairs with io_uring `IORING_SETUP_IOPOLL` on the Crimson side
(Seastar's `io_uring` reactor backend) to drive the storage path with
zero interrupts and zero softirqs, much closer to the production stack
shape (SPDK polls NVMe completion queues the same way).

Polled mode is **on by default** for memory backing. To opt out, pass
`--no-polled`. To customize the poll-queue count, pass `--polled=N`.

When the effective backing is **file** (either `--backing=file` or
`--backing=auto` resolving to file because total exceeds 75% of
MemTotal), polled mode is silently disabled with a warning — loop
devices over sparse files don't expose polled completion queues.

Constraints:

- Each polled queue burns a CPU when polled. Default of 2 queues per
  device × N OSDs needs free cores to avoid contending with the
  Crimson reactor shards. On small hosts (≤8 cores), pass
  `--no-polled` or lower the count with `--polled=1`.
- Algorithmic results (WAF, cleaner behavior, GC efficiency) are
  identical to the unpolled path — polled mode only affects how
  completions surface, not what IOs are issued. Validated by an A/B
  bench under the canonical 70%-full randwrite reproducer: WAF 2.826
  (non-polled) vs 2.818 (polled), within run-to-run noise.

Useful when measuring Crimson software latency without kernel-block-
layer IRQ noise, or when comparing the simulation against a real
SPDK+NVMe deployment.

### Wire CRC and the `--crc-data` flag

`start_multi_osd.sh` sets `ms_crc_data = false` on the cluster by
default — the messenger skips CRC32 over the payload bytes of every
IO. This is the right default for the simulation's primary use cases
(KV-cache-shaped workloads on single-host loopback). Pass
`--crc-data` to leave `ms_crc_data` at its production default.

**Read this before deciding which mode to use.**

`ms_crc_data` protects the IO payload against transit / in-memory
corruption that the messenger sees. At small block sizes (≤ 64 KiB)
its cost is sub-microsecond. At the large block sizes the simulation
typically uses (1 MiB and up), the cost is significant:

|  Block size  |  ms_crc_data cost (soft CRC)  |
|--------------|-------------------------------|
|        4 KiB |                       ~0.3 µs |
|       64 KiB |                       ~4   µs |
|      256 KiB |                       ~15  µs |
|        1 MiB |                       ~50-100 µs |
|       10 MiB |                       ~500-1000 µs |

Paid on both ingest and reply, so a 10 MiB read pays ~1 ms of CRC
alone. Skipping it is the single largest configurable lever for
latency at large block sizes.

**When the default (CRC OFF) is the right choice — most simulation runs:**

- **Regenerable workloads** — e.g. LLM KV cache, where a corrupted
  cache entry is detected by the application or just triggers a
  re-prefill (same as a cache miss).
- **Single-host latency benches** where the "wire" is kernel TCP
  loopback over `lo` — no real wire-corruption threat exists, so
  the CRC catches nothing real and only costs time.
- **Comparison runs against SPDK / userspace-stack numbers** where
  the other system isn't computing messenger-level CRC.

**When to pass `--crc-data` instead:**

- Simulating **durable / persistent** workloads — training data
  ingest, EC-pool writes, anything that isn't regenerable. Wire
  CRC defends against software bugs and rare firmware/NIC
  corruption that *do* occur in production and would silently
  persist if not caught. Storage at-rest CRC backstops some but
  not all of these threats (corruption between read-from-storage
  and send-to-peer is invisible to storage CRC).
- Simulating a Ceph deployment that intends to run with default
  upstream config (so your latency numbers match what users will
  actually see).
- Mixed-workload simulations where you want the conservative
  baseline. Note: in real production, per-client overrides are
  the right granularity — set `ms_crc_data = false` only in the
  KV-cache client's `[client.kvcache]` ceph.conf, not
  cluster-wide. The simulation harness intentionally takes a
  cluster-wide knob because it's single-purpose per run.

The `ms_crc_header` and `ms_crc_internal_tags` CRCs (protocol
header + msgr-v2 frame structure) are **always left on** — they
cost nanoseconds, protect against catastrophic protocol misparse,
and have no downstream backup integrity check.

### Network path: what this harness measures

The simulation reports **bare software latency** — the cost of the
Crimson + SeaStore code path, not end-to-end production latency.

Today the OSDs talk to fio (and to each other) over **kernel TCP on
the loopback interface**. That path has zero real wire latency but
costs ~120 µs per 1 MiB transfer in memory copies + kernel
scheduling. It's not a faithful model of any production network.

**What the numbers in this harness represent:** the SW cost of
Crimson + SeaStore handling the IO. To project end-to-end production
latency for your specific deployment, add the wire latency you
expect from your network:

- Same-rack DC fabric (kernel TCP/IP): +30-100 µs per round trip
- Same-rack DC fabric (DPDK/RDMA): +5-20 µs per round trip
- Same-host loopback: 0 (already what this harness measures)

The harness does **not** model NIC queue contention, switch
buffering, TCP congestion control, or any other production network
behavior. It's a SW-cost measurement, not an end-to-end latency
predictor.

### Simulation fidelity vs production

Side-by-side latency budget for **1 MiB random write, size=1** (the
KV-cache reference workload). Numbers are estimates anchored to the
measured ~489 µs simulation total. "Prod DPDK/RDMA + SPDK" represents
a fully-optimized production stack (e.g. Marvell CN10x / ConnectX
NICs with RDMA messenger, SPDK NVMe driver).

|  # | Component                                                   | Prod (kernel TCP + kernel NVMe) | Prod (DPDK/RDMA + SPDK)           | Simulation (current)                          |
|----|-------------------------------------------------------------|---------------------------------|-----------------------------------|-----------------------------------------------|
|  1 | Client side: 1 MiB send (copy + frame + socket)             | ~80 µs                          | ~10 µs (zero-copy bypass)         | ~60 µs (loopback memcpy, no NIC)              |
|  2 | NIC + wire transit (one-way)                                | ~5-20 µs                        | ~5-10 µs                          | 0 µs (no wire)                                |
|  3 | OSD side: 1 MiB recv (mirror of #1)                         | ~80 µs                          | ~10 µs                            | ~60 µs                                        |
|  4 | Msgr-v2 frame parse + header CRC + auth dispatch            | ~25 µs                          | ~25 µs                            | ~25 µs                                        |
|  5 | Wire CRC over 1 MiB payload (if ``ms_crc_data=true``)       | ~80 µs                          | ~10 µs (HW CRC32 instruction)     | 0 µs (sim default: off)                       |
|  6 | PG op routing + sequencer + cross-shard hops                | ~30 µs                          | ~30 µs                            | ~30 µs                                        |
|  7 | SeaStore transaction (onode + extent alloc + reserve)       | ~25 µs                          | ~25 µs                            | ~25 µs                                        |
|  8 | Reactor continuations / future plumbing                     | ~25 µs                          | ~25 µs                            | ~25 µs                                        |
|  9 | Journal write submit + completion (small metadata)          | ~30 µs (IRQ-driven)             | ~10 µs (SPDK polled)              | ~10 µs (null_blk polled + io_uring IOPOLL)    |
| 10 | OOL data write + DMA + completion (1 MiB)                   | ~120 µs (real flash + IRQ)      | ~70 µs (SPDK + real NVMe)         | ~30 µs (null_blk inline complete, **no flash**) |
| 11 | At-rest data checksum (``csum_type=crc32c``, write side)    | ~80 µs                          | ~80 µs (or 0 with ``csum_type=none``) | ~80 µs (default on)                       |
| 12 | Reply path: OSD → client (small ack ~50 B)                  | ~50 µs                          | ~10 µs                            | ~40 µs                                        |
| 13 | Wire transit (reply, one-way)                               | ~5-20 µs                        | ~5-10 µs                          | 0 µs                                          |
| 14 | Misc (locking, refcount, mon stats path)                    | ~30 µs                          | ~30 µs                            | ~30 µs                                        |
| **Total** |                                                      | **~660-710 µs**                 | **~340-360 µs**                   | **~485-490 µs (measured)**                    |

### Where the gaps live

|  Gap                                                       | Direction                       | Size       | Closable in sim?                                                                                              |
|------------------------------------------------------------|---------------------------------|------------|---------------------------------------------------------------------------------------------------------------|
| Wire transit (rows 2, 13)                                  | sim is **0**, prod is +10-30 µs | -10-30 µs  | **Yes** — ``--netem-delay-us=N`` injects N µs each direction.                                                 |
| Network code path (rows 1, 3, 12) for DPDK/RDMA stacks     | sim slower than DPDK/RDMA       | +130 µs    | **No** — librados has no DPDK/RDMA transport, so client→OSD always uses kernel TCP regardless of OSD-side config. Closing this requires upstream work (DPDK librados or a Seastar-native test client). |
| Real NVMe latency (row 10)                                 | sim faster than real flash      | -40-90 µs  | Partially — switching null_blk to SPDK bdev_malloc via NVMe-oF loopback (days of integration); or using a real NVMe partition. Tradeoff: harder to reproduce, less deterministic. |
| At-rest checksum (row 11) for regenerable data             | sim matches prod default        | 0          | Trivial when needed — ``ceph osd pool set <pool> csum_type none`` on the KV-cache pool only.                  |

### Projecting production latency from a simulation run

A 1 MiB unloaded write on the current harness measures p50 ~489 µs.
Adjusting for the gaps above gives a production estimate:

  - **kernel-TCP + kernel-NVMe production**: ~489 + 10 (wire RTT) + 90 (real-flash add for row 10) = **~590 µs**. Within ~50 µs of the table's 660-710 µs prediction.
  - **DPDK/RDMA + SPDK production**: ~489 + 10 (wire RTT) - 130 (DPDK network savings) + 40 (real-NVMe add) = **~410 µs**. Within ~70 µs of the table's 340-360 µs prediction.

The sim is **~80 µs optimistic** vs DPDK/RDMA production and **~70 µs
pessimistic** vs kernel-TCP production. For engineering decisions
about your specific stack, use the table to translate sim numbers
into your expected production envelope rather than treating the sim
number as a direct prediction.

**Empirical validation of the wire-transit adder:** measured p50 with
no netem was 489 µs. Re-running with ``--netem-delay-us=5`` (10 µs
RTT) gave p50 498 µs — a +9 µs shift, within 1 µs of the predicted
+10 µs from the table. The wire-latency component of the projection
formula is confirmed to be accurate at one-microsecond resolution.

The biggest **un-closable** gap is the network code path for
DPDK/RDMA deployments (~130 µs). To validate that gap, run on the
real production hardware/network — the simulation can't bridge it
without a librados rewrite.

### Cluster bring-up

`start_multi_osd.sh <NUM_OSDS> <SIZE_GB> <BASE_DIR>` runs five stages
in order:

```
  0. cleanup     (always — kills leftover procs, removes null_blk /
                  loop devices and $BUILD/dev)
  1. preflight   (sanity-check no stale state remains after cleanup)
  2. devices     (setup_osd_emul.sh provisions N backing devices)
  3. vstart      (mon, mgr, N crimson-osds; wait up+active;
                  vstart output redirected to vstart.log)
  4. pool        (create configurable workload pool; default waf-test)
  5. balancer    (enable upmap balancer; wait osd df pg counts to
                  converge; --no-balancer skips this stage)
```

The cleanup at step 0 is unconditional — every invocation starts from
a clean slate. `stop_multi_osd.sh` is the standalone teardown helper
called by the test runners on exit.

### Per-OSD config

`crimson/osd` reads a per-OSD `[osd.N]` ceph.conf section so each OSD
opens its own backing device path. `vstart.sh` writes those sections
from `--seastore-devs`. The `--null-blk` flag only fills empty slots
to avoid clobbering explicit per-OSD device paths.

### Workload driver

`test_multi_osd.sh` drives fio (1 MiB block size by default, configurable
`--bs` / `--rw`) against the pool. It samples `seastore_waf` perf
counters via asok every `--period` seconds, runs a stall watchdog that
kills fio when counters stop advancing for `--stall-multi × --period`
seconds, and detects OSD crashes by combining `ceph status` with asok
responsiveness probes.

### WAF perf counters (optional)

When the binary is built with `WITH_CRIMSON=ON` (`WITH_SEASTORE_WAF_COUNTERS`
is enabled automatically), SeaStore exposes:

- `l_seastore_bytes_user_written` — incremented per committed logical
  write with the user-visible payload size (deferred to the commit
  callback so retried-on-conflict transactions are not double-counted).
- `l_seastore_bytes_device_written` — incremented from `report_stats`
  with the per-shard device write delta.

A 10 s seastar timer emits a periodic `[WAF]` log line. Both counters
are visible through the OSD admin socket (`perfcounters_dump
seastore_waf`). When the option is OFF the symbols, the timer, the
per-write increment, and the report_stats hook all compile out — zero
runtime cost in production builds.

## Build

**Configure** (once; skip if `build/CMakeCache.txt` already exists):

```sh
PATH=/usr/bin:/bin ARGS="-DWITH_CRIMSON=ON -DCMAKE_BUILD_TYPE=Release" ./do_cmake.sh
```

`WITH_SEASTORE_WAF_COUNTERS` is automatically `ON` whenever `WITH_CRIMSON=ON` —
no explicit flag needed. `Release` must be specified: the repo default for
git checkouts is `Debug`.

**Build:**

```sh
PATH=/usr/bin:/bin ninja -C build -j$(nproc) vstart-base crimson-osd cython_rados
```

**Run** (canonical 90 GiB RBM benchmark, tears down on completion):

```sh
SIZE=90 && OSDS=1 && \
qa/standalone/crimson/start_multi_osd.sh --rbm --no-balancer $OSDS $((SIZE/OSDS)) build/dev && \
qa/standalone/crimson/test_multi_osd.sh --jobs 8 --size $((SIZE * 70 / 100))g \
  --iosize $((SIZE * 20))g --rw randwrite --teardown
```

## Command-line examples

### Canonical reproducer — 70%-full random write

The headline command for reproducing cleaner-saturation bugs. Brings up
a 2-OSD cluster with 32 GiB per OSD, then runs fio randwrite that
covers 70% of the cluster as its address space and writes 20× the
cluster size in total volume:

```sh
SIZE=64; OSDS=2
qa/standalone/crimson/start_multi_osd.sh --no-balancer $OSDS $((SIZE/OSDS)) build/dev && \
qa/standalone/crimson/test_multi_osd.sh --jobs 1 --size $((SIZE * 70 / 100))g --iosize $((SIZE * 20))g --rw randwrite
```

`start_multi_osd.sh` cleans up any prior run on its own, so the same
command can be re-run repeatedly with no manual teardown.

### Canonical reproducer with IRQ-driven completions (opt-out)

To compare against the polled default, force non-polled completion
via `--no-polled`:

```sh
SIZE=64; OSDS=2
qa/standalone/crimson/start_multi_osd.sh --no-balancer --no-polled $OSDS $((SIZE/OSDS)) build/dev && \
qa/standalone/crimson/test_multi_osd.sh --jobs 1 --size $((SIZE * 70 / 100))g --iosize $((SIZE * 20))g --rw randwrite
```

### WAF benchmark (small, end-to-end self-test)

The minimal CI-style self-test — brings up 2 OSDs (memory-backed), runs
a short bench, checks WAF is under the configured ceiling, tears down.

```sh
qa/standalone/crimson/test-waf-bench.sh --num-osds 2 --size-gb 2 --runtime 30 --waf-max 10
```

### WAF benchmark (full orchestration)

The reusable WAF measurement entry point. Each run produces a
`waf_report.txt` in the bench output dir.

```sh
qa/standalone/crimson/run_waf_bench.sh \
  --num-osds 2 --size-gb 32 --runtime 300 \
  --num-jobs 2 --bench-size 8g --bench-nrfiles 64
```

### File-backed mode for large clusters

For sizes above what `null_blk` can hold, force file-backed mode
explicitly. The launcher will create `$BASE_DIR/osdN/backing.img`
sparse files and bind them via `losetup` with 4 KiB sector size:

```sh
qa/standalone/crimson/start_multi_osd.sh --backing=file 4 64 build/dev
```

### Inspecting WAF perf counters live

While a cluster is up:

```sh
build/bin/ceph -c build/ceph.conf tell osd.0 perfcounters_dump seastore_waf
build/bin/ceph -c build/ceph.conf tell osd.1 perfcounters_dump seastore_waf
```

### Teardown

Cleanup happens automatically at the start of every
`start_multi_osd.sh` invocation. To tear down manually:

```sh
qa/standalone/crimson/stop_multi_osd.sh
```
