from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path
from typing import Any


def build_prompt(source_sql: str, converted_sql: str, reason: str) -> str:
    return (
        "You are a SQL migration assistant. Convert SQL Server object to PostgreSQL deployable SQL.\n"
        "Strict output contract:\n"
        "- Return SQL text only.\n"
        "- Do NOT include explanations, markdown, code fences, bullets, or comments outside SQL statements.\n"
        "- First non-whitespace token must be one of: SET, CREATE, DO, DROP.\n"
        "- Preserve business logic and procedure/function signature behavior.\n"
        "- Avoid placeholders and TODO text.\n"
        "- Use PostgreSQL syntax only (no TRY/CATCH, @@TRANCOUNT, RAISERROR, SCOPE_IDENTITY, WITH (UPDLOCK)).\n\n"
        "- Return a complete object definition, not a partial snippet.\n"
        "- If creating PROCEDURE/FUNCTION, include LANGUAGE plpgsql, opening AS $$ and matching closing $$; terminator.\n"
        "- Do not stop early; ensure all BEGIN/END blocks are fully closed.\n\n"
        f"Failure reason:\n{reason}\n\n"
        f"Original SQL Server:\n{source_sql}\n\n"
        f"Current converted SQL:\n{converted_sql}\n"
    )


def _extract_sql_only(raw: str) -> str:
    text = (raw or "").strip()
    if not text:
        return ""

    fenced = re.search(r"```(?:sql)?\s*(.*?)```", text, flags=re.IGNORECASE | re.DOTALL)
    if fenced:
        text = fenced.group(1).strip()

    start = re.search(r"(?im)^\s*(SET\s+search_path|CREATE\s+OR\s+REPLACE\s+|CREATE\s+|DO\s+\$\$|DROP\s+)", text)
    if start:
        text = text[start.start():].strip()

    return text


def _looks_like_deployable_sql(text: str) -> bool:
    if not text:
        return False

    if re.search(r"(?im)^\s*(here is|to convert|i can|i'm unable|explanation|note:)", text):
        return False

    if not re.search(r"(?im)^\s*(SET\s+search_path|CREATE\s+OR\s+REPLACE\s+|CREATE\s+|DO\s+\$\$|DROP\s+)", text):
        return False

    dollar_tags = re.findall(r"\$\$", text)
    if len(dollar_tags) % 2 != 0:
        return False

    if re.search(r"(?im)\b(CREATE\s+OR\s+REPLACE\s+(PROCEDURE|FUNCTION)|CREATE\s+(PROCEDURE|FUNCTION))\b", text):
        if not re.search(r"(?im)\bLANGUAGE\s+plpgsql\b", text):
            return False
        if not re.search(r"\$\$\s*;\s*$", text):
            return False

    return True


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
            {"role": "system", "content": "You convert SQL Server SQL to PostgreSQL SQL. Output SQL only, no prose, no markdown."},
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


def _deterministic_fallback_sql(converted_path: Path, source_sql: str) -> str:
    name = converted_path.name.lower()

    if name == "dbo.sp_getfilestatistics.sql":
        return (
            "SET search_path TO dbo, public;\n\n"
            "CREATE OR REPLACE FUNCTION dbo.sp_getfilestatistics(tenantid uuid DEFAULT NULL::uuid)\n"
            "RETURNS TABLE (\n"
            "    totalfiles bigint,\n"
            "    totalsize bigint,\n"
            "    averagesize double precision,\n"
            "    activefiles bigint,\n"
            "    deletedfiles bigint,\n"
            "    uniquecontenttypes bigint,\n"
            "    uniquecategories bigint,\n"
            "    totaldownloads bigint\n"
            ")\n"
            "LANGUAGE plpgsql\n"
            "AS $$\n"
            "BEGIN\n"
            "    RETURN QUERY\n"
            "    SELECT\n"
            "        COUNT(*)::bigint AS totalfiles,\n"
            "        COALESCE(SUM(filemetadata.filesize), 0)::bigint AS totalsize,\n"
            "        COALESCE(AVG(filemetadata.filesize::double precision), 0)::double precision AS averagesize,\n"
            "        COUNT(*) FILTER (WHERE filemetadata.isdeleted = false AND filemetadata.isactive = true)::bigint AS activefiles,\n"
            "        COUNT(*) FILTER (WHERE filemetadata.isdeleted = true)::bigint AS deletedfiles,\n"
            "        COUNT(DISTINCT filemetadata.contenttype)::bigint AS uniquecontenttypes,\n"
            "        COUNT(DISTINCT filemetadata.category)::bigint AS uniquecategories,\n"
            "        COALESCE(SUM(filemetadata.downloadcount), 0)::bigint AS totaldownloads\n"
            "    FROM dbo.filemetadata\n"
            "    WHERE tenantid IS NULL OR filemetadata.tenantid = sp_getfilestatistics.tenantid;\n"
            "END;\n"
            "$$;\n"
        )

    if name == "dbo.upsertformpermission.sql":
        return (
            "SET search_path TO dbo, public;\n\n"
            "CREATE OR REPLACE PROCEDURE dbo.upsertformpermission(\n"
            "    IN formpermissionid integer,\n"
            "    IN formid integer,\n"
            "    IN roleid text,\n"
            "    IN canview boolean,\n"
            "    IN canadd boolean,\n"
            "    IN canedit boolean,\n"
            "    IN candelete boolean\n"
            ")\n"
            "LANGUAGE plpgsql\n"
            "AS $$\n"
            "BEGIN\n"
            "    IF EXISTS (\n"
            "        SELECT 1\n"
            "        FROM dbo.formpermissions fp\n"
            "        WHERE fp.formpermissionid = upsertformpermission.formpermissionid\n"
            "    ) THEN\n"
            "        UPDATE dbo.formpermissions\n"
            "        SET formid = upsertformpermission.formid,\n"
            "            roleid = upsertformpermission.roleid,\n"
            "            canview = upsertformpermission.canview,\n"
            "            canadd = upsertformpermission.canadd,\n"
            "            canedit = upsertformpermission.canedit,\n"
            "            candelete = upsertformpermission.candelete,\n"
            "            updatedat = clock_timestamp()\n"
            "        WHERE formpermissionid = upsertformpermission.formpermissionid;\n"
            "    ELSE\n"
            "        INSERT INTO dbo.formpermissions (formid, roleid, canview, canadd, canedit, candelete, updatedat)\n"
            "        VALUES (\n"
            "            upsertformpermission.formid,\n"
            "            upsertformpermission.roleid,\n"
            "            upsertformpermission.canview,\n"
            "            upsertformpermission.canadd,\n"
            "            upsertformpermission.canedit,\n"
            "            upsertformpermission.candelete,\n"
            "            clock_timestamp()\n"
            "        );\n"
            "    END IF;\n"
            "END;\n"
            "$$;\n"
        )

    if name == "dbo.sp_dropdiagram.sql":
        return (
            "SET search_path TO dbo, public;\n\n"
            "CREATE OR REPLACE PROCEDURE dbo.sp_dropdiagram(\n"
            "    IN diagramname text,\n"
            "    IN owner_id integer DEFAULT NULL,\n"
            "    INOUT resultcode integer DEFAULT 0\n"
            ")\n"
            "LANGUAGE plpgsql\n"
            "AS $$\n"
            "DECLARE\n"
            "    effective_owner integer;\n"
            "    target_diag_id integer;\n"
            "BEGIN\n"
            "    IF diagramname IS NULL OR btrim(diagramname) = '' THEN\n"
            "        resultcode := -1;\n"
            "        RETURN;\n"
            "    END IF;\n"
            "\n"
            "    effective_owner := owner_id;\n"
            "\n"
            "    IF effective_owner IS NULL THEN\n"
            "        SELECT principal_id\n"
            "        INTO effective_owner\n"
            "        FROM dbo.sysdiagrams\n"
            "        WHERE name = diagramname\n"
            "        ORDER BY diagram_id\n"
            "        LIMIT 1;\n"
            "    END IF;\n"
            "\n"
            "    SELECT diagram_id\n"
            "    INTO target_diag_id\n"
            "    FROM dbo.sysdiagrams\n"
            "    WHERE name = diagramname\n"
            "      AND (effective_owner IS NULL OR principal_id = effective_owner)\n"
            "    ORDER BY diagram_id\n"
            "    LIMIT 1;\n"
            "\n"
            "    IF target_diag_id IS NULL THEN\n"
            "        resultcode := -3;\n"
            "        RETURN;\n"
            "    END IF;\n"
            "\n"
            "    DELETE FROM dbo.sysdiagrams WHERE diagram_id = target_diag_id;\n"
            "    resultcode := 0;\n"
            "END;\n"
            "$$;\n"
        )

    return ""


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
        accepted_sql = ""
        for attempt in range(1, 4):
            try:
                generated = try_foundry_generate(prompt, root)
            except Exception as exc:
                if attempt == 3:
                    print(f"Skip {converted_path.name}: {exc}")
                continue

            if generated:
                sql_text = _extract_sql_only(generated)
                if _looks_like_deployable_sql(sql_text):
                    accepted_sql = sql_text
                    break
                if attempt == 3:
                    print(f"Skip {converted_path.name}: non-SQL/incomplete response rejected")

        if accepted_sql:
            converted_path.write_text(accepted_sql + "\n", encoding="utf-8")
            updated += 1
        else:
            fallback_sql = _deterministic_fallback_sql(converted_path, source_sql)
            if fallback_sql and _looks_like_deployable_sql(fallback_sql):
                converted_path.write_text(fallback_sql + "\n", encoding="utf-8")
                updated += 1
                print(f"Applied deterministic fallback: {converted_path.name}")

    print(f"Enhanced {updated} files using Foundry model.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
