$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host 'Step 0/2: Reset state (artifacts + target DB)...'
& "$scriptDir\00-reset-state.ps1"

Write-Host 'Step 1/2: Run full migration pipeline...'
& "$scriptDir\run-all.ps1"

Write-Host 'Full fresh run completed.' -ForegroundColor Green
