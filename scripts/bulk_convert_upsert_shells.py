from __future__ import annotations

import argparse
import re
from pathlib import Path

SHELL_MARKER = "converted to deployable shell; manual logic porting required."

TECHNICAL_COLS = {
    "isactive",
    "isdeleted",
    "ismodified",
    "insertedby",
    "insertedat",
    "updatedby",
    "updatedat",
    "deletedby",
    "deletedat",
}


def split_csv(text: str) -> list[str]:
    cleaned = text.replace("\r", " ").replace("\n", " ")
    parts: list[str] = []
    current: list[str] = []
    depth = 0
    in_single_quote = False
    i = 0
    while i < len(cleaned):
        ch = cleaned[i]
        if ch == "'":
            if in_single_quote and i + 1 < len(cleaned) and cleaned[i + 1] == "'":
                current.append("''")
                i += 2
                continue
            in_single_quote = not in_single_quote
            current.append(ch)
        elif not in_single_quote and ch == "(":
            depth += 1
            current.append(ch)
        elif not in_single_quote and ch == ")":
            depth = max(0, depth - 1)
            current.append(ch)
        elif not in_single_quote and depth == 0 and ch == ",":
            item = "".join(current).strip()
            if item:
                parts.append(item)
            current = []
        else:
            current.append(ch)
        i += 1

    tail = "".join(current).strip()
    if tail:
        parts.append(tail)
    return parts


def to_bool_literals(sql: str) -> str:
    sql = re.sub(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*0\b", lambda m: f"{m.group(1)} = false" if m.group(1).lower() in {"isdeleted", "isactive", "ismodified"} else m.group(0), sql)
    sql = re.sub(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*1\b", lambda m: f"{m.group(1)} = true" if m.group(1).lower() in {"isdeleted", "isactive", "ismodified"} else m.group(0), sql)
    return sql


def convert_expr(expr: str, proc_name: str | None = None) -> str:
    s = expr.strip()
    if ";" in s:
        s = s.split(";", 1)[0].strip()
    s = re.sub(r"(?is)^\s*SET\s+@?[A-Za-z_][A-Za-z0-9_]*\s*=\s*SCOPE_IDENTITY\(\)\s*$", "target_id", s)
    if proc_name:
        s = re.sub(r"@([A-Za-z_][A-Za-z0-9_]*)", lambda m: f"{proc_name}.{m.group(1).lower()}", s)
    else:
        s = re.sub(r"@([A-Za-z_][A-Za-z0-9_]*)", lambda m: m.group(1).lower(), s)
    if proc_name:
        s = re.sub(rf"\b{re.escape(proc_name)}\.now\b", "now_ts", s, flags=re.IGNORECASE)
    s = re.sub(r"\bnow\b", "now_ts", s, flags=re.IGNORECASE)
    s = re.sub(r"\bSYSDATETIME\(\)\b", "now_ts", s, flags=re.IGNORECASE)
    s = re.sub(r"\bGETDATE\(\)\b", "now_ts", s, flags=re.IGNORECASE)
    s = re.sub(r"\bGETUTCDATE\(\)\b", "now_ts", s, flags=re.IGNORECASE)
    s = re.sub(r"\bSCOPE_IDENTITY\(\)\b", "target_id", s, flags=re.IGNORECASE)
    s = to_bool_literals(s)
    return s


def qualify_table_columns(expr: str, columns: set[str], alias: str) -> str:
    qualified = expr
    for col in sorted(columns, key=len, reverse=True):
        pattern = rf"(?<!\.)\b{re.escape(col)}\b"
        qualified = re.sub(pattern, f"{alias}.{col}", qualified, flags=re.IGNORECASE)
    return qualified


def parse_source(source_sql: str):
    normalized = source_sql.replace("[", "").replace("]", "")

    m_table = re.search(
        r"IF\s+UPPER\(@ActionType\)\s*=\s*'INSERT'\s*BEGIN.*?FROM\s+(?:dbo\.)?([A-Za-z_][A-Za-z0-9_]*)\s*\n\s*WHERE\s+IsDeleted\s*=\s*0",
        normalized,
        flags=re.IGNORECASE | re.DOTALL,
    )
    if not m_table:
        m_table = re.search(r"FROM\s+(?:dbo\.)?([A-Za-z_][A-Za-z0-9_]*)\s*\n\s*WHERE\s+IsDeleted\s*=\s*0", normalized, flags=re.IGNORECASE)
    if not m_table:
        return parse_source_mode_b(normalized)
    table = m_table.group(1)

    m_pk = re.search(r"SELECT\s+@Target\w+\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s+FROM\s+(?:dbo\.)?" + re.escape(table), normalized, flags=re.IGNORECASE)
    if not m_pk:
        return parse_source_mode_b(normalized)
    pk_col = m_pk.group(1)

    insert_branch = re.search(
        r"IF\s+UPPER\(@ActionType\)\s*=\s*'INSERT'\s*BEGIN(.*?)ELSE\s+IF\s+UPPER\(@ActionType\)\s*=\s*'UPDATE'",
        normalized,
        flags=re.IGNORECASE | re.DOTALL,
    )
    insert_search_space = insert_branch.group(1) if insert_branch else normalized

    insert_parts = extract_insert_parts(insert_search_space, table)
    if not insert_parts:
        return parse_source_mode_b(normalized)
    insert_cols, insert_vals = insert_parts
    if len(insert_cols) != len(insert_vals):
        return parse_source_mode_b(normalized)

    update_branch = re.search(
        r"ELSE\s+IF\s+UPPER\(@ActionType\)\s*=\s*'UPDATE'\s*BEGIN(.*?)ELSE\s+IF\s+UPPER\(@ActionType\)\s*=\s*'DELETE'",
        normalized,
        flags=re.IGNORECASE | re.DOTALL,
    )
    update_search_space = update_branch.group(1) if update_branch else normalized

    update_matches = re.findall(
        r"UPDATE\s+(?:dbo\.)?" + re.escape(table) + r"\s*\n\s*SET\s*(.*?)\n\s*WHERE\s+" + re.escape(pk_col) + r"\s*=\s*@([A-Za-z_][A-Za-z0-9_]*)\s*;?",
        update_search_space,
        flags=re.IGNORECASE | re.DOTALL,
    )
    update_set = ""
    if update_matches:
        preferred = [m for m in update_matches if "target" not in m[1].lower()]
        chosen = preferred[-1] if preferred else update_matches[-1]
        update_set = chosen[0].strip()

    m_dup_where = re.search(
        r"FROM\s+(?:dbo\.)?" + re.escape(table) + r"\s*\n\s*WHERE\s+IsDeleted\s*=\s*0\s*(.*?)\s*AND\s+1\s*=\s*1\s*;?",
        normalized,
        flags=re.IGNORECASE | re.DOTALL,
    )
    dup_conditions = []
    if m_dup_where:
        cond_blob = m_dup_where.group(1)
        dup_conditions = [c.strip() for c in re.findall(r"AND\s+([^\n;]+)", cond_blob, flags=re.IGNORECASE) if c.strip()]

    return {
        "table": table,
        "pk_col": pk_col,
        "insert_cols": insert_cols,
        "insert_vals": insert_vals,
        "update_set": update_set,
        "dup_conditions": dup_conditions,
    }


def parse_source_mode_b(normalized_sql: str):
    insert_branch = re.search(
        r"IF\s+@ActionType\s*=\s*'INSERT'\s*BEGIN(.*?)ELSE\s+IF\s+@ActionType\s*=\s*'UPDATE'",
        normalized_sql,
        flags=re.IGNORECASE | re.DOTALL,
    )
    insert_search_space = insert_branch.group(1) if insert_branch else normalized_sql

    m_insert = re.search(
        r"INSERT\s+INTO\s+(?:dbo\.)?([A-Za-z_][A-Za-z0-9_]*)\s*\(",
        insert_search_space,
        flags=re.IGNORECASE,
    )
    if not m_insert:
        return None

    table = m_insert.group(1)
    insert_parts = extract_insert_parts(insert_search_space, table)
    if not insert_parts:
        return None
    insert_cols, insert_vals = insert_parts
    if len(insert_cols) != len(insert_vals):
        return None

    update_set = ""
    pk_col = None

    update_branch = re.search(
        r"ELSE\s+IF\s+UPPER\(@ActionType\)\s*=\s*'UPDATE'\s*BEGIN(.*?)ELSE\s+IF\s+UPPER\(@ActionType\)\s*=\s*'DELETE'",
        normalized_sql,
        flags=re.IGNORECASE | re.DOTALL,
    )
    update_space = update_branch.group(1) if update_branch else normalized_sql

    m_update = re.search(
        r"UPDATE\s+(?:dbo\.)?" + re.escape(table) + r"\s*\n\s*SET\s*(.*?)\n\s*WHERE\s+(.*?)\s*;",
        update_space,
        flags=re.IGNORECASE | re.DOTALL,
    )
    if m_update:
        update_set = m_update.group(1).strip()
        where_expr = m_update.group(2)
        m_pk_from_where = re.search(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*@([A-Za-z_][A-Za-z0-9_]*)\b", where_expr, flags=re.IGNORECASE)
        if m_pk_from_where:
            pk_col = m_pk_from_where.group(1)

    if not pk_col:
        delete_branch = re.search(
            r"ELSE\s+IF\s+UPPER\(@ActionType\)\s*=\s*'DELETE'\s*BEGIN(.*?)(?:ELSE|END\s*TRY|END)\b",
            normalized_sql,
            flags=re.IGNORECASE | re.DOTALL,
        )
        delete_space = delete_branch.group(1) if delete_branch else normalized_sql
        m_delete_where = re.search(
            r"UPDATE\s+(?:dbo\.)?" + re.escape(table) + r"\s*\n\s*SET\s*.*?\n\s*WHERE\s+(.*?)\s*;",
            delete_space,
            flags=re.IGNORECASE | re.DOTALL,
        )
        if m_delete_where:
            m_pk_from_delete = re.search(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*@([A-Za-z_][A-Za-z0-9_]*)\b", m_delete_where.group(1), flags=re.IGNORECASE)
            if m_pk_from_delete:
                pk_col = m_pk_from_delete.group(1)

    if not pk_col:
        pk_candidates = [c for c in insert_cols if c.lower().endswith("id") and c.lower() not in {"entityid"}]
        if pk_candidates:
            pk_col = pk_candidates[0]
        else:
            return None

    return {
        "table": table,
        "pk_col": pk_col,
        "insert_cols": insert_cols,
        "insert_vals": insert_vals,
        "update_set": update_set,
        "dup_conditions": [],
    }


def extract_insert_parts(sql_text: str, table: str) -> tuple[list[str], list[str]] | None:
    m = re.search(r"INSERT\s+INTO\s+(?:dbo\.)?" + re.escape(table) + r"\s*\(", sql_text, flags=re.IGNORECASE)
    if not m:
        return None

    cols_open_idx = sql_text.find("(", m.start())
    if cols_open_idx < 0:
        return None

    def read_balanced(text: str, open_idx: int) -> tuple[str, int] | None:
        depth = 0
        in_single_quote = False
        i = open_idx
        while i < len(text):
            ch = text[i]
            if ch == "'":
                if in_single_quote and i + 1 < len(text) and text[i + 1] == "'":
                    i += 2
                    continue
                in_single_quote = not in_single_quote
            elif not in_single_quote and ch == "(":
                depth += 1
            elif not in_single_quote and ch == ")":
                depth -= 1
                if depth == 0:
                    return text[open_idx + 1 : i], i
            i += 1
        return None

    cols_parsed = read_balanced(sql_text, cols_open_idx)
    if not cols_parsed:
        return None
    cols_blob, cols_close_idx = cols_parsed

    m_values = re.search(r"\bVALUES\b", sql_text[cols_close_idx + 1 :], flags=re.IGNORECASE)
    if not m_values:
        return None
    values_keyword_idx = cols_close_idx + 1 + m_values.start()

    vals_open_idx = sql_text.find("(", values_keyword_idx)
    if vals_open_idx < 0:
        return None

    vals_parsed = read_balanced(sql_text, vals_open_idx)
    if not vals_parsed:
        return None
    vals_blob, _ = vals_parsed

    insert_cols = split_csv(cols_blob)
    insert_vals = split_csv(vals_blob)
    if not insert_cols or not insert_vals:
        return None
    return insert_cols, insert_vals


def build_logic_block(meta: dict, param_names: set[str]) -> str:
    table = meta["table"].lower()
    pk_col = meta["pk_col"].lower()
    pk_param = pk_col.lower()
    if pk_param not in param_names:
        id_like = [p for p in param_names if p.endswith("id") and p not in {"entityid"}]
        if id_like:
            pk_param = id_like[0]

    proc_name = "upsert_" + table
    has_resultcode = "resultcode" in param_names

    def rc(value: str) -> str:
        return f"resultcode := {value};" if has_resultcode else "NULL;"

    now_decl = "DECLARE\n    now_ts timestamp := clock_timestamp();\n    target_id integer := NULL;\n    normalized_action text := upper(coalesce(actiontype, ''));"

    business_checks = []
    table_cols = {c.lower() for c in meta["insert_cols"]}
    table_cols.add(pk_col)

    if meta["dup_conditions"]:
        for cond in meta["dup_conditions"]:
            condition = convert_expr(cond, proc_name)
            condition = condition.replace(f"{proc_name}.", "__PROC__.")
            condition = qualify_table_columns(condition, table_cols, "t")
            condition = condition.replace("__PROC__.", f"{proc_name}.")
            business_checks.append(condition)
    else:
        for col in meta["insert_cols"]:
            c = col.lower()
            if c == pk_col.lower() or c in TECHNICAL_COLS:
                continue
            if c in param_names:
                business_checks.append(f"t.{c} = {proc_name}.{c}")

    where_business = "\n          AND ".join(business_checks) if business_checks else "1=1"

    insert_cols_list = [c.lower() for c in meta["insert_cols"]]
    insert_cols = ", ".join(insert_cols_list)
    insert_values_list = []
    for col, raw_val in zip(insert_cols_list, meta["insert_vals"]):
        value = convert_expr(raw_val, proc_name)
        if col in {"isactive", "isdeleted", "ismodified"}:
            if value.strip() == "0":
                value = "false"
            elif value.strip() == "1":
                value = "true"
        insert_values_list.append(value)
    insert_vals = ", ".join(insert_values_list)

    update_lines = []
    if meta["update_set"]:
        for a in split_csv(meta["update_set"]):
            update_lines.append(convert_expr(a, proc_name))
    update_set = ",\n                ".join(update_lines) if update_lines else "updatedat = now_ts"

    return f"""{now_decl}
BEGIN
    IF normalized_action = 'INSERT' THEN
        SELECT t.{pk_col}
        INTO target_id
        FROM dbo.{table} t
        WHERE t.isdeleted = false
          AND {where_business}
        LIMIT 1;

        IF target_id IS NOT NULL THEN
            {rc('-1')}
        ELSE
            SELECT t.{pk_col}
            INTO target_id
            FROM dbo.{table} t
            WHERE t.isdeleted = true
              AND {where_business}
            FOR UPDATE
            LIMIT 1;

            IF target_id IS NOT NULL THEN
                UPDATE dbo.{table}
                SET isdeleted = false,
                    isactive = true,
                    ismodified = true,
                    updatedby = auditusername,
                    updatedat = now_ts,
                    deletedby = NULL,
                    deletedat = NULL
                WHERE {pk_col} = target_id;

                {rc('2')}
            ELSE
                INSERT INTO dbo.{table}
                    ({insert_cols})
                VALUES ({insert_vals});

                SELECT t.{pk_col}
                INTO target_id
                FROM dbo.{table} t
                WHERE t.isdeleted = false
                  AND {where_business}
                ORDER BY t.{pk_col} DESC
                LIMIT 1;

                {rc('0')}
            END IF;
        END IF;

    ELSIF normalized_action = 'UPDATE' THEN
        IF {pk_param} IS NULL THEN
            {rc('-30')}
            RETURN;
        END IF;

        SELECT t.{pk_col}
        INTO target_id
        FROM dbo.{table} t
                WHERE t.{pk_col} = {proc_name}.{pk_param}
          AND t.isdeleted = false
        LIMIT 1;

        IF target_id IS NULL THEN
            {rc('-20')}
        ELSE
            UPDATE dbo.{table} AS u
            SET {update_set}
            WHERE u.{pk_col} = {proc_name}.{pk_param};

            {rc('1')}
        END IF;

    ELSIF normalized_action = 'DELETE' THEN
        IF {pk_param} IS NULL THEN
            {rc('-30')}
            RETURN;
        END IF;

        SELECT t.{pk_col}
        INTO target_id
        FROM dbo.{table} t
                WHERE t.{pk_col} = {proc_name}.{pk_param}
          AND t.isdeleted = false
        LIMIT 1;

        IF target_id IS NULL THEN
            {rc('-20')}
        ELSE
            UPDATE dbo.{table} AS u
            SET isdeleted = true,
                isactive = false,
                ismodified = true,
                updatedby = auditusername,
                updatedat = now_ts,
                deletedby = auditusername,
                deletedat = now_ts
            WHERE u.{pk_col} = {proc_name}.{pk_param};

            {rc('3')}
        END IF;

    ELSE
        {rc('-9')}
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        {rc('-9')}
        RAISE;
END;"""


def replace_body(converted_sql: str, logic_block: str) -> str:
    # Keep drop/create header + signature; replace body and remove commented original body.
    m = re.search(r"LANGUAGE\s+plpgsql\s*\nAS\s*\$\$", converted_sql, flags=re.IGNORECASE)
    if not m:
        return converted_sql
    head = converted_sql[: m.end()]
    new_sql = head + "\n" + logic_block + "\n$$;\n"
    return new_sql


def get_param_names(converted_sql: str) -> set[str]:
    m = re.search(r"CREATE\s+OR\s+REPLACE\s+PROCEDURE\s+dbo\.[^(]+\((.*?)\)\s*LANGUAGE", converted_sql, flags=re.IGNORECASE | re.DOTALL)
    if not m:
        return set()
    names = set()
    for line in m.group(1).splitlines():
        line = line.strip().rstrip(",")
        if not line:
            continue
        mm = re.match(r"(?:IN|OUT|INOUT)\s+([a-zA-Z_][a-zA-Z0-9_]*)", line, flags=re.IGNORECASE)
        if mm:
            names.add(mm.group(1).lower())
    return names


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--files", default="", help="Comma-separated converted file names to force-convert")
    parser.add_argument("--force", action="store_true", help="Convert targeted files even without shell marker")
    args = parser.parse_args()

    root = Path(args.root)
    src_dir = root / "artifacts" / "sqlserver_objects" / "procedures"
    dst_dir = root / "artifacts" / "converted_objects" / "procedures"
    artifact_dir = root / "artifacts"
    artifact_dir.mkdir(parents=True, exist_ok=True)
    parse_failures_path = artifact_dir / "upsert_shell_parse_failures.txt"
    summary_path = artifact_dir / "upsert_shell_conversion_summary.txt"

    updated = 0
    skipped = 0
    parse_failures: list[str] = []

    force_names = {x.strip() for x in args.files.split(",") if x.strip()}

    for dst in sorted(dst_dir.glob("dbo.Upsert_*.sql")):
        converted_sql = dst.read_text(encoding="utf-8", errors="ignore")
        if force_names and dst.name not in force_names:
            continue
        if not args.force and SHELL_MARKER not in converted_sql:
            continue

        src = src_dir / dst.name
        if not src.exists():
            skipped += 1
            print(f"skip {dst.name}: source missing")
            continue

        source_sql = src.read_text(encoding="utf-8", errors="ignore")
        meta = parse_source(source_sql)
        if not meta:
            skipped += 1
            print(f"skip {dst.name}: parse_source failed")
            parse_failures.append(dst.name)
            continue

        param_names = get_param_names(converted_sql)
        logic = build_logic_block(meta, param_names)
        out = replace_body(converted_sql, logic)

        dst.write_text(out, encoding="utf-8")
        updated += 1

    parse_failures_sorted = sorted(set(parse_failures))
    if parse_failures_sorted:
        parse_failures_path.write_text("\n".join(parse_failures_sorted) + "\n", encoding="utf-8")
    elif parse_failures_path.exists():
        parse_failures_path.unlink()

    summary = (
        "scope=upsert_shell_parser_only\n"
        "note=This file reports deterministic Upsert parser conversion only; it does not include PostgreSQL apply failures.\n"
        "apply_failures_file=artifacts/object_apply_failures.csv\n"
        f"updated={updated}\n"
        f"skipped={skipped}\n"
        f"parse_failures={len(parse_failures_sorted)}\n"
        f"parse_failures_file={parse_failures_path if parse_failures_sorted else 'none'}\n"
    )
    summary_path.write_text(summary, encoding="utf-8")

    print(f"bulk_convert_upsert_shells: updated={updated}, skipped={skipped}")
    if parse_failures_sorted:
        print(f"parse failures saved: {parse_failures_path}")
    else:
        print("parse failures saved: none")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
