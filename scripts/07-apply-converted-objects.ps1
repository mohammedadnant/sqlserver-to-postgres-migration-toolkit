param(
    [switch]$RetryKnownFailures,
    [switch]$IncludeTables,
    [string]$OnlyFile
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
. "$scriptDir\Helpers.ps1"

Import-DotEnv "$rootDir\.env"
Require-Env @('PG_HOST', 'PG_PORT', 'PG_DB', 'PG_USER', 'PG_PASSWORD')

$objectRoot = Join-Path $rootDir 'artifacts\converted_objects'
if (-not (Test-Path $objectRoot)) {
    throw "Converted objects directory not found: $objectRoot"
}

$targetFolders = @('functions', 'procedures', 'views', 'triggers')
if ($IncludeTables) {
    $targetFolders += 'tables'
}

$files = @()
foreach ($folder in $targetFolders) {
    $folderPath = Join-Path $objectRoot $folder
    if (Test-Path $folderPath) {
        $files += Get-ChildItem -Path $folderPath -Recurse -Filter *.sql
    }
}

$files = $files | Sort-Object FullName

if (-not [string]::IsNullOrWhiteSpace($OnlyFile)) {
    $files = $files | Where-Object {
        $_.Name -like $OnlyFile -or $_.FullName -like $OnlyFile
    }
}

if ($files.Count -eq 0) {
    throw 'No converted SQL files found to apply.'
}

$artifactDir = Join-Path $rootDir 'artifacts'
New-Directory $artifactDir
$failedPath = Join-Path $artifactDir 'object_apply_failures.txt'
$failedDetailPath = Join-Path $artifactDir 'object_apply_failures.csv'

$knownFailures = @{}
if (-not $RetryKnownFailures -and (Test-Path $failedPath)) {
    Get-Content $failedPath | ForEach-Object {
        $path = $_.Trim()
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $knownFailures[$path.ToLowerInvariant()] = $true
        }
    }
}

$env:PGPASSWORD = $env:PG_PASSWORD
$useLocalPsql = [bool](Get-Command psql -ErrorAction SilentlyContinue)
$pgHost = if ($useLocalPsql) { $env:PG_HOST } else { Resolve-DockerHost $env:PG_HOST }
$applied = 0
$skippedKnown = 0
$skippedInvalid = 0
$failed = @()

foreach ($file in $files) {
    $fileKey = $file.FullName.ToLowerInvariant()
    if (-not $RetryKnownFailures -and $knownFailures.ContainsKey($fileKey)) {
        $skippedKnown++
        continue
    }

    $rawContent = Get-Content -Path $file.FullName -Raw
    $firstLine = (Get-Content -Path $file.FullName -TotalCount 40 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)

    if ($rawContent -notmatch '(?is)\bcreate\b') {
        $failed += [PSCustomObject]@{
            file_path = $file.FullName
            reason    = 'invalid converted SQL (no CREATE statement found)'
        }
        $skippedInvalid++
        continue
    }

    if ($firstLine -match '^\s*CREATE\s+AS\s+(VIEW|FUNCTION|PROCEDURE)\b') {
        $failed += [PSCustomObject]@{
            file_path = $file.FullName
            reason    = 'invalid converted SQL (CREATE AS ... pattern)'
        }
        $skippedInvalid++
        continue
    }

    Write-Host "Applying $($file.FullName)"

    $fileArg = if ($useLocalPsql) {
        $file.FullName
    } else {
        $rootPrefix = $rootDir.TrimEnd('\') + '\'
        if ($file.FullName.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relative = $file.FullName.Substring($rootPrefix.Length).Replace('\', '/')
        } else {
            throw "File path '$($file.FullName)' is outside workspace root '$rootDir'."
        }
        "/workspace/$relative"
    }

    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $applyOutput = Invoke-PsqlCommand -WorkspaceRoot $rootDir -Arguments @(
        '-h', $pgHost,
        '-p', $env:PG_PORT,
        '-U', $env:PG_USER,
        '-d', $env:PG_DB,
        '-v', 'ON_ERROR_STOP=1',
        '-f', $fileArg
    ) 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousEap

    if ($exitCode -ne 0) {
        $outputLines = $applyOutput | ForEach-Object { $_.ToString() }
        $firstError = $outputLines | Where-Object { $_ -match 'ERROR:' } | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($firstError)) {
            $firstError = $outputLines | Select-Object -First 1
        }
        if ([string]::IsNullOrWhiteSpace($firstError)) {
            $firstError = 'apply failed with non-zero exit code'
        }

        $failed += [PSCustomObject]@{
            file_path = $file.FullName
            reason    = $firstError.Trim()
        }
        continue
    }

    $applied++
}

if ($failed.Count -gt 0) {
    Set-Content -Path $failedPath -Value ($failed | ForEach-Object { $_.file_path }) -Encoding UTF8
    $failed | Export-Csv -Path $failedDetailPath -NoTypeInformation -Encoding UTF8
    Write-Warning "Applied $applied files; skipped known failures: $skippedKnown; invalid pre-check skips: $skippedInvalid; failed: $($failed.Count)."
    Write-Warning "Failure files: $failedPath"
    Write-Warning "Failure details: $failedDetailPath"
} else {
    if (Test-Path $failedPath) { Remove-Item $failedPath -Force }
    if (Test-Path $failedDetailPath) { Remove-Item $failedDetailPath -Force }
    Write-Host "Applied $applied converted object files to PostgreSQL." -ForegroundColor Green
}
