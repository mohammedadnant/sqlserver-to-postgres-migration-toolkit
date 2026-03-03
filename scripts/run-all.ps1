param(
	[switch]$EnableAiShellEnhancement
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host 'Step 0/10: Checking prerequisites...'
& "$scriptDir\00-check-prereqs.ps1"

Write-Host 'Step 1/10: Creating PostgreSQL target database if needed...'
& "$scriptDir\02-create-postgres-db.ps1"

Write-Host 'Step 2/10: Exporting SQL Server table DDL files...'
& "$scriptDir\03-export-sqlserver-tables.ps1"

Write-Host 'Step 3/10: Extracting SQL Server views/procedures/functions/triggers...'
& "$scriptDir\04-extract-sqlserver-objects.ps1"

Write-Host 'Step 4/10: Migrating schemas/tables/data with pgloader...'
& "$scriptDir\05-run-pgloader.ps1"

Write-Host 'Step 5/10: Converting SQL Server programmable objects to PostgreSQL SQL...'
& "$scriptDir\06-convert-objects.ps1"

Write-Host 'Step 6/10: Converting Upsert shell procedures (deterministic pass)...'
python "$scriptDir\bulk_convert_upsert_shells.py" --root (Split-Path -Parent $scriptDir)

if ($EnableAiShellEnhancement) {
	Write-Host 'Step 7/10: Enhancing remaining shell procedures with local AI model...'
	python "$scriptDir\enhance_shell_procedures.py" --root (Split-Path -Parent $scriptDir)
} else {
	Write-Host 'Step 7/10: Skipping AI shell enhancement (use -EnableAiShellEnhancement to enable).'
}

Write-Host 'Step 8/10: Applying converted objects in PostgreSQL...'
& "$scriptDir\07-apply-converted-objects.ps1"

Write-Host 'Step 9/10: Validating row counts...'
& "$scriptDir\08-validate-row-counts.ps1"

Write-Host 'Migration pipeline completed.' -ForegroundColor Green
