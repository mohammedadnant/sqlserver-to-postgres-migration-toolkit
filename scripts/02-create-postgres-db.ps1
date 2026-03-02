$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
. "$scriptDir\Helpers.ps1"

Import-DotEnv "$rootDir\.env"
Require-Env @('PG_HOST', 'PG_PORT', 'PG_DB', 'PG_USER', 'PG_PASSWORD')

$env:PGPASSWORD = $env:PG_PASSWORD
$useLocalPsql = [bool](Get-Command psql -ErrorAction SilentlyContinue)
$pgHost = if ($useLocalPsql) { $env:PG_HOST } else { Resolve-DockerHost $env:PG_HOST }
$adminDb = if ([string]::IsNullOrWhiteSpace($env:PG_ADMIN_DB)) { 'postgres' } else { $env:PG_ADMIN_DB }

$escapedDbForSql = $env:PG_DB.Replace("'", "''")
$escapedDbForIdentifier = $env:PG_DB.Replace('"', '""')

$existsOutput = Invoke-PsqlCommand -WorkspaceRoot $rootDir -Arguments @(
    '-h', $pgHost,
    '-p', $env:PG_PORT,
    '-U', $env:PG_USER,
    '-d', $adminDb,
    '-v', 'ON_ERROR_STOP=1',
    '-t',
    '-A',
    '-c', "SELECT 1 FROM pg_database WHERE lower(datname) = lower('$escapedDbForSql') LIMIT 1;"
)

if ($LASTEXITCODE -ne 0) {
    throw "Failed ensuring PostgreSQL database '$($env:PG_DB)'."
}

$dbExists = (($existsOutput | Out-String).Trim() -eq '1')
if (-not $dbExists) {
    Invoke-PsqlCommand -WorkspaceRoot $rootDir -Arguments @(
        '-h', $pgHost,
        '-p', $env:PG_PORT,
        '-U', $env:PG_USER,
        '-d', $adminDb,
        '-v', 'ON_ERROR_STOP=1',
        '-c', ('CREATE DATABASE "' + $escapedDbForIdentifier + '";')
    )

    if ($LASTEXITCODE -ne 0) {
        throw "Failed creating PostgreSQL database '$($env:PG_DB)'."
    }
}

Write-Host "PostgreSQL database '$($env:PG_DB)' is ready." -ForegroundColor Green
