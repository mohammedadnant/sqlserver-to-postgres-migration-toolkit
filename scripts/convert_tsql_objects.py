from __future__ import annotations

import argparse
from pathlib import Path


def get_sqlglot():
    try:
        import sqlglot
        from sqlglot import transpile
        return sqlglot, transpile
    except Exception as exc:
        raise RuntimeError(
            "sqlglot is required. Install with: pip install sqlglot"
        ) from exc


def convert_file(source: Path, target: Path, transpile):
    text = source.read_text(encoding="utf-8", errors="ignore")

    try:
        converted_chunks = transpile(text, read="tsql", write="postgres", pretty=True, error_level="ignore")
        converted = "\n\n".join(chunk.strip() for chunk in converted_chunks if chunk.strip())
    except Exception:
        converted = ""

    if not converted:
        converted = (
            "-- AUTO-CONVERSION FAILED. MANUAL REVIEW REQUIRED\n"
            "-- Original SQL Server definition is included below for manual conversion\n\n"
            f"{text.strip()}\n"
        )

    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(converted + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument(
        "--folders",
        default="functions,procedures,views,triggers",
        help="Comma-separated top-level folders under input to include (default excludes tables)",
    )
    args = parser.parse_args()

    _, transpile = get_sqlglot()

    input_root = Path(args.input)
    output_root = Path(args.output)

    include_folders = {
        part.strip().lower()
        for part in args.folders.split(",")
        if part.strip()
    }

    files = []
    for source in sorted(input_root.rglob("*.sql")):
        try:
            top_folder = source.relative_to(input_root).parts[0].lower()
        except Exception:
            continue

        if top_folder in include_folders:
            files.append(source)

    if not files:
        print("No SQL files found for conversion.")
        return

    converted_count = 0
    for source in files:
        rel = source.relative_to(input_root)
        target = output_root / rel
        convert_file(source, target, transpile)
        converted_count += 1

    print(f"Converted {converted_count} files to PostgreSQL SQL in {output_root}")


if __name__ == "__main__":
    main()
