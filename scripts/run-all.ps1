$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host 'Step 0/8: Checking prerequisites...'
& "$scriptDir\00-check-prereqs.ps1"

Write-Host 'Step 1/8: Creating PostgreSQL target database if needed...'
& "$scriptDir\02-create-postgres-db.ps1"

Write-Host 'Step 2/8: Exporting SQL Server table DDL files...'
& "$scriptDir\03-export-sqlserver-tables.ps1"

Write-Host 'Step 3/8: Extracting SQL Server views/procedures/functions/triggers...'
& "$scriptDir\04-extract-sqlserver-objects.ps1"

Write-Host 'Step 4/8: Migrating schemas/tables/data with pgloader...'
& "$scriptDir\05-run-pgloader.ps1"

Write-Host 'Step 5/8: Converting SQL Server programmable objects to PostgreSQL SQL...'
& "$scriptDir\06-convert-objects.ps1"

Write-Host 'Step 6/8: Applying converted objects in PostgreSQL...'
& "$scriptDir\07-apply-converted-objects.ps1"

Write-Host 'Step 7/8: Validating row counts...'
& "$scriptDir\08-validate-row-counts.ps1"

Write-Host 'Migration pipeline completed.' -ForegroundColor Green
