$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\Helpers.ps1"

function Assert-Command {
    param([string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

Assert-Command docker
Assert-Command sqlcmd

if (Get-Command psql -ErrorAction SilentlyContinue) {
    Write-Host 'Found local psql client.' -ForegroundColor Green
} else {
    Write-Host 'Local psql not found; Dockerized psql fallback will be used.' -ForegroundColor Yellow
}

Write-Host 'Prerequisite check passed: docker and sqlcmd found.' -ForegroundColor Green
