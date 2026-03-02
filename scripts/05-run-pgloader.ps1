$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
. "$scriptDir\Helpers.ps1"

Import-DotEnv "$rootDir\.env"
Require-Env @('SQLSERVER_HOST', 'SQLSERVER_PORT', 'SQLSERVER_DB', 'SQLSERVER_USER', 'SQLSERVER_PASSWORD', 'PG_HOST', 'PG_PORT', 'PG_DB', 'PG_USER', 'PG_PASSWORD')

$mssqlHost = Resolve-DockerHost $env:SQLSERVER_HOST
$pgHost = Resolve-DockerHost $env:PG_HOST
$includeDrop = if ($env:RECREATE_TARGET -eq 'true') { 'include drop,' } else { '' }

$mssqlUser = [System.Uri]::EscapeDataString($env:SQLSERVER_USER)
$mssqlPass = [System.Uri]::EscapeDataString($env:SQLSERVER_PASSWORD)
$pgUser = [System.Uri]::EscapeDataString($env:PG_USER)
$pgPass = [System.Uri]::EscapeDataString($env:PG_PASSWORD)

$loadFilePath = Join-Path $rootDir 'config\mssql_to_pg.load'
$loadContent = @"
LOAD DATABASE
     FROM mssql://${mssqlUser}:${mssqlPass}@${mssqlHost}:$($env:SQLSERVER_PORT)/$($env:SQLSERVER_DB)
     INTO postgresql://${pgUser}:${pgPass}@${pgHost}:$($env:PG_PORT)/$($env:PG_DB)

 WITH $includeDrop
      create tables,
      create indexes,
      reset sequences,
      foreign keys,
      workers = 6,
      concurrency = 1,
      prefetch rows = 50000,
      batch rows = 5000,
      on error stop

 CAST type datetime to timestamptz drop default drop not null using zero-dates-to-null,
      type datetime2 to timestamptz drop default,
      type smalldatetime to timestamptz drop default,
      type date to date drop default,
      type time to time drop default,
      type bit to boolean,
     type uniqueidentifier to uuid drop default,
      type money to numeric,
      type smallmoney to numeric,
      type xml to text

 SET work_mem to '64MB', maintenance_work_mem to '512MB';
"@

[System.IO.File]::WriteAllText($loadFilePath, $loadContent, (New-Object System.Text.UTF8Encoding($false)))

$volumePath = $rootDir.Replace('\\', '/')
$containerLoadPath = '/workspace/config/mssql_to_pg.load'

Write-Host "docker run --rm -v ${volumePath}:/workspace dimitri/pgloader:latest pgloader $containerLoadPath" -ForegroundColor Yellow
$previousEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$output = & docker run --rm -v "${volumePath}:/workspace" dimitri/pgloader:latest pgloader $containerLoadPath 2>&1
$exitCode = $LASTEXITCODE
$ErrorActionPreference = $previousEap

$outputText = ($output | ForEach-Object { $_.ToString() }) -join "`n"
if (-not [string]::IsNullOrWhiteSpace($outputText)) {
     Write-Host $outputText
}

if ($exitCode -ne 0 -or ($outputText -match 'FATAL|DB-CONNECTION-ERROR|ERROR Database error')) {
     throw 'pgloader execution failed.'
}

Write-Host 'pgloader migration completed.' -ForegroundColor Green
