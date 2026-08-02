# disk-benchmark

Scripts that automate storage benchmarking, built for comparing configurations such as Non-RAID, RAID0, and RAID1. While each test runs, they also sample CPU, memory, and disk utilization concurrently.

- Windows: [windows/Run-DiskBenchmark.ps1](windows/Run-DiskBenchmark.ps1), using Microsoft [DiskSpd](https://github.com/microsoft/diskspd).
- Linux: [linux/run-disk-benchmark.sh](linux/run-disk-benchmark.sh), using [fio](https://github.com/axboe/fio).

Both run the same 6-test matrix (mirrors CrystalDiskMark's default profile), so their CSVs can be combined for cross-platform comparison. macOS support is planned.

## Windows setup

1. Download DiskSpd from the [releases page](https://github.com/microsoft/diskspd/releases) and unzip it.
2. Place `amd64\diskspd.exe` next to `windows/Run-DiskBenchmark.ps1`, or pass its location with `-DiskSpdPath`.
3. Run PowerShell **as Administrator** (elevation is needed to create the test file at a drive root).
4. If execution policy blocks the script, run this first:

   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   ```

   Cache bypass via `-Sh` (unbuffered + write-through) works without elevation too, but a non-admin session can trigger DiskSpd's own `SeManageVolumePrivilege` warnings (error code 1300) while preparing the test file. These only affect file-prep time, not the measured results.

### Windows usage

```powershell
# Non-RAID: measure E: and F: individually
.\windows\Run-DiskBenchmark.ps1 -Drives E,F -Config NonRAID

# After building a RAID0 array (e.g. mounted as R:)
.\windows\Run-DiskBenchmark.ps1 -Drives R -Config RAID0

# After building a RAID1 array
.\windows\Run-DiskBenchmark.ps1 -Drives R -Config RAID1
```

Run each configuration (NonRAID → RAID0 → RAID1) and combine the resulting CSVs later for comparison.

### Windows parameters

| Parameter | Default | Description |
|---|---|---|
| `-Drives` | `E,F` | Target drive letter(s), one or more |
| `-Config` | `NonRAID` | Config label recorded in the CSV as the comparison axis: `NonRAID` / `RAID0` / `RAID1` |
| `-SizeGB` | `8` | Test file size in GB; use a size large enough to exceed the SSD's cache |
| `-Duration` | `30` | Duration of each test in seconds |
| `-DiskSpdPath` | auto-detected | Path to `diskspd.exe`; if omitted, the script looks next to itself, in an `amd64` subfolder, and on PATH |
| `-OutDir` | same folder as the script | Output folder for the result CSV |
| `-Iterations` | `1` | Number of times to repeat each test, to gauge run-to-run variance (recorded in the `Iteration` column) |

## Linux setup

1. Install fio and jq:

   ```bash
   # Debian/Ubuntu
   sudo apt install fio jq
   # RHEL/Fedora
   sudo dnf install fio jq
   ```

2. Each `--targets` entry is either a directory/mount point (a test file is created inside it) or a raw block device such as `/dev/nvme1n1` (**all data on it is destroyed** — use with care).
3. Root is not required for O_DIRECT cache bypass, but it's recommended: writing to some mount points, and any use of a raw block device, may need root.

### Linux usage

```bash
# Non-RAID: measure two mount points individually
./linux/run-disk-benchmark.sh --targets /mnt/d1,/mnt/d2 --config NonRAID

# After building a RAID0 array (e.g. mounted at /mnt/raid)
./linux/run-disk-benchmark.sh --targets /mnt/raid --config RAID0

# After building a RAID1 array
./linux/run-disk-benchmark.sh --targets /mnt/raid --config RAID1
```

Run each configuration (NonRAID → RAID0 → RAID1) and combine the resulting CSVs later for comparison.

### Linux parameters

| Parameter | Default | Description |
|---|---|---|
| `--targets`, `-T` | *(required)* | Comma-separated list of mount points / directories / raw block devices, one or more |
| `--config`, `-c` | `NonRAID` | Config label recorded in the CSV as the comparison axis: `NonRAID` / `RAID0` / `RAID1` |
| `--size-gb`, `-s` | `8` | Test file size in GB; use a size large enough to exceed the SSD's cache |
| `--duration`, `-d` | `30` | Duration of each test in seconds |
| `--fio-path` | auto-detected | Path to `fio`; if omitted, the script looks on PATH |
| `--ioengine` | `libaio` | fio ioengine (e.g. `io_uring` on newer kernels/fio) |
| `--outdir`, `-o` | same folder as the script | Output folder for the result CSV |
| `--iterations`, `-i` | `1` | Number of times to repeat each test, to gauge run-to-run variance (recorded in the `Iteration` column) |

## What gets measured

For each drive/target, the script runs 6 tests (Read/Write across 3 patterns), mirroring CrystalDiskMark's default profile.

| Test | Description | DiskSpd options | fio options |
|---|---|---|---|
| `SEQ1M-Q8T1` | Sequential, 1MB blocks, queue depth 8 | `-b1M -o8 -t1` | `--bs=1M --iodepth=8 --numjobs=1` |
| `RND4K-Q32T16` | Random parallel IOPS (OS/app/DB-style workload) | `-b4K -o32 -t16 -r` | `--bs=4k --iodepth=32 --numjobs=16` |
| `RND4K-Q1T1` | Random, QD1 (responsiveness/latency) | `-b4K -o1 -t1 -r` | `--bs=4k --iodepth=1 --numjobs=1` |

- Windows common options: `-Sh` (disable caching, unbuffered, write-through), `-L` (latency), `-W5` (5s warmup), `-C1` (1s cooldown).
- Linux common options: `--direct=1` (bypass page cache), `--ioengine=libaio` (async I/O so `--iodepth` is meaningful), `--ramp_time=5` (5s warmup, excluded from stats).

## Concurrent utilization sampling

Each run's engine (DiskSpd / fio) is launched as a background process, and while it runs the script samples the following once per second, recording the average and maximum for each test:

**Windows** (via CIM classes, language-neutral so it works on localized Windows too):
- **CPU**: `Win32_PerfFormattedData_PerfOS_Processor` (total processor busy % for `_Total`)
- **Memory**: `Win32_OperatingSystem` (percentage of physical memory in use)
- **Disk**: `Win32_PerfFormattedData_PerfDisk_LogicalDisk` (`100 - % Idle Time` for the target drive)

**Linux** (via `/proc`):
- **CPU**: `/proc/stat` (`100 - idle - iowait`, delta between samples)
- **Memory**: `/proc/meminfo` (`(MemTotal - MemAvailable) / MemTotal`)
- **Disk**: `/proc/diskstats` field 13 (time spent doing I/Os), delta over wall-clock time — the same method `iostat` uses for `%util`. The target path is resolved to its own device/partition/array name (symlinks such as `/dev/mapper/...` are canonicalized), matching the Windows script's per-logical-disk semantics.

## Output

Each test's result is printed to the console like this:

```
SEQ1M-Q8T1-Read          559.3 MB/s |        533 IOPS |  14.997 ms  ||  CPU  14/ 31%  Mem  18%  Disk  95/100%
```

Every run writes a fresh, timestamped CSV to `-OutDir` / `--outdir` (default: the script's own folder), named after the config and run time (e.g. `DiskBenchmark_NonRAID_20260730_131538.csv`). Both scripts write the same columns, so CSVs from Windows and Linux runs can be combined directly.

CSV columns:

| Column | Description |
|---|---|
| `Timestamp` | Run timestamp |
| `Config` | Config label (NonRAID/RAID0/RAID1) |
| `Drive` | Drive letter (Windows) or target path/device (Linux) |
| `Test` | Test name |
| `Iteration` | Repeat count (`-Iterations` / `--iterations`) |
| `MBps` | Throughput in MB/s (decimal) |
| `IOPS` | IOPS |
| `AvgLat_ms` | Average latency (ms) |
| `CPU_Avg_pct` / `CPU_Max_pct` | Average / max CPU utilization |
| `Mem_Avg_pct` / `Mem_Max_pct` | Average / max memory utilization |
| `Disk_Avg_pct` / `Disk_Max_pct` | Average / max utilization of the target drive |
| `IsAdmin` | Whether the run was elevated (Administrator on Windows, root on Linux) |
| `SizeGB` | Test file size |
| `Duration_sec` | Test duration in seconds |

Example:

```csv
"Timestamp","Config","Drive","Test","Iteration","MBps","IOPS","AvgLat_ms","CPU_Avg_pct","CPU_Max_pct","Mem_Avg_pct","Mem_Max_pct","Disk_Avg_pct","Disk_Max_pct","IsAdmin","SizeGB","Duration_sec"
"2026-07-30 13:15:38","NonRAID","E","SEQ1M-Q8T1-Read","1","559.31","533","14.997","13.9","31","18","18.1","94.5","100","True","8","30"
"2026-07-30 13:15:38","NonRAID","E","SEQ1M-Q8T1-Write","1","486.56","464","17.239","12.2","28","17.9","18","99.8","100","True","8","30"
```

## Roadmap

- macOS script
