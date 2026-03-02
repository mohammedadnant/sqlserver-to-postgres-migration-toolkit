# SQL Server to PostgreSQL Migration Toolkit

Practical automation for migrating a SQL Server database to PostgreSQL on local/dev environments.

This toolkit focuses on:
- reliable schema/table/data migration,
- repeatable end-to-end execution,
- best-effort conversion of programmable objects,
- post-migration validation and failure reporting.

## Why this project

Database migration is usually split between bulk data tools and manual object rewrites. This project combines both in one scriptable pipeline so teams can migrate quickly, then iterate only where business logic needs deeper conversion.

## What it does

1. Exports SQL Server table definitions in bulk.
2. Extracts views, procedures, functions, and triggers.
3. Creates PostgreSQL target database if needed.
4. Migrates schema, tables, columns, and data using `pgloader`.
5. Converts programmable objects to PostgreSQL SQL (best effort).
6. Applies converted objects to PostgreSQL with robust failure reporting.
7. Validates row counts between SQL Server and PostgreSQL.

## Deterministic vs LLM path

The successful default pipeline is deterministic (PowerShell + `pgloader` + rule-based conversion).

Optional LLM enhancement is available in `09-enhance-and-publish.ps1`:
- `-Mode Chat`: creates a manual enhancement queue.
- `-Mode PhiMini`: attempts automated rewrite through a local Foundry-compatible model endpoint.

Use LLM mode as an accelerator, not a guarantee.

## Project structure

- `scripts/` migration pipeline and helpers
- `config/` generated `pgloader` load file
- `artifacts/sqlserver_objects/` extracted SQL Server definitions
- `artifacts/converted_objects/` converted PostgreSQL SQL
- `artifacts/row_count_report.csv` row count validation report
- `artifacts/object_apply_failures.csv` apply failures (when present)

## Prerequisites

- Docker Desktop (running)
- SQL Server CLI tools (`sqlcmd`)
- Python 3
- PostgreSQL `psql` client (optional; Dockerized fallback is built-in)

## Configuration

1. Create `.env` from `.env.template`:

```powershell
Copy-Item .env.template .env
```

Or on bash:

```bash
cp .env.template .env
```

2. Fill all SQL Server and PostgreSQL values
3. Set target database name in `PG_DB`
4. Optional: set `PG_ADMIN_DB` (defaults to `postgres`)

Never commit `.env` with real credentials.

Install Python dependencies:

```powershell
python -m pip install -r requirements.txt
```

## Quick start

Fresh full run (recommended):

```powershell
./scripts/run-from-scratch.ps1
```

Full run without reset:

```powershell
./scripts/run-all.ps1
```

## Pipeline scripts (all .ps1 files)

```powershell
./scripts/00-check-prereqs.ps1
./scripts/00-reset-state.ps1
./scripts/02-create-postgres-db.ps1
./scripts/03-export-sqlserver-tables.ps1
./scripts/04-extract-sqlserver-objects.ps1
./scripts/05-run-pgloader.ps1
./scripts/06-convert-objects.ps1
./scripts/06a-convert-views-manual.ps1
./scripts/06b-convert-procedures-manual.ps1
./scripts/06c-convert-functions-manual.ps1
./scripts/07-apply-converted-objects.ps1
./scripts/08-validate-row-counts.ps1
./scripts/09-enhance-and-publish.ps1 -Mode Chat
./scripts/09-enhance-and-publish.ps1 -Mode PhiMini
./scripts/run-all.ps1
./scripts/run-from-scratch.ps1
```

## Script reference

- `00-check-prereqs.ps1`: validates required tools and runtime dependencies.
- `00-reset-state.ps1`: clears artifacts and recreates target PostgreSQL DB.
- `02-create-postgres-db.ps1`: ensures target PostgreSQL DB exists.
- `03-export-sqlserver-tables.ps1`: exports SQL Server table DDL in bulk.
- `04-extract-sqlserver-objects.ps1`: extracts views/procedures/functions/triggers.
- `05-run-pgloader.ps1`: migrates schema + tables + data using `pgloader`.
- `06-convert-objects.ps1`: orchestrates programmable-object conversion.
- `06a-convert-views-manual.ps1`: deterministic/manual-rule view conversion.
- `06b-convert-procedures-manual.ps1`: deterministic/manual-rule procedure conversion.
- `06c-convert-functions-manual.ps1`: deterministic/manual-rule function conversion.
- `07-apply-converted-objects.ps1`: applies converted SQL with failure reporting/retry options.
- `08-validate-row-counts.ps1`: compares SQL Server vs PostgreSQL row counts.
- `09-enhance-and-publish.ps1`: optional AI/manual enhancement pass on failed objects.
- `run-all.ps1`: executes the full pipeline without reset.
- `run-from-scratch.ps1`: reset + full pipeline in one command.

Helper scripts:
- `Helpers.ps1`: shared utility functions used by other scripts.

## Outputs you should review

- `artifacts/row_count_report.csv`
- `artifacts/converted_objects/**/*.sql`
- `artifacts/object_apply_failures.csv` (if generated)

## Known limitations

This toolkit handles most migration plumbing, but some SQL Server patterns still need manual conversion, especially:
- dynamic SQL and metadata-driven procedure logic,
- cursor-heavy routines,
- SQL Server security/permission semantics,
- advanced transaction/error behavior differences,
- SQL Server-only features with no direct PostgreSQL equivalent.

Large-scale data migration considerations:
- Default settings are tuned for practical local/dev migration, not maximum billion-row throughput.
- For very large databases, additional tuning is typically required (workers, batch sizing, infrastructure sizing, indexing strategy, cutover planning).

Schema parity considerations:
- Primary keys, indexes, sequences, and foreign keys are migrated by `pgloader` in most common cases.
- Some SQL Server-specific index/constraint behaviors may not map 1:1 and should be verified post-migration.

Future development:
- Add a dedicated "large database mode" profile for high-volume migrations.
- Add an automated index/foreign-key/constraint parity verification report between SQL Server and PostgreSQL.

For production usage, always run integration/business tests after migration.

## Troubleshooting

- If host networking fails from Docker, keep DB host as `localhost`; scripts map it to `host.docker.internal` for container tools.
- If object apply fails, inspect `artifacts/object_apply_failures.csv`, fix target SQL in `artifacts/converted_objects/`, then rerun:

```powershell
./scripts/07-apply-converted-objects.ps1 -RetryKnownFailures
```

## Contributing

Contributions are welcome:
- conversion rules for tricky T-SQL patterns,
- test databases and reproducible edge cases,
- improvements to validation and reporting,
- docs and platform compatibility updates.

## Disclaimer

This project is provided as-is. Always validate schema, data, and business behavior before using migrated output in production.
