# Capture a perfetto trace from the connected MovinkPad while the user
# reproduces a flash. Drop the resulting .perfetto-trace into
# https://ui.perfetto.dev to inspect — look for the DrawingApp.* slices
# under the app's process row, and correlate with SurfaceFlinger's
# composition and vsync events on the system rows.
#
# Pre-req: app installed and launched on a connected device.
#
# Run from the repo root:
#     .\tools\capture-trace.ps1
#
# Reproduce the flash during the 10-second capture window. The script
# pulls the trace into the current directory when done.

$ErrorActionPreference = "Stop"

$cfg     = "tools/perfetto-config.pbtxt"
$ts      = Get-Date -Format "yyyyMMdd-HHmmss"
$outName = "drawing-$ts.perfetto-trace"
# /data/misc/perfetto-traces/ is the only directory the perfetto
# daemon's SELinux domain can write to. adb pull can read out of it.
$devOut  = "/data/misc/perfetto-traces/$outName"

if (-not (Test-Path $cfg)) {
    Write-Error "config not found: $cfg (run from repo root?)"
    exit 1
}

Write-Host "`nStarting 10s perfetto capture."
Write-Host "→ Reproduce a flash now (fast handwriting, t/i letters work well).`n"

# Pipe the config to perfetto over stdin rather than via a file on
# /data/local/tmp/ — the perfetto daemon's SELinux domain can't read
# files in that directory directly, even when they're world-readable.
# Using `-c -` makes perfetto consume config from stdin, sidestepping
# the file-permission issue entirely.
Get-Content -Raw $cfg | adb shell "perfetto --txt -c - -o $devOut"
if ($LASTEXITCODE -ne 0) {
    Write-Error "perfetto exited with code $LASTEXITCODE"
    exit $LASTEXITCODE
}

Write-Host "`nPulling trace..."
adb pull $devOut $outName | Out-Null
adb shell rm $devOut | Out-Null

$size = (Get-Item $outName).Length
$sizeMb = [Math]::Round($size / 1MB, 2)
Write-Host "`nSaved $outName ($sizeMb MB)."
Write-Host "Open at https://ui.perfetto.dev"
