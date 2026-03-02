$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
. "$scriptDir\Helpers.ps1"

Import-DotEnv "$rootDir\.env"
Require-Env @('SQLSERVER_HOST', 'SQLSERVER_PORT', 'SQLSERVER_DB', 'SQLSERVER_USER', 'SQLSERVER_PASSWORD')

$outRoot = Join-Path $rootDir 'artifacts\sqlserver_objects\tables'
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
SELECT s.name AS schema_name, t.name AS table_name
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  $schemaFilterSql
ORDER BY s.name, t.name;
"@

$tablesRaw = sqlcmd -S "$($env:SQLSERVER_HOST),$($env:SQLSERVER_PORT)" -d $env:SQLSERVER_DB -U $env:SQLSERVER_USER -P $env:SQLSERVER_PASSWORD -h -1 -W -s "|" -Q $listQuery
if (-not $tablesRaw) {
    throw 'No tables found to export.'
}

$exported = 0
foreach ($line in $tablesRaw) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $parts = $line.Split('|')
    if ($parts.Count -lt 2) { continue }

    $schemaName = $parts[0].Trim()
    $tableName = $parts[1].Trim()

    if ([string]::IsNullOrWhiteSpace($schemaName) -or [string]::IsNullOrWhiteSpace($tableName)) {
        continue
    }

    $ddlQuery = @"
SET NOCOUNT ON;
DECLARE @schema sysname = N'$schemaName';
DECLARE @table sysname = N'$tableName';
DECLARE @objId int = OBJECT_ID(QUOTENAME(@schema) + '.' + QUOTENAME(@table));
DECLARE @cols nvarchar(max);
DECLARE @pk nvarchar(max) = N'';

SELECT @cols = STUFF((
    SELECT CHAR(10) + '    [' + c.name + '] '
        + CASE
            WHEN t.name IN ('varchar','char','binary','varbinary')
                THEN t.name + '(' + CASE WHEN c.max_length = -1 THEN 'MAX' ELSE CAST(c.max_length AS varchar(10)) END + ')'
            WHEN t.name IN ('nvarchar','nchar')
                THEN t.name + '(' + CASE WHEN c.max_length = -1 THEN 'MAX' ELSE CAST(c.max_length / 2 AS varchar(10)) END + ')'
            WHEN t.name IN ('decimal','numeric')
                THEN t.name + '(' + CAST(c.precision AS varchar(10)) + ',' + CAST(c.scale AS varchar(10)) + ')'
            WHEN t.name IN ('datetime2','datetimeoffset','time')
                THEN t.name + '(' + CAST(c.scale AS varchar(10)) + ')'
            ELSE t.name
          END
        + CASE
            WHEN c.is_identity = 1
                THEN ' IDENTITY(' + CAST(CONVERT(bigint, ISNULL(ic.seed_value, 1)) AS varchar(30)) + ',' + CAST(CONVERT(bigint, ISNULL(ic.increment_value, 1)) AS varchar(30)) + ')'
            ELSE ''
          END
        + CASE WHEN c.is_nullable = 1 THEN ' NULL' ELSE ' NOT NULL' END
        + ISNULL(' DEFAULT ' + dc.definition, '')
    FROM sys.columns c
    JOIN sys.types t ON c.user_type_id = t.user_type_id
    LEFT JOIN sys.default_constraints dc ON c.default_object_id = dc.object_id
    LEFT JOIN sys.identity_columns ic ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE c.object_id = @objId
    ORDER BY c.column_id
    FOR XML PATH(''), TYPE
).value('.', 'nvarchar(max)'), 1, 1, '');

SELECT @pk =
    CASE WHEN COUNT(*) = 0 THEN N'' ELSE
        CHAR(10) + '  ,CONSTRAINT [' + kc.name + '] PRIMARY KEY ('
        + STUFF((
            SELECT ', [' + c.name + ']'
            FROM sys.index_columns ic
            JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
            WHERE ic.object_id = kc.parent_object_id
              AND ic.index_id = kc.unique_index_id
            ORDER BY ic.key_ordinal
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)'), 1, 2, '')
        + ')'
      END
FROM sys.key_constraints kc
WHERE kc.parent_object_id = @objId
  AND kc.type = 'PK';

SELECT 'CREATE TABLE [' + @schema + '].[' + @table + '] (' + @cols + ISNULL(@pk, '') + CHAR(10) + ');' AS ddl;
"@

    $ddlRaw = sqlcmd -S "$($env:SQLSERVER_HOST),$($env:SQLSERVER_PORT)" -d $env:SQLSERVER_DB -U $env:SQLSERVER_USER -P $env:SQLSERVER_PASSWORD -h -1 -W -Q $ddlQuery | Out-String

    $ddl = $ddlRaw.Trim()
    if ([string]::IsNullOrWhiteSpace($ddl)) {
        Write-Warning "No DDL generated for [$schemaName].[$tableName]"
        continue
    }

    $safeSchema = $schemaName.Replace(' ', '_')
    $safeTable = $tableName.Replace(' ', '_')
    $path = Join-Path $outRoot "$safeSchema.$safeTable.sql"
    Set-Content -Path $path -Value $ddl -Encoding UTF8
    $exported++
}

Write-Host "Exported $exported SQL Server table DDL files to $outRoot" -ForegroundColor Green
