$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
. "$scriptDir\Helpers.ps1"

Import-DotEnv "$rootDir\.env"
Require-Env @('SQLSERVER_HOST', 'SQLSERVER_PORT', 'SQLSERVER_DB', 'SQLSERVER_USER', 'SQLSERVER_PASSWORD')

$outRoot = Join-Path $rootDir 'artifacts\sqlserver_objects'
New-Directory $outRoot

$includeSchemas = ($env:INCLUDE_SCHEMAS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$excludeSchemas = ($env:EXCLUDE_SCHEMAS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$schemaFilter = @()
if ($includeSchemas.Count -gt 0) {
    $inList = ($includeSchemas | ForEach-Object { "'$_'" }) -join ','
    $schemaFilter += "AND s.name IN ($inList)"
}
if ($excludeSchemas.Count -gt 0) {
    $notInList = ($excludeSchemas | ForEach-Object { "'$_'" }) -join ','
    $schemaFilter += "AND s.name NOT IN ($notInList)"
}
$schemaFilterSql = ($schemaFilter -join " `n")

$listQuery = @"
SET NOCOUNT ON;
SELECT s.name AS schema_name, o.name AS object_name, o.type AS object_type
FROM sys.objects o
JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0
  AND o.type IN ('V','P','FN','IF','TF','TR')
  $schemaFilterSql
ORDER BY s.name, o.type, o.name;
"@

$rowsRaw = sqlcmd -S "$($env:SQLSERVER_HOST),$($env:SQLSERVER_PORT)" -d $env:SQLSERVER_DB -U $env:SQLSERVER_USER -P $env:SQLSERVER_PASSWORD -h -1 -W -s "|" -Q $listQuery
if (-not $rowsRaw) {
    throw 'No programmable objects found to export.'
}

function Resolve-ObjectFolder {
    param([string]$Type)
    switch ($Type) {
        'V' { return 'views' }
        'P' { return 'procedures' }
        'FN' { return 'functions' }
        'IF' { return 'functions' }
        'TF' { return 'functions' }
        'TR' { return 'triggers' }
        default { return 'others' }
    }
}

$exported = 0
foreach ($line in $rowsRaw) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $parts = $line.Split('|')
    if ($parts.Count -lt 3) { continue }

    $schemaName = $parts[0].Trim()
    $objectName = $parts[1].Trim()
    $objectType = $parts[2].Trim()

    $folder = Resolve-ObjectFolder $objectType
    $folderPath = Join-Path $outRoot $folder
    New-Directory $folderPath

    $definitionQuery = "SET NOCOUNT ON; SELECT OBJECT_DEFINITION(OBJECT_ID(N'[$schemaName].[$objectName]'));"
    $definition = sqlcmd -S "$($env:SQLSERVER_HOST),$($env:SQLSERVER_PORT)" -d $env:SQLSERVER_DB -U $env:SQLSERVER_USER -P $env:SQLSERVER_PASSWORD -y 0 -Y 0 -Q $definitionQuery | Out-String

    if ([string]::IsNullOrWhiteSpace($definition)) {
        Write-Warning "No definition found for [$schemaName].[$objectName]"
        continue
    }

    $safeSchema = $schemaName.Replace(' ', '_')
    $safeObject = $objectName.Replace(' ', '_')
    $path = Join-Path $folderPath "$safeSchema.$safeObject.sql"
    Set-Content -Path $path -Value $definition.Trim() -Encoding UTF8
    $exported++
}

Write-Host "Exported $exported SQL Server programmable objects to $outRoot" -ForegroundColor Green
