param(
    [ValidateSet('Chat','PhiMini')]
    [string]$Mode = 'Chat'
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
. "$scriptDir\Helpers.ps1"

$failCsv = Join-Path $rootDir 'artifacts\object_apply_failures.csv'
$queuePath = Join-Path $rootDir 'artifacts\manual_enhancement_queue.md'

if (-not (Test-Path $failCsv)) {
    Write-Host 'No failure CSV found. Running apply once to refresh failures...' -ForegroundColor Yellow
    & "$scriptDir\07-apply-converted-objects.ps1"
}

if (-not (Test-Path $failCsv)) {
    Write-Host 'No failed objects detected. Nothing to enhance.' -ForegroundColor Green
    exit 0
}

$rows = Import-Csv $failCsv
if ($rows.Count -eq 0) {
    Write-Host 'Failure CSV is empty. Nothing to enhance.' -ForegroundColor Green
    exit 0
}

if ($Mode -eq 'Chat') {
    $lines = @()
    $lines += '# Manual Enhancement Queue'
    $lines += ''
    $lines += 'Use this queue with chat for semantic conversion of failed objects.'
    $lines += ''

    foreach ($row in $rows) {
        $convertedPath = $row.file_path
        $sourcePath = $convertedPath.Replace('artifacts\converted_objects', 'artifacts\sqlserver_objects')

        $lines += "## $([System.IO.Path]::GetFileName($convertedPath))"
        $lines += "- Source: $sourcePath"
        $lines += "- Converted: $convertedPath"
        $lines += "- Failure: $($row.reason)"
        $lines += '- Prompt: Convert this SQL Server object to PostgreSQL equivalent, preserving business logic. Return only deployable SQL.'
        $lines += ''
    }

    Set-Content -Path $queuePath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
    Write-Host "Generated manual enhancement queue: $queuePath" -ForegroundColor Green
    exit 0
}

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw 'python is required for PhiMini enhancement mode.'
}

python "$scriptDir\enhance_with_phi_mini.py" --root "$rootDir" --failures "$failCsv"
if ($LASTEXITCODE -ne 0) {
    throw 'PhiMini enhancement script failed.'
}

Write-Host 'Re-applying enhanced objects...' -ForegroundColor Yellow
& "$scriptDir\07-apply-converted-objects.ps1" -RetryKnownFailures

Write-Host 'Enhancement and publish step completed.' -ForegroundColor Green
