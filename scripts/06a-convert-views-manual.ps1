$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir

$inputDir = Join-Path $rootDir 'artifacts\sqlserver_objects\views'
$outputDir = Join-Path $rootDir 'artifacts\converted_objects\views'

if (-not (Test-Path $inputDir)) {
    throw "Views input directory not found: $inputDir"
}

if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}

function Convert-ViewSql {
    param([string]$SqlText)

    $text = $SqlText -replace "`r`n", "`n"
    $text = $text -replace '\[([^\]]+)\]', '$1'
    $text = [regex]::Replace($text, '(?im)^\s*GO\s*$', '')

    $createMatch = [regex]::Match($text, '(?is)CREATE\s+VIEW\s+((?:\w+\.)?\w+)\s+AS')
    if (-not $createMatch.Success) {
        return "-- AUTO-CONVERSION FAILED: CREATE VIEW statement not found`n$text"
    }

    $fullName = $createMatch.Groups[1].Value
    $parts = $fullName.Split('.')
    $viewName = if ($parts.Count -ge 2) { $parts[1] } else { $parts[0] }
    $viewName = $viewName.ToLowerInvariant()

    $body = $text.Substring($createMatch.Index + $createMatch.Length).Trim()

    $body = [regex]::Replace($body, "'([^']*)'\s*\+\s*CAST\(", "'$1' || CAST(")
    $body = [regex]::Replace($body, '\b(IsActive|IsDeleted|IsPublic|IsModified)\s*=\s*1\b', '$1 = TRUE', 'IgnoreCase')
    $body = [regex]::Replace($body, '\b(IsActive|IsDeleted|IsPublic|IsModified)\s*=\s*0\b', '$1 = FALSE', 'IgnoreCase')

    $converted = @"
SET search_path TO dbo, public;

CREATE OR REPLACE VIEW dbo.$viewName AS
$body
"@

    $converted = $converted.Trim() + ';'
    return $converted + "`n"
}

$files = Get-ChildItem -Path $inputDir -Filter *.sql | Sort-Object Name
$count = 0

foreach ($file in $files) {
    $source = Get-Content -Path $file.FullName -Raw
    $converted = Convert-ViewSql -SqlText $source

    $targetPath = Join-Path $outputDir $file.Name
    Set-Content -Path $targetPath -Value $converted -Encoding UTF8
    $count++
}

Write-Host "Manually converted $count view files to PostgreSQL SQL in $outputDir" -ForegroundColor Green
