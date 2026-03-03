param(
	[switch]$EnableAiShellEnhancement
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host 'Step 0/2: Reset state (artifacts + target DB)...'
& "$scriptDir\00-reset-state.ps1"

Write-Host 'Step 1/2: Run full migration pipeline (includes deterministic Upsert shell conversion)...'
if ($EnableAiShellEnhancement) {
	Write-Host '         AI shell enhancement is enabled for remaining shell procedures.' -ForegroundColor Yellow
	& "$scriptDir\run-all.ps1" -EnableAiShellEnhancement
} else {
	Write-Host '         AI shell enhancement is disabled (default deterministic mode).' -ForegroundColor Yellow
	& "$scriptDir\run-all.ps1"
}

Write-Host 'Full fresh run completed.' -ForegroundColor Green
