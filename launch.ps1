<#
.SYNOPSIS
    Launch px4-gazebo-headless:multi with auto-split Windows Terminal panes.

.DESCRIPTION
    Opens a new Windows Terminal window with:
      - Top pane   : combined [drone-N]-prefixed output via 'docker logs -f'
      - Bottom row : one pane per drone, each tailing its own log file

    The container runs detached (-d) so all panes read clean line-buffered
    streams instead of racing over a shared TTY (which causes flickering).

    Requires: Windows Terminal (pre-installed on Windows 11), Docker Desktop.

.PARAMETER N
    Number of vehicles to spawn (default: 1)

.PARAMETER IP
    Host IP for MAVLink API output on UDP 14540+i (required)

.PARAMETER IPQGC
    Separate QGC host IP for UDP 14550+i (defaults to same as IP)

.PARAMETER Vehicle
    PX4 vehicle model (default: gz_x500)

.PARAMETER Spacing
    Metres between drones along the Y axis (default: 2)

.PARAMETER World
    Gazebo world name (default: default). Ignored if -WorldFile is supplied.

.PARAMETER WorldFile
    Path to a custom .sdf world file on the host. Mounts it into the container
    and sets the world name from the filename automatically.

.PARAMETER Image
    Docker image to use (default: px4-gazebo-headless:multi)

.PARAMETER ContainerName
    Docker container name (default: px4sim)

.EXAMPLE
    .\launch.ps1 -IP 192.168.1.31
    .\launch.ps1 -N 3 -IP 192.168.1.31
    .\launch.ps1 -N 3 -IP 192.168.1.31 -Spacing 5
    .\launch.ps1 -N 2 -IP 192.168.1.31 -IPQGC 192.168.1.50
#>

param(
    [int]    $N             = 1,
    [Parameter(Mandatory=$true)]
    [string] $IP,
    [string] $IPQGC         = "",
    [string] $Vehicle       = "gz_x500",
    [string] $World         = "default",
    [string] $WorldFile     = "",
    [int]    $Spacing       = 2,
    [string] $Image         = "px4-gazebo-headless:multi",
    [string] $ContainerName = "px4sim"
)

# ── Pre-flight checks ────────────────────────────────────────────────────────

if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
    Write-Error "Windows Terminal (wt.exe) not found. Install it from the Microsoft Store."
    exit 1
}
if (-not (docker info 2>$null)) {
    Write-Error "Docker is not running. Start Docker Desktop first."
    exit 1
}

# ── Stop and remove any leftover container ───────────────────────────────────

docker rm -f $ContainerName 2>$null | Out-Null

# ── Resolve world name and optional volume mount ──────────────────────────────

$volumeMount = ""
if ($WorldFile -ne "") {
    $resolvedFile = Resolve-Path $WorldFile -ErrorAction Stop
    $worldName    = [System.IO.Path]::GetFileNameWithoutExtension($resolvedFile)
    $World        = $worldName
    $containerPath = "/root/px4/Tools/simulation/gz/worlds/${worldName}.sdf"
    $volumeMount  = "--volume `"${resolvedFile}:${containerPath}`""
}

# ── Build the docker run command (detached — no -it) ─────────────────────────
# Running detached means Docker buffers output line-by-line, so 'docker logs -f'
# shows clean complete lines instead of characters racing from multiple processes.

$ipArgs = if ($IPQGC -ne "") { "$IPQGC $IP" } else { $IP }
$dockerRunArgs = "run --rm -d --name $ContainerName $volumeMount $Image -n $N -s $Spacing -v $Vehicle -w $World $ipArgs"

# ── Write temp .bat files ─────────────────────────────────────────────────────
# cmd /k inline strings don't support 'goto', so each pane gets a real .bat file.

$tempDir = $env:TEMP

# Main pane: start the container, then stream combined output via docker logs -f.
$mainBat = Join-Path $tempDir "px4_main_${ContainerName}.bat"
@"
@echo off
title px4sim [main]
echo Starting container: $Image  (-n $N  $ipArgs)
echo.
docker $dockerRunArgs
if errorlevel 1 (
    echo.
    echo ERROR: Failed to start container.
    echo   - Is Docker Desktop running?
    echo   - Does the image exist?  Run: docker images $Image
    echo.
    pause
    exit /b 1
)
echo Container started.  Streaming combined output  [Ctrl+C detaches log]
echo To stop the simulation:  docker stop $ContainerName
echo.
docker logs -f $ContainerName
echo.
echo Container stopped.
"@ | Set-Content -Path $mainBat -Encoding ASCII

# Drone panes: wait until the log FILE exists inside the container, then tail it.
# We check for the file (not just the container) because PX4 takes a few seconds
# to start writing — the container can be "running" before the file appears.
$droneBats = @()
for ($i = 0; $i -lt $N; $i++) {
    $bat = Join-Path $tempDir "px4_drone_${ContainerName}_${i}.bat"
    $logFile = "/tmp/px4_instance_${i}.log"
    @"
@echo off
title drone-$i
echo [drone-$i] Waiting for PX4 instance $i to create its log file...
:wait
docker exec $ContainerName test -f $logFile 2>nul 1>nul
if errorlevel 1 (
    timeout /t 2 /nobreak >nul
    goto wait
)
echo [drone-$i] Log ready.  Press Ctrl+C to stop following.
echo.
docker exec $ContainerName tail -f $logFile
"@ | Set-Content -Path $bat -Encoding ASCII
    $droneBats += $bat
}

# ── Build wt argument list ────────────────────────────────────────────────────
# Layout for N=3:
#
#   ┌─────────────────────────────────────────┐
#   │  main pane  (docker logs -f)            │  ~65 %
#   ├─────────────┬─────────────┬─────────────┤
#   │  drone-0    │  drone-1    │  drone-2    │  ~35 %
#   └─────────────┴─────────────┴─────────────┘
#
# -H splits with a horizontal divider → new pane appears below
# -V splits with a vertical divider   → new pane appears to the right

$wtArgs = @(
    "new-tab", "--title", "px4sim", "cmd", "/k", $mainBat
)

for ($i = 0; $i -lt $N; $i++) {
    if ($i -eq 0) {
        # First drone pane: open below the main pane, taking 35% of the height
        $wtArgs += @(";", "split-pane", "-H", "--size", "0.35", "--title", "drone-0", "cmd", "/k", $droneBats[0])
    } else {
        # Additional drone panes: open to the right of the previous drone pane
        $wtArgs += @(";", "split-pane", "-V", "--title", "drone-$i", "cmd", "/k", $droneBats[$i])
    }
}

# ── Launch ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Launching $N drone(s)"
Write-Host "  Image    : $Image"
Write-Host "  API host : $IP  (UDP 14540 .. 14$( 540 + $N - 1 ))"
if ($IPQGC -ne "") {
    Write-Host "  QGC host : $IPQGC  (UDP 14550 .. 14$( 550 + $N - 1 ))"
}
Write-Host ""
Write-Host "Windows Terminal opening.  Drone panes wait for each log file before attaching."
Write-Host ""
Write-Host "  To stop:   .\stop.ps1   (or: docker stop $ContainerName)"
Write-Host "  To check:  docker ps"
Write-Host ""

Start-Process wt -ArgumentList $wtArgs
