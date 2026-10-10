$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  throw 'Install Node.js LTS (22 or newer), then reopen PowerShell.'
}
$nodeMajor = [int]((node --version).TrimStart('v').Split('.')[0])
if ($nodeMajor -lt 22) { throw 'The local worker requires Node.js 22 or newer.' }
if (-not (Test-Path '.env')) {
  Copy-Item '.env.example' '.env'
  throw 'A private .env file was created. Open it in Notepad and enter the real server key, MySQL database name and MySQL password. Then run start.ps1 again.'
}
if (-not (Test-Path 'node_modules')) {
  & npm.cmd ci
  if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' }
}
& node --env-file=.env worker.mjs
exit $LASTEXITCODE
