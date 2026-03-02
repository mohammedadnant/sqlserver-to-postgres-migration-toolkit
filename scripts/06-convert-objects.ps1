param(
    [switch]$IncludeTables
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir

$inputDir = Join-Path $rootDir 'artifacts\sqlserver_objects'
$outputDir = Join-Path $rootDir 'artifacts\converted_objects'
$converter = Join-Path $scriptDir 'convert_tsql_objects.py'
$viewConverter = Join-Path $scriptDir '06a-convert-views-manual.ps1'
$procedureConverter = Join-Path $scriptDir '06b-convert-procedures-manual.ps1'
$functionConverter = Join-Path $scriptDir '06c-convert-functions-manual.ps1'

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw 'python is required for object conversion. Install Python and re-run.'
}

python -m pip install --disable-pip-version-check -q sqlglot

$folderList = if ($IncludeTables) {
    'functions,procedures,triggers,tables'
} else {
    'functions,procedures,triggers'
}

python $converter --input $inputDir --output $outputDir --folders $folderList
& $viewConverter
& $procedureConverter
& $functionConverter

Write-Host "Object conversion finished: $outputDir" -ForegroundColor Green
