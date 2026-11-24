# =============================================================================
# PyroGuard - secure camera link for the website (Vercel)
#
# The Vercel site is HTTPS, so the browser blocks the camera's http:// video.
# This script runs on a PC that is on the Pyroguard_Team Wi-Fi and opens two
# free Cloudflare quick tunnels:
#     https://<random>.trycloudflare.com  ->  http://<camera>:80   (photos, motion)
#     https://<random>.trycloudflare.com  ->  http://<camera>:81   (live video)
# It saves both addresses to Supabase (pyroguard_camera_tunnel); the website
# picks them up within a second and plays the live video.
#
# Run:  double-click start-camera-tunnel.bat   (keep the window open)
# Stop: close the window or press Ctrl+C.
# Needs: deployment\local-mysql-sync\.env with SUPABASE_URL and
#        SUPABASE_SERVER_KEY (the same file the MySQL sync worker uses).
# =============================================================================
param([string]$CameraIp = "")

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cameraId = "pyroguard_camera_001"

# ---- Supabase settings from the sync worker's .env -------------------------
$envFile = Join-Path $here "..\local-mysql-sync\.env"
if (-not (Test-Path $envFile)) { throw "Missing $envFile (copy .env.example and fill it in)." }
$cfg = @{}
Get-Content $envFile | ForEach-Object {
  if ($_ -match '^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$') { $cfg[$matches[1]] = $matches[2].Trim('"').Trim("'") }
}
$sbUrl = $cfg["SUPABASE_URL"]
$sbKey = if ($cfg["SUPABASE_SERVER_KEY"]) { $cfg["SUPABASE_SERVER_KEY"] } else { $cfg["SUPABASE_SERVICE_ROLE_KEY"] }
if (-not $sbUrl -or -not $sbKey) { throw "SUPABASE_URL / SUPABASE_SERVER_KEY not found in $envFile." }
$headers = @{ apikey = $sbKey; Authorization = "Bearer $sbKey"; "Content-Type" = "application/json" }

# ---- Camera address: argument, else the one Camera 1 last reported ---------
if (-not $CameraIp) {
  try {
    $t = Invoke-RestMethod -Headers $headers -Uri "$sbUrl/rest/v1/pyroguard_camera_telemetry?select=camera_ip&camera_device_id=eq.$cameraId&limit=1"
    if ($t -and $t[0].camera_ip) { $CameraIp = $t[0].camera_ip }
  } catch {}
}
if (-not $CameraIp) { $CameraIp = "192.168.8.99" }
Write-Host "Camera 1 address: $CameraIp" -ForegroundColor Cyan
try {
  $null = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Uri "http://$CameraIp/status"
  Write-Host "Camera 1 answers on the Wi-Fi." -ForegroundColor Green
} catch {
  Write-Host "WARNING: Camera 1 did not answer at http://$CameraIp. Is this PC on Pyroguard_Team?" -ForegroundColor Yellow
}

# ---- cloudflared (downloaded once next to this script) ---------------------
$cf = (Get-Command cloudflared -ErrorAction SilentlyContinue).Source
if (-not $cf) {
  $cf = Join-Path $here "cloudflared.exe"
  if (-not (Test-Path $cf)) {
    Write-Host "Downloading cloudflared (one time, about 60 MB)..." -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -OutFile $cf `
      -Uri "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
  }
}

function Start-Tunnel([int]$port) {
  $log = Join-Path $env:TEMP "pyroguard-tunnel-$port.log"
  Remove-Item $log -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath $cf -PassThru -WindowStyle Hidden `
    -ArgumentList @("tunnel", "--no-autoupdate", "--url", "http://${CameraIp}:$port", "--logfile", $log)
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 1
    if (Test-Path $log) {
      $m = Select-String -Path $log -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' | Select-Object -First 1
      if ($m) { return @{ Proc = $p; Url = $m.Matches[0].Value } }
    }
    if ($p.HasExited) { break }
  }
  throw "Tunnel for port $port did not start. See $log"
}

function Save-Urls($httpUrl, $streamUrl) {
  $body = @{ camera_device_id = $cameraId; http_url = $httpUrl; stream_url = $streamUrl;
             updated_at = (Get-Date).ToUniversalTime().ToString("o") } | ConvertTo-Json
  $h = $headers.Clone(); $h["Prefer"] = "resolution=merge-duplicates"
  Invoke-RestMethod -Method Post -Headers $h -Body $body `
    -Uri "$sbUrl/rest/v1/pyroguard_camera_tunnel?on_conflict=camera_device_id" | Out-Null
}

$t80 = $null; $t81 = $null
try {
  Write-Host "Opening the secure links..." -ForegroundColor Cyan
  $t80 = Start-Tunnel 80
  $t81 = Start-Tunnel 81
  Save-Urls $t80.Url $t81.Url
  Write-Host ""
  Write-Host "READY. The website now shows Camera 1 live." -ForegroundColor Green
  Write-Host "  Photos/motion: $($t80.Url)"
  Write-Host "  Live video:    $($t81.Url)/stream"
  Write-Host "Keep this window open during the demo. Close it to stop."
  while ($true) {
    Start-Sleep -Seconds 30
    if ($t80.Proc.HasExited) { $t80 = Start-Tunnel 80; Write-Host "Restarted photo link: $($t80.Url)" }
    if ($t81.Proc.HasExited) { $t81 = Start-Tunnel 81; Write-Host "Restarted video link: $($t81.Url)" }
    try { Save-Urls $t80.Url $t81.Url } catch { Write-Host "Could not refresh Supabase: $_" -ForegroundColor Yellow }
  }
} finally {
  foreach ($t in @($t80, $t81)) { if ($t -and -not $t.Proc.HasExited) { Stop-Process -Id $t.Proc.Id -Force } }
  try { Save-Urls $null $null; Write-Host "Secure links closed." } catch {}
}
