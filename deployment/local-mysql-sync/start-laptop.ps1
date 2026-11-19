# PyroGuard Supabase -> MySQL sync running on a Windows laptop.
# Run in PowerShell from anywhere: powershell -ExecutionPolicy Bypass -File .\start-laptop.ps1
# Do not commit .env; it contains a privileged Supabase secret.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'Node.js is not installed or not on PATH.' }
foreach ($name in @('.env', 'tables.json', 'package.json')) {
  if (-not (Test-Path (Join-Path $PSScriptRoot $name))) {
    throw "Missing $name in $PSScriptRoot. Keep these existing project files; this ZIP is only a project update, not a full installation."
  }
}
Get-Content -LiteralPath (Join-Path $PSScriptRoot '.env') | ForEach-Object {
  $line = $_.Trim()
  if ($line.Length -eq 0 -or $line.StartsWith('#')) { return }
  $parts = $line -split '=', 2
  if ($parts.Length -ne 2 -or $parts[0] -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw 'Invalid .env entry' }
  [Environment]::SetEnvironmentVariable($parts[0], $parts[1].Trim(), 'Process')
}
if (-not (Test-Path (Join-Path $PSScriptRoot 'node_modules'))) { throw 'Dependencies missing: run npm install from deployment/local-mysql-sync first.' }
Write-Host 'Starting PyroGuard Supabase -> MySQL sync on this laptop. Keep it awake and MySQL running.'
& node (Join-Path $PSScriptRoot 'worker.mjs')
if ($LASTEXITCODE -ne 0) { throw "Sync worker exited with code $LASTEXITCODE" }
