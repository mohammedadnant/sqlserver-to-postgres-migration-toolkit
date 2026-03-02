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

Write-Host 'Clearing artifacts folder...' -ForegroundColor Yellow
if (Test-Path "$rootDir\artifacts") {
    Remove-Item -Path "$rootDir\artifacts\*" -Recurse -Force -ErrorAction SilentlyContinue
}

New-Directory "$rootDir\artifacts\sqlserver_objects\tables"
New-Directory "$rootDir\artifacts\sqlserver_objects\views"
New-Directory "$rootDir\artifacts\sqlserver_objects\functions"
New-Directory "$rootDir\artifacts\sqlserver_objects\procedures"
New-Directory "$rootDir\artifacts\sqlserver_objects\triggers"
New-Directory "$rootDir\artifacts\converted_objects\views"
New-Directory "$rootDir\artifacts\converted_objects\functions"
New-Directory "$rootDir\artifacts\converted_objects\procedures"
New-Directory "$rootDir\artifacts\converted_objects\triggers"

$dbNameLiteral = $env:PG_DB.Replace("'", "''")
$dbNameIdent = $env:PG_DB.Replace('"', '""')

$terminateQuery = @"
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE lower(datname) = lower('$dbNameLiteral')
    AND pid <> pg_backend_pid();
"@

$dropQuery = "DROP DATABASE IF EXISTS `"$dbNameIdent`";"
$createQuery = "CREATE DATABASE `"$dbNameIdent`";"

Write-Host "Resetting PostgreSQL database '$($env:PG_DB)'..." -ForegroundColor Yellow
Invoke-PsqlCommand -WorkspaceRoot $rootDir -Arguments @(
    '-h', $pgHost,
    '-p', $env:PG_PORT,
    '-U', $env:PG_USER,
    '-d', $adminDb,
    '-v', 'ON_ERROR_STOP=1',
    '-c', $terminateQuery
)

Invoke-PsqlCommand -WorkspaceRoot $rootDir -Arguments @(
    '-h', $pgHost,
    '-p', $env:PG_PORT,
    '-U', $env:PG_USER,
    '-d', $adminDb,
    '-v', 'ON_ERROR_STOP=1',
    '-c', $dropQuery
)

Invoke-PsqlCommand -WorkspaceRoot $rootDir -Arguments @(
    '-h', $pgHost,
    '-p', $env:PG_PORT,
    '-U', $env:PG_USER,
    '-d', $adminDb,
    '-v', 'ON_ERROR_STOP=1',
    '-c', $createQuery
)

if ($LASTEXITCODE -ne 0) {
    throw "Failed to reset PostgreSQL database '$($env:PG_DB)'. Ensure PG user has drop/create privileges."
}

Write-Host 'Reset state completed (artifacts + target DB).' -ForegroundColor Green
