from __future__ import annotations

import argparse
from pathlib import Path

from enhance_with_phi_mini import _extract_sql_only, _looks_like_deployable_sql, try_foundry_generate


SHELL_MARKER = "converted to deployable shell; manual logic porting required."


def build_prompt(source_sql: str, converted_sql: str, file_name: str) -> str:
    return (
        "You are a senior SQL migration engineer. Convert this SQL Server stored procedure to PostgreSQL PL/pgSQL.\n"
        "Requirements:\n"
        "- Preserve business logic and result-code behavior exactly.\n"
        "- Return deployable PostgreSQL SQL only (no explanation, no markdown, no code fences).\n"
        "- First non-whitespace token must be one of: SET, CREATE, DO, DROP.\n"
        "- Keep the existing procedure name and parameter list from the current converted SQL.\n"
        "- Replace shell notices with full executable logic.\n"
        "- Use PostgreSQL idioms (clock_timestamp, RETURNING, EXCEPTION blocks, etc.).\n"
        "- Do not emit SQL Server-only syntax (TRY/CATCH, SCOPE_IDENTITY, @@TRANCOUNT, THROW, WITH (UPDLOCK)).\n\n"
        f"File: {file_name}\n\n"
        "Original SQL Server procedure:\n"
        f"{source_sql}\n\n"
        "Current converted PostgreSQL SQL (shell):\n"
        f"{converted_sql}\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--limit", type=int, default=0, help="Max number of shell procedures to enhance (0 = all)")
    args = parser.parse_args()

    root = Path(args.root)
    converted_dir = root / "artifacts" / "converted_objects" / "procedures"
    source_dir = root / "artifacts" / "sqlserver_objects" / "procedures"

    files = sorted(converted_dir.glob("*.sql"))
    shell_files = []
    for file_path in files:
        text = file_path.read_text(encoding="utf-8", errors="ignore")
        if SHELL_MARKER in text:
            shell_files.append(file_path)

    if args.limit and args.limit > 0:
        shell_files = shell_files[: args.limit]

    updated = 0
    failed = 0
    for converted_path in shell_files:
        source_path = source_dir / converted_path.name
        converted_sql = converted_path.read_text(encoding="utf-8", errors="ignore")
        source_sql = source_path.read_text(encoding="utf-8", errors="ignore") if source_path.exists() else ""

        prompt = build_prompt(source_sql, converted_sql, converted_path.name)

        try:
            generated = try_foundry_generate(prompt, root)
            sql_text = _extract_sql_only(generated)
            if _looks_like_deployable_sql(sql_text):
                converted_path.write_text(sql_text.strip() + "\n", encoding="utf-8")
                updated += 1
            else:
                failed += 1
                print(f"Skip {converted_path.name}: empty/non-SQL output")
        except Exception as exc:
            failed += 1
            print(f"Skip {converted_path.name}: {exc}")

    print(f"Enhanced shell procedures: updated={updated}, failed={failed}, targeted={len(shell_files)}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
