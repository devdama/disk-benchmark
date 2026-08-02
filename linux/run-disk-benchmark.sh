#!/usr/bin/env bash
#=====================================================================
# run-disk-benchmark.sh
# ---------------------------------------------------------------------
# Automated SSD performance test (compare Non-RAID / RAID0 / RAID1).
# Engine : fio (Linux equivalent of Microsoft DiskSpd)
# Also samples CPU / Memory / Disk utilization DURING each test.
# Output : on-screen summary + a fresh, timestamped CSV per run
#
# This is the Linux counterpart of windows/Run-DiskBenchmark.ps1 and
# runs the same 6-test matrix (mirrors CrystalDiskMark defaults), so
# CSVs from both scripts can be combined for comparison.
#
# Examples:
#   # Non-RAID: measure two mount points individually
#   ./run-disk-benchmark.sh --targets /mnt/d1,/mnt/d2 --config NonRAID
#
#   # RAID0 array mounted at /mnt/raid
#   ./run-disk-benchmark.sh --targets /mnt/raid --config RAID0
#
#   # RAID1 array
#   ./run-disk-benchmark.sh --targets /mnt/raid --config RAID1
#
# Setup:
#   1) Install fio and jq:
#        Debian/Ubuntu : sudo apt install fio jq
#        RHEL/Fedora   : sudo dnf install fio jq
#   2) Each --targets entry is either a directory/mount point (a test
#      file is created inside it) or a raw block device such as
#      /dev/nvme1n1 (ALL DATA ON IT IS DESTROYED - use with care).
#   3) Root is not required for O_DIRECT cache bypass, but it is
#      recommended: writing to some mount points, and any use of a
#      raw block device, need root/appropriate permissions.
#
# Notes on utilization:
#   - Sampled once per second while each fio run is in progress.
#   - CPU  : total busy %   from /proc/stat (100 - idle - iowait)
#   - Mem  : used memory %  from /proc/meminfo (MemTotal - MemAvailable)
#   - Disk : target device busy % from /proc/diskstats (field 13,
#            time spent doing I/Os), same method iostat uses for %util
#=====================================================================

set -uo pipefail

# ---- Defaults ------------------------------------------------------
TARGETS=""
CONFIG="NonRAID"
SIZE_GB=8
DURATION=30
FIO_PATH=""
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ITERATIONS=1
IOENGINE="libaio"

usage() {
    cat <<EOF
Usage: $(basename "$0") --targets DIR_OR_DEV[,DIR_OR_DEV...] [options]

Options:
  --targets, -T   LIST      Comma-separated list of mount points / directories
                             / raw block devices to test (required)
  --config,  -c   LABEL     NonRAID | RAID0 | RAID1  (default: NonRAID)
  --size-gb, -s   N         Test file size in GB (default: 8)
  --duration, -d  N         Duration of each test in seconds (default: 30)
  --iterations, -i N        Repeat each test N times (default: 1)
  --fio-path      PATH      Path to fio binary (default: auto-detect on PATH)
  --ioengine      NAME      fio ioengine (default: libaio)
  --outdir, -o    DIR       Output folder for the result CSV (default: script dir)
  -h, --help                Show this help
EOF
}

# ---- Parse args ------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --targets|-T)     TARGETS="$2"; shift 2 ;;
        --config|-c)      CONFIG="$2"; shift 2 ;;
        --size-gb|-s)     SIZE_GB="$2"; shift 2 ;;
        --duration|-d)    DURATION="$2"; shift 2 ;;
        --iterations|-i)  ITERATIONS="$2"; shift 2 ;;
        --fio-path)       FIO_PATH="$2"; shift 2 ;;
        --ioengine)       IOENGINE="$2"; shift 2 ;;
        --outdir|-o)      OUT_DIR="$2"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

if [ -z "$TARGETS" ]; then
    echo "Error: --targets is required." >&2
    usage
    exit 1
fi

case "$CONFIG" in
    NonRAID|RAID0|RAID1) ;;
    *) echo "Error: --config must be one of NonRAID, RAID0, RAID1." >&2; exit 1 ;;
esac

# ---- Root check (warning only) --------------------------------------
IS_ROOT=false
if [ "$(id -u)" -eq 0 ]; then IS_ROOT=true; fi
if [ "$IS_ROOT" = false ]; then
    echo "WARNING: Not running as root. O_DIRECT cache bypass works fine either way," >&2
    echo "         but writing to some mount points, and any raw block device target," >&2
    echo "         may require root. Re-run with sudo if a test fails on permissions." >&2
fi

# ---- Locate fio -------------------------------------------------------
if [ -z "$FIO_PATH" ]; then
    FIO_PATH="$(command -v fio || true)"
fi
if [ -z "$FIO_PATH" ] || [ ! -x "$FIO_PATH" ]; then
    echo "Error: fio not found. Install it (e.g. 'sudo apt install fio') or pass --fio-path." >&2
    exit 1
fi
echo "fio: $FIO_PATH"

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq not found. Install it (e.g. 'sudo apt install jq') to parse fio's JSON output." >&2
    exit 1
fi

# ---- Test matrix (mirrors CrystalDiskMark defaults) -------------------
#   SEQ1M  Q8T1   : sequential large-block throughput
#   RND4K  Q32T16 : random parallel IOPS (OS / apps / DB workloads)
#   RND4K  Q1T1   : responsiveness (QD1 latency)
TEST_NAMES=(SEQ1M-Q8T1-Read SEQ1M-Q8T1-Write RND4K-Q32T16-Read RND4K-Q32T16-Write RND4K-Q1T1-Read RND4K-Q1T1-Write)
TEST_ARGS=(
    "--rw=read      --bs=1M --iodepth=8  --numjobs=1"
    "--rw=write     --bs=1M --iodepth=8  --numjobs=1"
    "--rw=randread  --bs=4k --iodepth=32 --numjobs=16"
    "--rw=randwrite --bs=4k --iodepth=32 --numjobs=16"
    "--rw=randread  --bs=4k --iodepth=1  --numjobs=1"
    "--rw=randwrite --bs=4k --iodepth=1  --numjobs=1"
)
# rw= value that selects which fio JSON section (read/write) to parse
TEST_RWKEY=(read write read write read write)

# Common fio options: --direct=1 bypass page cache, --ramp_time warmup
# (excluded from stats, plays the role of DiskSpd's -W5)
COMMON_ARGS="--direct=1 --ioengine=$IOENGINE --size=${SIZE_GB}G --runtime=$DURATION --ramp_time=5 --time_based=1 --group_reporting=1"

# ---- Resolve a target's own device name for /proc/diskstats -----------
# Mirrors the Windows script's use of the *logical disk* (drive letter /
# partition) counter, not the physical disk: we resolve to the exact
# device the target lives on (partition, mdadm array, or dm/LVM volume),
# canonicalizing symlinks (e.g. /dev/mapper/vg-lv -> /dev/dm-0) so the
# name matches what /proc/diskstats reports.
resolve_disk_dev() {
    local target="$1" src canonical
    if [ -b "$target" ]; then
        src="$target"
    else
        src="$(df --output=source "$target" 2>/dev/null | tail -1)"
        [ -z "$src" ] && { echo ""; return; }
    fi
    canonical="$(readlink -f "$src" 2>/dev/null || echo "$src")"
    basename "$canonical"
}

# ---- Utilization sampling helpers -------------------------------------
cpu_ticks() {
    # total idle from the aggregate "cpu " line in /proc/stat
    awk '/^cpu / { total=0; for(i=2;i<=NF;i++) total+=$i; idle=$5+$6; print total, idle; exit }' /proc/stat
}

mem_used_pct() {
    awk '
        /^MemTotal:/     { total=$2 }
        /^MemAvailable:/ { avail=$2 }
        END { if (total>0) printf "%.1f", (total-avail)*100/total; else print "0" }
    ' /proc/meminfo
}

disk_ticks() {
    local dev="$1"
    [ -z "$dev" ] && { echo 0; return; }
    awk -v d="$dev" '$3==d { print $13; exit }' /proc/diskstats
}

# avg/max over a space-separated list of numbers -> "avg max"
avg_max() {
    local values="$1"
    if [ -z "${values// /}" ]; then echo "0 0"; return; fi
    awk '{ n=0; for(i=1;i<=NF;i++){ s+=$i; n++; if($i>m||n==1) m=$i } } END{ if(n==0){print "0 0"} else printf "%.1f %.1f", s/n, m }' <<< "$values"
}

# ---- Parse fio's JSON output --------------------------------------
# Echoes "mbps iops avglat_ms", or nothing on failure.
parse_fio_json() {
    local json_file="$1" rwkey="$2"
    local bw_bytes iops clat_ns lat_ns bw_kib

    bw_bytes=$(jq -r ".jobs[0].${rwkey}.bw_bytes // empty" "$json_file" 2>/dev/null)
    if [ -z "$bw_bytes" ]; then
        bw_kib=$(jq -r ".jobs[0].${rwkey}.bw // empty" "$json_file" 2>/dev/null)
        [ -n "$bw_kib" ] && bw_bytes=$(awk -v k="$bw_kib" 'BEGIN{printf "%.0f", k*1024}')
    fi
    iops=$(jq -r ".jobs[0].${rwkey}.iops // empty" "$json_file" 2>/dev/null)
    clat_ns=$(jq -r ".jobs[0].${rwkey}.clat_ns.mean // empty" "$json_file" 2>/dev/null)
    if [ -z "$clat_ns" ] || [ "$clat_ns" = "null" ]; then
        lat_ns=$(jq -r ".jobs[0].${rwkey}.lat_ns.mean // empty" "$json_file" 2>/dev/null)
        clat_ns="$lat_ns"
    fi

    if [ -z "$bw_bytes" ] || [ -z "$iops" ] || [ -z "$clat_ns" ]; then
        return 1
    fi

    awk -v b="$bw_bytes" -v i="$iops" -v l="$clat_ns" \
        'BEGIN{ printf "%.2f %.0f %.3f", b/1000000, i, l/1000000 }'
}

# ---- Run one fio test while sampling utilization -----------------
# Echoes: mbps iops avglat_ms cpu_avg cpu_max mem_avg mem_max disk_avg disk_max
run_test() {
    local target="$1" test_name="$2" fio_extra="$3" rwkey="$4" disk_dev="$5" iteration="$6"
    local filename out_json err_file job_name

    if [ -b "$target" ]; then filename="$target"; else filename="${target%/}/fio_testfile.dat"; fi
    out_json="$(mktemp)"
    err_file="$(mktemp)"
    job_name="${test_name}_i${iteration}"

    # shellcheck disable=SC2086
    "$FIO_PATH" --name="$job_name" --filename="$filename" $COMMON_ARGS $fio_extra \
        --output-format=json --output="$out_json" >/dev/null 2>"$err_file" &
    local fio_pid=$!

    local cpu_samples="" mem_samples="" disk_samples=""
    local prev_cpu prev_idle cur_cpu cur_idle
    local prev_dticks cur_dticks prev_ns cur_ns

    read -r prev_cpu prev_idle < <(cpu_ticks)
    prev_dticks=$(disk_ticks "$disk_dev")
    prev_ns=$(date +%s%N)

    while kill -0 "$fio_pid" 2>/dev/null; do
        sleep 1

        read -r cur_cpu cur_idle < <(cpu_ticks)
        local dt=$((cur_cpu - prev_cpu)) di=$((cur_idle - prev_idle)) cpu_pct=0
        if [ "$dt" -gt 0 ]; then cpu_pct=$(awk -v dt="$dt" -v di="$di" 'BEGIN{v=(dt-di)*100/dt; if(v<0)v=0; printf "%.1f", v}'); fi
        cpu_samples+=" $cpu_pct"
        prev_cpu=$cur_cpu; prev_idle=$cur_idle

        mem_samples+=" $(mem_used_pct)"

        cur_dticks=$(disk_ticks "$disk_dev")
        cur_ns=$(date +%s%N)
        local dtick=$((cur_dticks - prev_dticks)) dtime_ms=$(( (cur_ns - prev_ns) / 1000000 )) disk_pct=0
        if [ "$dtime_ms" -gt 0 ]; then disk_pct=$(awk -v a="$dtick" -v b="$dtime_ms" 'BEGIN{v=a*100/b; if(v>100)v=100; if(v<0)v=0; printf "%.1f", v}'); fi
        disk_samples+=" $disk_pct"
        prev_dticks=$cur_dticks; prev_ns=$cur_ns
    done
    wait "$fio_pid" 2>/dev/null

    local parsed
    parsed="$(parse_fio_json "$out_json" "$rwkey")"
    local rc=$?

    # Surface fio's own stderr (permission errors, O_DIRECT alignment, etc.)
    if [ -s "$err_file" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && echo "WARNING: [fio] $line" >&2
        done < "$err_file"
    fi
    rm -f "$out_json" "$err_file"

    if [ $rc -ne 0 ] || [ -z "$parsed" ]; then
        echo "PARSE_FAILED"
        return
    fi

    local cm cx mm mx dm dx
    read -r cm cx <<< "$(avg_max "$cpu_samples")"
    read -r mm mx <<< "$(avg_max "$mem_samples")"
    read -r dm dx <<< "$(avg_max "$disk_samples")"

    echo "$parsed $cm $cx $mm $mx $dm $dx"
}

# ---- Run -------------------------------------------------------------
STAMP="$(date '+%Y-%m-%d %H:%M:%S')"
FILE_STAMP="$(date '+%Y%m%d_%H%M%S')"

mkdir -p "$OUT_DIR"
OUT_CSV="$OUT_DIR/DiskBenchmark_${CONFIG}_${FILE_STAMP}.csv"
echo "Timestamp,Config,Drive,Test,Iteration,MBps,IOPS,AvgLat_ms,CPU_Avg_pct,CPU_Max_pct,Mem_Avg_pct,Mem_Max_pct,Disk_Avg_pct,Disk_Max_pct,IsAdmin,SizeGB,Duration_sec" > "$OUT_CSV"

RESULT_COUNT=0
IFS=',' read -ra TARGET_LIST <<< "$TARGETS"

for target in "${TARGET_LIST[@]}"; do
    if [ ! -e "$target" ]; then
        echo "WARNING: Target '$target' not found. Skipping." >&2
        continue
    fi
    if [ ! -b "$target" ] && [ ! -d "$target" ]; then
        echo "WARNING: Target '$target' is not a directory or block device. Skipping." >&2
        continue
    fi

    disk_dev="$(resolve_disk_dev "$target")"
    echo ""
    echo "===== $CONFIG / Target $target (disk: ${disk_dev:-unknown}) ====="

    for t_idx in "${!TEST_NAMES[@]}"; do
        t_name="${TEST_NAMES[$t_idx]}"
        t_args="${TEST_ARGS[$t_idx]}"
        t_rwkey="${TEST_RWKEY[$t_idx]}"

        for ((i=1; i<=ITERATIONS; i++)); do
            if [ "$ITERATIONS" -gt 1 ]; then label="$t_name #$i"; else label="$t_name"; fi
            printf "  %-24s ... " "$label"

            out="$(run_test "$target" "$t_name" "$t_args" "$t_rwkey" "$disk_dev" "$i")"

            if [ "$out" = "PARSE_FAILED" ] || [ -z "$out" ]; then
                echo "PARSE FAILED"
                continue
            fi

            read -r mbps iops avglat cpu_avg cpu_max mem_avg mem_max disk_avg disk_max <<< "$out"
            printf "%9s MB/s | %10s IOPS | %7s ms  ||  CPU %4s/%4s%%  Mem %4s%%  Disk %4s/%4s%%\n" \
                "$mbps" "$iops" "$avglat" "$cpu_avg" "$cpu_max" "$mem_avg" "$disk_avg" "$disk_max"

            echo "\"$STAMP\",\"$CONFIG\",\"$target\",\"$t_name\",\"$i\",\"$mbps\",\"$iops\",\"$avglat\",\"$cpu_avg\",\"$cpu_max\",\"$mem_avg\",\"$mem_max\",\"$disk_avg\",\"$disk_max\",\"$IS_ROOT\",\"$SIZE_GB\",\"$DURATION\"" >> "$OUT_CSV"
            RESULT_COUNT=$((RESULT_COUNT+1))
        done
    done

    # Remove test file (skip for raw block device targets)
    if [ ! -b "$target" ]; then
        rm -f "${target%/}/fio_testfile.dat"
    fi
done

# ---- Output ------------------------------------------------------
if [ "$RESULT_COUNT" -eq 0 ]; then
    echo "WARNING: No results." >&2
    exit 1
fi

echo ""
echo "---------------- Summary ----------------"
column -s, -t "$OUT_CSV" | cut -c1-160

echo ""
echo "Results written to: $OUT_CSV"
echo "Run each config (NonRAID -> RAID0 -> RAID1); combine the CSVs later into one comparison table."
