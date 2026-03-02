from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Any


def build_prompt(source_sql: str, converted_sql: str, reason: str) -> str:
    return (
        "You are a SQL migration assistant. Convert SQL Server object to PostgreSQL deployable SQL.\n"
        "Preserve business logic; avoid placeholders.\n"
        "Return SQL only.\n\n"
        f"Failure reason:\n{reason}\n\n"
        f"Original SQL Server:\n{source_sql}\n\n"
        f"Current converted SQL:\n{converted_sql}\n"
    )


def _read_foundry_local_settings(appsettings_path: Path) -> dict[str, Any]:
    if not appsettings_path.exists():
        return {}

    try:
        data = json.loads(appsettings_path.read_text(encoding="utf-8"))
    except Exception:
        return {}

    value = data.get("FoundryLocal", {})
    if isinstance(value, dict):
        return value
    return {}


def _resolve_foundry_local_config(root: Path) -> tuple[str, str, str]:
    fallback_endpoint_primary = "http://127.0.0.1:59754"
    fallback_endpoint_secondary = "http://127.0.0.1:51110"
    fallback_model = "phi-3-mini-4k-instruct-trtrtx-gpu:1"

    search_candidates = [
        root / "appsettings.json",
        root / "scripts" / "appsettings.json",
        root.parent / "appsettings.json",
    ]

    foundry_local = {}
    for candidate in search_candidates:
        foundry_local = _read_foundry_local_settings(candidate)
        if foundry_local:
            break

    endpoint = str(foundry_local.get("BaseUrl", "")).strip()
    model = str(foundry_local.get("Model", "")).strip()

    endpoint = endpoint or os.getenv("FOUNDRY_LOCAL_BASE_URL", "").strip() or fallback_endpoint_primary
    model = model or os.getenv("FOUNDRY_LOCAL_MODEL", "").strip() or fallback_model

    api_key = os.getenv("FOUNDRY_LOCAL_API_KEY", "").strip()
    if not api_key:
        api_key = os.getenv("FOUNDRY_API_KEY", "").strip()

    if not endpoint:
        endpoint = fallback_endpoint_secondary

    return endpoint, model, api_key


def _post_chat_completion(
    *,
    endpoint: str,
    model: str,
    api_key: str,
    payload_messages: list[dict[str, str]],
) -> str:
    try:
        import requests
    except Exception as exc:
        raise RuntimeError("requests package is required for PhiMini mode.") from exc

    headers = {
        "Content-Type": "application/json",
    }
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    payload = {
        "model": model,
        "messages": payload_messages,
        "temperature": 0.1,
    }

    base = endpoint.rstrip("/")
    candidate_urls = [
        f"{base}/chat/completions",
        f"{base}/v1/chat/completions",
        f"{base}/openai/v1/chat/completions",
    ]

    last_error: Exception | None = None
    for url in candidate_urls:
        try:
            response = requests.post(url, headers=headers, json=payload, timeout=90)
            response.raise_for_status()
            data = response.json()
            return data["choices"][0]["message"]["content"].strip()
        except Exception as exc:
            last_error = exc

    raise RuntimeError(f"Foundry Local request failed for all URL patterns. Last error: {last_error}")


def try_foundry_generate(prompt: str, root: Path) -> str:
    endpoint, model, api_key = _resolve_foundry_local_config(root)

    return _post_chat_completion(
        endpoint=endpoint,
        model=model,
        api_key=api_key,
        payload_messages=[
            {"role": "system", "content": "You convert SQL Server SQL to PostgreSQL SQL."},
            {"role": "user", "content": prompt},
        ],
    )


def _row_value(row: dict[str, str], key: str) -> str:
    for k, v in row.items():
        if k and k.lstrip("\ufeff").strip().lower() == key.lower():
            return (v or "").strip()
    return ""


def _resolve_source_path(converted_path: Path, root: Path) -> Path:
    try:
        rel = converted_path.resolve().relative_to((root / "artifacts" / "converted_objects").resolve())
        return root / "artifacts" / "sqlserver_objects" / rel
    except Exception:
        text = str(converted_path)
        if "artifacts\\converted_objects" in text:
            return Path(text.replace("artifacts\\converted_objects", "artifacts\\sqlserver_objects"))
        if "artifacts/converted_objects" in text:
            return Path(text.replace("artifacts/converted_objects", "artifacts/sqlserver_objects"))
        return Path()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--failures", required=True)
    args = parser.parse_args()

    root = Path(args.root)
    failures_csv = Path(args.failures)
    if not failures_csv.exists():
        print("No failures CSV found.")
        return 0

    import csv

    updated = 0
    with failures_csv.open("r", encoding="utf-8", newline="") as fh:
        rows = list(csv.DictReader(fh))

    for row in rows:
        converted_raw = _row_value(row, "file_path")
        reason = _row_value(row, "reason")
        if not converted_raw:
            continue

        converted_path = Path(converted_raw)
        if not converted_path.exists() or not converted_path.is_file():
            continue

        source_path = _resolve_source_path(converted_path, root)
        source_sql = source_path.read_text(encoding="utf-8", errors="ignore") if source_path.exists() and source_path.is_file() else ""
        converted_sql = converted_path.read_text(encoding="utf-8", errors="ignore")

        prompt = build_prompt(source_sql, converted_sql, reason)
        try:
            generated = try_foundry_generate(prompt, root)
        except Exception as exc:
            print(f"Skip {converted_path.name}: {exc}")
            continue

        if generated:
            converted_path.write_text(generated + "\n", encoding="utf-8")
            updated += 1

    print(f"Enhanced {updated} files using Foundry model.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
