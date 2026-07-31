<#
=====================================================================
 Run-DiskBenchmark.ps1
 ---------------------------------------------------------------------
 Automated SSD performance test (compare Non-RAID / RAID0 / RAID1).
 Engine : Microsoft DiskSpd
 Also samples CPU / Memory / Disk utilization DURING each test.
 Output : on-screen summary + append-only CSV (accumulates all configs)

 Examples:
   # Non-RAID: measure E: and F: individually
   .\Run-DiskBenchmark.ps1 -Drives E,F -Config NonRAID

   # RAID0 array mounted as R:
   .\Run-DiskBenchmark.ps1 -Drives R -Config RAID0

   # RAID1 array
   .\Run-DiskBenchmark.ps1 -Drives R -Config RAID1

 Setup:
   1) Get DiskSpd from https://github.com/microsoft/diskspd/releases
      Unzip and either put amd64\diskspd.exe next to this script,
      or pass its path with -DiskSpdPath.
   2) Run PowerShell "as Administrator" (needed for cache bypass).
      If blocked by execution policy:
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

 Notes on utilization:
   - Sampled once per second while each diskspd run is in progress.
   - CPU  : total processor busy %  (Win32_PerfFormattedData_PerfOS_Processor)
   - Mem  : used physical memory %  (from Win32_OperatingSystem)
   - Disk : target drive busy %     (100 - % Idle Time of that logical disk)
   - CIM classes are used (language-neutral) so it works on localized Windows.

 Notes on DiskSpd warnings:
   - DiskSpd writes its own warnings (e.g. the SeManageVolumePrivilege /
     "valid file size" messages seen when NOT running as Administrator) to
     STDERR. This script now surfaces those lines so they are visible even
     though diskspd's output is captured to a temp file.
=====================================================================
#>

[CmdletBinding()]
param(
    # Target drive letters (one or more). Non-RAID: pass both, e.g. E,F
    [string[]] $Drives = @('E','F'),

    # Config label, recorded in the CSV and summary (the comparison axis).
    [ValidateSet('NonRAID','RAID0','RAID1')]
    [string]   $Config = 'NonRAID',

    # Test file size (GB). Use 8+ to exceed the SSD cache.
    [int]      $SizeGB = 8,

    # Duration of each test in seconds.
    [int]      $Duration = 30,

    # Path to diskspd.exe (auto-detected next to this script / on PATH if empty).
    [string]   $DiskSpdPath,

    # Folder for result files (default: same folder as this script).
    # A new timestamped CSV is written for every run.
    [string]   $OutDir = $PSScriptRoot,

    # Repeat each test this many times to gauge run-to-run variance.
    # Every iteration is recorded (Iteration column) so you can see the spread.
    [int]      $Iterations = 1
)

# ---- Admin check (warning only) ----------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning 'Not running as Administrator. Elevation is recommended mainly because writing the test file to a drive root (e.g. C:\) fails without it. NOTE: DiskSpd -Sh (unbuffered + write-through) does NOT require admin, so cache bypass applies either way; elevation is about permissions/consistency, not making results look faster.'
    Write-Warning 'Because this is a non-elevated session, DiskSpd cannot acquire SeManageVolumePrivilege and will emit its own warnings (error code 1300) while preparing the test file. Those messages are shown per-test below; they affect only file-prep time, not the measured numbers.'
}

# ---- Locate diskspd.exe ------------------------------------------
if (-not $DiskSpdPath) {
    $candidates = @(
        (Join-Path $PSScriptRoot 'diskspd.exe'),
        (Join-Path $PSScriptRoot 'amd64\diskspd.exe'),
        'diskspd.exe'
    )
    foreach ($c in $candidates) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { $DiskSpdPath = $cmd.Source; break }
    }
}
if (-not $DiskSpdPath -or -not (Test-Path $DiskSpdPath)) {
    Write-Error "diskspd.exe not found. Download it from https://github.com/microsoft/diskspd/releases and pass -DiskSpdPath or place it next to this script."
    return
}
Write-Host "DiskSpd: $DiskSpdPath" -ForegroundColor DarkGray

# ---- Test matrix (mirrors CrystalDiskMark defaults) --------------
#   SEQ1M  Q8T1   : sequential large-block throughput
#   RND4K  Q32T16 : random parallel IOPS (OS / apps / DB workloads)
#   RND4K  Q1T1   : responsiveness (QD1 latency)
$tests = @(
    @{ Name='SEQ1M-Q8T1-Read';    Args='-b1M -o8  -t1  -w0'      }
    @{ Name='SEQ1M-Q8T1-Write';   Args='-b1M -o8  -t1  -w100'    }
    @{ Name='RND4K-Q32T16-Read';  Args='-b4K -o32 -t16 -w0   -r' }
    @{ Name='RND4K-Q32T16-Write'; Args='-b4K -o32 -t16 -w100 -r' }
    @{ Name='RND4K-Q1T1-Read';    Args='-b4K -o1  -t1  -w0   -r' }
    @{ Name='RND4K-Q1T1-Write';   Args='-b4K -o1  -t1  -w100 -r' }
)

# Common options: -Sh disable caching, -L latency, -W5 warmup, -C1 cooldown
$commonArgs = @("-c${SizeGB}G", "-d$Duration", "-W5", "-C1", "-Sh", "-L")

# ---- Parse the "Total IO" total: line from DiskSpd text output ----
function Parse-DiskSpd([string]$text) {
    $sections = $text -split 'Total IO'
    if ($sections.Count -lt 2) { return $null }
    $line = ($sections[1] -split "`n" | Where-Object { $_ -match '^\s*total:' } | Select-Object -First 1)
    if (-not $line) { return $null }
    # Fields split by "|": [0]=total:+bytes [1]=I/Os [2]=MiB/s [3]=IOPS [4]=AvgLat(ms)
    $p = $line -split '\|'
    if ($p.Count -lt 5) { return $null }
    $mibps = [double]($p[2].Trim())
    return [pscustomobject]@{
        MBps   = [math]::Round($mibps * 1.048576, 2)   # MiB/s -> MB/s (decimal, CDM-compatible)
        IOPS   = [math]::Round([double]($p[3].Trim()), 0)
        AvgLat = [double]($p[4].Trim())                # milliseconds
    }
}

# ---- Extract DiskSpd's own WARNING lines from stdout + stderr -----
# DiskSpd normally writes these to stderr, but scan both streams to be safe.
function Get-DiskSpdWarnings([string]$stdout, [string]$stderr) {
    $warnings = @()
    foreach ($stream in @($stdout, $stderr)) {
        if ($stream) {
            $warnings += ($stream -split "`r?`n" |
                Where-Object { $_ -match 'WARNING\s*:' } |
                ForEach-Object { $_.Trim() })
        }
    }
    return ($warnings | Select-Object -Unique)
}

# ---- Avg/Max helper ----------------------------------------------
function Stat($arr) {
    if (-not $arr -or $arr.Count -eq 0) { return @{ Avg = $null; Max = $null } }
    return @{
        Avg = [math]::Round((($arr | Measure-Object -Average).Average), 1)
        Max = [math]::Round((($arr | Measure-Object -Maximum).Maximum), 1)
    }
}

# ---- Run diskspd in background while sampling utilization ---------
function Invoke-TestWithUtil([string[]]$dsArgs, [string]$driveLetter) {
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    $proc = Start-Process -FilePath $DiskSpdPath -ArgumentList $dsArgs -NoNewWindow -PassThru `
                          -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr

    $cpu = @(); $mem = @(); $dsk = @()
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 1000
        try {
            $c = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor `
                    -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $m  = (($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100
            $di = Get-CimInstance Win32_PerfFormattedData_PerfDisk_LogicalDisk `
                    -Filter "Name='$($driveLetter):'" -ErrorAction Stop
            $dbusy = 100 - [double]$di.PercentIdleTime
            if ($dbusy -lt 0) { $dbusy = 0 }
            $cpu += [double]$c
            $mem += [double]$m
            $dsk += $dbusy
        } catch { }
    }
    $proc.WaitForExit()

    # Read BOTH streams. stderr carries DiskSpd's own warnings (e.g. the
    # SeManageVolumePrivilege / "valid file size" messages when non-admin).
    $out = Get-Content $tmpOut -Raw -ErrorAction SilentlyContinue
    $err = Get-Content $tmpErr -Raw -ErrorAction SilentlyContinue
    Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        Output = $out
        Err    = $err
        Cpu    = (Stat $cpu)
        Mem    = (Stat $mem)
        Disk   = (Stat $dsk)
    }
}

# ---- Run ---------------------------------------------------------
$now       = Get-Date
$stamp     = $now.ToString('yyyy-MM-dd HH:mm:ss')   # value stored in the CSV
$fileStamp = $now.ToString('yyyyMMdd_HHmmss')       # file-name-safe timestamp
$results   = @()

foreach ($d in $Drives) {
    $drive  = $d.TrimEnd(':').ToUpper()
    $target = "${drive}:\diskspd_testfile.dat"
    if (-not (Test-Path "${drive}:\")) {
        Write-Warning "Drive ${drive}: not found. Skipping."
        continue
    }

    Write-Host "`n===== $Config / Drive ${drive}: =====" -ForegroundColor Cyan
    foreach ($t in $tests) {
        for ($i = 1; $i -le $Iterations; $i++) {
            $label = if ($Iterations -gt 1) { "{0} #{1}" -f $t.Name, $i } else { $t.Name }
            Write-Host ("  {0,-24} ... " -f $label) -NoNewline

            $argsList  = @()
            $argsList += $commonArgs
            $argsList += ($t.Args -split '\s+' | Where-Object { $_ })
            $argsList += $target

            $run = Invoke-TestWithUtil -dsArgs $argsList -driveLetter $drive
            $r   = Parse-DiskSpd $run.Output

            if ($r) {
                Write-Host ("{0,9:N1} MB/s | {1,10:N0} IOPS | {2,7:N3} ms  ||  CPU {3,4:N0}/{4,4:N0}%  Mem {5,4:N0}%  Disk {6,4:N0}/{7,4:N0}%" -f `
                    $r.MBps, $r.IOPS, $r.AvgLat, `
                    $run.Cpu.Avg, $run.Cpu.Max, $run.Mem.Avg, $run.Disk.Avg, $run.Disk.Max) -ForegroundColor Green
                $results += [pscustomobject]@{
                    Timestamp   = $stamp
                    Config      = $Config
                    Drive       = $drive
                    Test        = $t.Name
                    Iteration   = $i
                    MBps        = $r.MBps
                    IOPS        = $r.IOPS
                    AvgLat_ms   = $r.AvgLat
                    CPU_Avg_pct = $run.Cpu.Avg
                    CPU_Max_pct = $run.Cpu.Max
                    Mem_Avg_pct = $run.Mem.Avg
                    Mem_Max_pct = $run.Mem.Max
                    Disk_Avg_pct= $run.Disk.Avg
                    Disk_Max_pct= $run.Disk.Max
                    IsAdmin     = $isAdmin
                    SizeGB      = $SizeGB
                    Duration_sec= $Duration
                }
            } else {
                Write-Host 'PARSE FAILED' -ForegroundColor Red
                Write-Verbose $run.Output
            }

            # ---- Surface DiskSpd's own warnings (e.g. SeManageVolumePrivilege
            #      / error code 1300 seen when NOT elevated). These come from
            #      stderr, which the script previously discarded. -------------
            $dsWarnings = Get-DiskSpdWarnings $run.Output $run.Err
            foreach ($w in $dsWarnings) {
                # Strip DiskSpd's leading "WARNING:" so Write-Warning doesn't double it.
                Write-Warning ("[DiskSpd] " + ($w -replace '^\s*WARNING\s*:\s*',''))
            }
        }
    }

    # Remove test file
    if (Test-Path $target) { Remove-Item $target -Force -ErrorAction SilentlyContinue }
}

# ---- Output ------------------------------------------------------
if ($results.Count -eq 0) { Write-Warning 'No results.'; return }

Write-Host "`n---------------- Summary ----------------" -ForegroundColor Yellow
$results | Format-Table Config,Drive,Test,MBps,IOPS,AvgLat_ms,CPU_Avg_pct,Mem_Avg_pct,Disk_Avg_pct -AutoSize

# Write a fresh, timestamped CSV for this run into the output folder.
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutCsv = Join-Path $OutDir ("DiskBenchmark_{0}_{1}.csv" -f $Config, $fileStamp)
$results | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8
Write-Host "`nResults written to: $OutCsv" -ForegroundColor Green
Write-Host "Run each config (NonRAID -> RAID0 -> RAID1); combine the CSVs later into one comparison table." -ForegroundColor DarkGray
