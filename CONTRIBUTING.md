# Contributing

Thanks for contributing to this SQL Server to PostgreSQL Migration Toolkit.

## How to contribute

- Open an issue describing the problem, sample input SQL, and expected output.
- Keep pull requests focused and small (one fix/feature per PR).
- Include clear reproduction steps and commands used.
- Update docs when behavior or scripts change.

## Development notes

- Main entry points:
  - `scripts/run-from-scratch.ps1`
  - `scripts/run-all.ps1`
- Conversion pipeline:
  - `scripts/06-convert-objects.ps1`
  - `scripts/06a-convert-views-manual.ps1`
  - `scripts/06b-convert-procedures-manual.ps1`
  - `scripts/06c-convert-functions-manual.ps1`

## Validation checklist

Before submitting, run:

```powershell
./scripts/run-from-scratch.ps1
```

Then confirm:

- No `artifacts/object_apply_failures.csv` file is generated (or failures are explained).
- `artifacts/row_count_report.csv` shows all rows matched.
- README is updated for any user-facing change.

## PR guidance

- Explain what changed and why.
- Mention any limitations or known edge cases.
- Attach sample logs or relevant output for migration/apply/validation steps.

## Code of conduct

Be respectful, constructive, and solution-oriented in issues and pull requests.
