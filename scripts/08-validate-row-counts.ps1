$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
. "$scriptDir\Helpers.ps1"

Import-DotEnv "$rootDir\.env"
Require-Env @('SQLSERVER_HOST', 'SQLSERVER_PORT', 'SQLSERVER_DB', 'SQLSERVER_USER', 'SQLSERVER_PASSWORD', 'PG_HOST', 'PG_PORT', 'PG_DB', 'PG_USER', 'PG_PASSWORD')

$artifactDir = Join-Path $rootDir 'artifacts'
New-Directory $artifactDir

$sqlServerQuery = @"
SET NOCOUNT ON;
DECLARE @sql NVARCHAR(MAX) = N'';

SELECT @sql +=
    N'SELECT ''' + REPLACE(s.name + N'.' + t.name, '''', '''''') + N''' AS table_name, COUNT_BIG(*) AS row_count FROM '
    + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) + N' UNION ALL '
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0;

IF LEN(@sql) > 10
BEGIN
    SET @sql = LEFT(@sql, LEN(@sql) - 10);
    EXEC sp_executesql @sql;
END
"@

$sqlRows = sqlcmd -S "$($env:SQLSERVER_HOST),$($env:SQLSERVER_PORT)" -d $env:SQLSERVER_DB -U $env:SQLSERVER_USER -P $env:SQLSERVER_PASSWORD -h -1 -W -s "|" -Q $sqlServerQuery

$pgQuery = @'
DROP TABLE IF EXISTS tmp_migration_counts;
CREATE TEMP TABLE tmp_migration_counts (
        table_name text,
        row_count bigint
);

DO $$
DECLARE
        r record;
        c bigint;
BEGIN
        FOR r IN
                SELECT n.nspname AS schema_name, c.relname AS table_name
                FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relkind = 'r'
                    AND n.nspname NOT IN ('pg_catalog', 'information_schema')
                    AND n.nspname !~ '^pg_temp'
                    AND c.relname <> 'tmp_migration_counts'
                ORDER BY n.nspname, c.relname
        LOOP
                EXECUTE format('SELECT COUNT(*)::bigint FROM %I.%I', r.schema_name, r.table_name) INTO c;
                INSERT INTO tmp_migration_counts(table_name, row_count)
                VALUES (r.schema_name || '.' || r.table_name, c);
        END LOOP;
END $$;

SELECT table_name, row_count
FROM tmp_migration_counts
ORDER BY table_name;
'@

$env:PGPASSWORD = $env:PG_PASSWORD
$useLocalPsql = [bool](Get-Command psql -ErrorAction SilentlyContinue)
$pgHost = if ($useLocalPsql) { $env:PG_HOST } else { Resolve-DockerHost $env:PG_HOST }
$pgRows = Invoke-PsqlCommand -WorkspaceRoot $rootDir -Arguments @(
    '-h', $pgHost,
    '-p', $env:PG_PORT,
    '-U', $env:PG_USER,
    '-d', $env:PG_DB,
    '-A',
    '-F', '|',
    '-t',
    '-c', $pgQuery
)

$sourceMap = @{}
foreach ($line in $sqlRows) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line.Split('|')
    if ($parts.Count -lt 2) { continue }
    $key = $parts[0].Trim()
    $sourceMap[$key] = [int64]($parts[1].Trim())
}

$targetMap = @{}
foreach ($line in $pgRows) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line.Split('|')
    if ($parts.Count -lt 2) { continue }
    $key = $parts[0].Trim()
    $targetMap[$key] = [int64]($parts[1].Trim())
}

$allKeys = ($sourceMap.Keys + $targetMap.Keys | Sort-Object -Unique)
$report = foreach ($key in $allKeys) {
    $sourceCount = if ($sourceMap.ContainsKey($key)) { $sourceMap[$key] } else { 0 }
    $targetCount = if ($targetMap.ContainsKey($key)) { $targetMap[$key] } else { 0 }
    [PSCustomObject]@{
        table_name   = $key
        sqlserver    = $sourceCount
        postgres     = $targetCount
        diff         = ($targetCount - $sourceCount)
        matched      = ($targetCount -eq $sourceCount)
    }
}

$reportPath = Join-Path $artifactDir 'row_count_report.csv'
$report | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8

$failCount = ($report | Where-Object { -not $_.matched }).Count
if ($failCount -gt 0) {
    Write-Warning "$failCount tables have row count mismatches. Report: $reportPath"
} else {
    Write-Host "Row count validation passed for all tables. Report: $reportPath" -ForegroundColor Green
}
