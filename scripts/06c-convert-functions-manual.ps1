$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir

$inputDir = Join-Path $rootDir 'artifacts\sqlserver_objects\functions'
$outputDir = Join-Path $rootDir 'artifacts\converted_objects\functions'

if (-not (Test-Path $inputDir)) {
    throw "Functions input directory not found: $inputDir"
}

if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}

function Convert-Type {
    param([string]$TypeName)

    $t = $TypeName.Trim().ToLowerInvariant()

    if ($t -match '^(n?varchar|n?char)\s*\(.*\)$') { return 'text' }
    if ($t -match '^(varchar|char|nvarchar|nchar)$') { return 'text' }
    if ($t -match '^int$') { return 'integer' }
    if ($t -match '^bigint$') { return 'bigint' }
    if ($t -match '^smallint$') { return 'smallint' }
    if ($t -match '^tinyint$') { return 'smallint' }
    if ($t -match '^bit$') { return 'boolean' }
    if ($t -match '^uniqueidentifier$') { return 'uuid' }
    if ($t -match '^datetime2?$') { return 'timestamp' }
    if ($t -match '^smalldatetime$') { return 'timestamp' }
    if ($t -match '^date$') { return 'date' }
    if ($t -match '^time$') { return 'time' }
    if ($t -match '^decimal\((.+)\)$') { return "numeric($($matches[1]))" }
    if ($t -match '^numeric\((.+)\)$') { return "numeric($($matches[1]))" }
    if ($t -match '^decimal$|^numeric$') { return 'numeric' }
    if ($t -match '^float$|^real$') { return 'double precision' }
    if ($t -match '^money$|^smallmoney$') { return 'numeric' }

    return 'text'
}

function Parse-Function {
    param([string]$SqlText)

    $text = $SqlText -replace "`r`n", "`n"
    $text = $text.Replace([string][char]0xFEFF, '')

    $createMatch = [regex]::Match($text, '(?is)CREATE\s+FUNCTION\s+([\[\]\w\.]+)')
    if (-not $createMatch.Success) {
        return $null
    }

    $rawName = ($createMatch.Groups[1].Value -replace '[\[\]]', '').Trim()
    $nameParts = $rawName.Split('.')
    $fnName = if ($nameParts.Count -ge 2) { $nameParts[1] } else { $nameParts[0] }
    $fnName = $fnName.ToLowerInvariant()

    $afterCreate = $text.Substring($createMatch.Index + $createMatch.Length)
    $asMatch = [regex]::Match($afterCreate, '(?is)\bAS\b')
    if (-not $asMatch.Success) {
        return $null
    }

    $paramBlock = $afterCreate.Substring(0, $asMatch.Index)
    $body = $afterCreate.Substring($asMatch.Index + $asMatch.Length).Trim()

    $paramMatches = [regex]::Matches($paramBlock, '(?im)@(\w+)\s+([\w]+(?:\s*\([^\)]*\))?)')
    $params = @()

    foreach ($m in $paramMatches) {
        $name = $m.Groups[1].Value.ToLowerInvariant()
        $type = Convert-Type $m.Groups[2].Value
        $params += "IN $name $type"
    }

    $paramSql = if ($params.Count -gt 0) { $params -join ",`n    " } else { '' }

    $safeBody = $body -replace '\$\$', '$'
    $safeBody = $safeBody.Trim()
    $commentedBody = ($safeBody -split "`n" | ForEach-Object { "-- $_" }) -join "`n"

    $template = @'
SET search_path TO dbo, public;

DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS routine_sig
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'dbo'
          AND lower(p.proname) = '{0}'
    LOOP
        EXECUTE format('DROP FUNCTION IF EXISTS %s CASCADE', r.routine_sig);
    END LOOP;
END;
$$;

CREATE FUNCTION dbo.{0}(
    {1}
)
RETURNS text
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE NOTICE 'Function dbo.{0} converted to deployable shell; manual logic porting required.';
    RETURN NULL;
END;
$$;

-- Original SQL Server body for manual porting:
{2}
'@

    $converted = [string]::Format($template, $fnName, $paramSql, $commentedBody)

    return $converted.Trim() + "`n"
}

$files = Get-ChildItem -Path $inputDir -Filter *.sql | Sort-Object Name
$convertedCount = 0
$fallbackCount = 0

foreach ($file in $files) {
    $source = Get-Content -Path $file.FullName -Raw
    $converted = Parse-Function -SqlText $source

    $targetPath = Join-Path $outputDir $file.Name
    if ($null -eq $converted) {
        $fallbackName = ($file.BaseName -replace '^dbo\.', '').ToLowerInvariant()
        $fallbackTemplate = @'
SET search_path TO dbo, public;

DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS routine_sig
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'dbo'
          AND lower(p.proname) = '{0}'
    LOOP
        EXECUTE format('DROP FUNCTION IF EXISTS %s CASCADE', r.routine_sig);
    END LOOP;
END;
$$;

CREATE FUNCTION dbo.{0}()
RETURNS text
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE NOTICE 'Function conversion failed for {1}. Manual conversion required.';
    RETURN NULL;
END;
$$;
'@
        $fallback = [string]::Format($fallbackTemplate, $fallbackName, $file.Name)
        [System.IO.File]::WriteAllText($targetPath, $fallback, (New-Object System.Text.UTF8Encoding($false)))
        $fallbackCount++
        continue
    }

    [System.IO.File]::WriteAllText($targetPath, $converted, (New-Object System.Text.UTF8Encoding($false)))
    $convertedCount++
}

Write-Host "Manually converted $convertedCount functions; fallback shells: $fallbackCount. Output: $outputDir" -ForegroundColor Green
