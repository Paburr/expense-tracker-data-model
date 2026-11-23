#!/usr/bin/env python3
"""Verification harness for the expense-tracker-data-model data layer.

Builds a throwaway SQLite database in a fresh system temp directory, applies
`schema/01-ddl.sql` and `schema/02-seed.sql`, then:

  1. exercises the database-level rules (duplicate signature, foreign keys,
     CHECK constraints, declared-duplicate consistency),
  2. runs every report query in `queries/` and prints a compact summary
     (row count plus the first rows),
  3. removes the temp directory and exits non-zero if anything failed.

Requires only the Python standard library (sqlite3 from Python 3.x).
"""

from __future__ import annotations

import shutil
import sqlite3
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DDL_FILE = ROOT / "schema" / "01-ddl.sql"
SEED_FILE = ROOT / "schema" / "02-seed.sql"
QUERY_DIR = ROOT / "queries"

MAX_PREVIEW_ROWS = 3
MAX_PREVIEW_WIDTH = 78


def configure_stdout() -> None:
    # Seed values are Spanish text; force UTF-8 so the summary is readable on
    # consoles that default to a legacy code page.
    reconfigure = getattr(sys.stdout, "reconfigure", None)
    if reconfigure is not None:
        reconfigure(encoding="utf-8", errors="replace")


def read_sql(path: Path) -> str:
    if not path.is_file():
        raise FileNotFoundError(f"Missing required file: {path}")
    return path.read_text(encoding="utf-8")


def connect(db_path: Path) -> sqlite3.Connection:
    # Foreign keys are off by default in SQLite and must be enabled per
    # connection. PostgreSQL always enforces them, so this is a driver concern
    # and stays out of the portable DDL.
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def scalar_count(conn: sqlite3.Connection, sql: str) -> int:
    return int(conn.execute(sql).fetchone()[0])


def try_insert(conn: sqlite3.Connection, sql: str, params: tuple = ()) -> str:
    """Run a statement inside a rolled-back savepoint.

    Returns "accepted" or "rejected" so callers can assert the intended
    database behaviour without leaving any state behind.
    """
    conn.execute("SAVEPOINT probe")
    try:
        conn.execute(sql, params)
        outcome = "accepted"
    except sqlite3.IntegrityError:
        outcome = "rejected"
    finally:
        conn.execute("ROLLBACK TO probe")
        conn.execute("RELEASE probe")
    return outcome


def check_rules(conn: sqlite3.Connection) -> list[str]:
    """Assert the business rules that the schema claims to enforce."""
    failures: list[str] = []

    def expect(label: str, sql: str, expected: str, params: tuple = ()) -> None:
        observed = try_insert(conn, sql, params)
        status = "ok" if observed == expected else "FAIL"
        print(f"  [{status}] {label}: {observed} (expected {expected})")
        if observed != expected:
            failures.append(label)

    insert_expense = (
        "INSERT INTO expense (id, currency_id, card_id, capture_batch_id, description,"
        " amount_cents, spent_on, is_edited, created_at)"
        " VALUES (?, ?, ?, ?, ?, ?, ?, 0, '2025-06-01T00:00:00')"
    )

    print("Rule checks")
    expect(
        "duplicate signature inside one capture batch is rejected",
        insert_expense,
        "rejected",
        (900, 1, 1, 1, "  supermercado-DEMO ", 42500, "2025-03-03"),
    )
    expect(
        "same signature in a different capture batch is allowed",
        insert_expense,
        "accepted",
        (901, 1, 1, 4, "Supermercado Demo", 42500, "2025-06-01"),
    )
    expect(
        "different amount breaks the signature (legitimate repeat)",
        insert_expense,
        "accepted",
        (902, 1, 1, 1, "Supermercado Demo", 42501, "2025-03-03"),
    )
    expect(
        "expense cannot reference a card that does not exist",
        insert_expense,
        "rejected",
        (903, 1, 99, 1, "Comercio Inexistente", 1000, "2025-03-03"),
    )
    expect(
        "expense cannot reference a currency that does not exist",
        insert_expense,
        "rejected",
        (904, 99, 1, 1, "Comercio Ejemplo", 1000, "2025-03-03"),
    )
    expect(
        "amount must be strictly positive",
        insert_expense,
        "rejected",
        (905, 1, 1, 1, "Comercio Ejemplo", 0, "2025-03-03"),
    )
    expect(
        "currency code is restricted to the supported set",
        "INSERT INTO currency (id, code, symbol) VALUES (?, ?, ?)",
        "rejected",
        (90, "EUR", "E"),
    )
    expect(
        "card last digits must fit the 0..9999 range",
        "INSERT INTO card (id, label, last_digits) VALUES (?, ?, ?)",
        "rejected",
        (90, "Tarjeta Fuera de Rango", 10000),
    )
    expect(
        "declared duplicate must share the expense signature",
        "INSERT INTO detected_duplicate (expense_id, original_expense_id,"
        " duplicate_signature, status, detected_on) VALUES (?, ?, ?, ?, ?)",
        "rejected",
        (2, 1, "1|1|NOTTHESIGNATURE", "pending", "2025-03-05"),
    )
    expect(
        "an expense cannot be declared as its own duplicate",
        "INSERT INTO detected_duplicate (expense_id, original_expense_id,"
        " duplicate_signature, status, detected_on)"
        " SELECT ?, ?, duplicate_signature, 'pending', '2025-03-05' FROM expense WHERE id = ?",
        "rejected",
        (1, 1, 1),
    )

    undeclared = scalar_count(conn, "SELECT COUNT(*) FROM v_undeclared_duplicate")
    status = "ok" if undeclared == 0 else "FAIL"
    print(f"  [{status}] every repeated signature in the seed is declared: {undeclared} undeclared")
    if undeclared:
        failures.append("undeclared duplicates in seed")

    return failures


def preview(rows: list[tuple]) -> str:
    if not rows:
        return "    (no rows)"
    lines = []
    for row in rows[:MAX_PREVIEW_ROWS]:
        text = "    - " + ", ".join("NULL" if value is None else str(value) for value in row)
        lines.append(text[:MAX_PREVIEW_WIDTH])
    if len(rows) > MAX_PREVIEW_ROWS:
        lines.append(f"    ... {len(rows) - MAX_PREVIEW_ROWS} more row(s)")
    return "\n".join(lines)


def run_queries(conn: sqlite3.Connection) -> list[str]:
    failures: list[str] = []
    query_files = sorted(QUERY_DIR.glob("*.sql"))
    if not query_files:
        raise FileNotFoundError(f"No query files found in {QUERY_DIR}")

    print("Report queries")
    for path in query_files:
        try:
            cursor = conn.execute(read_sql(path))
            rows = cursor.fetchall()
        except sqlite3.Error as error:
            print(f"  [FAIL] {path.name}: {error}")
            failures.append(f"{path.name}: {error}")
            continue
        if not rows:
            print(f"  [FAIL] {path.name}: 0 rows")
            failures.append(f"{path.name}: returned no rows")
            continue
        print(f"  [ok] {path.name}: {len(rows)} row(s)")
        print(preview(rows))
    return failures


def main() -> int:
    configure_stdout()
    workdir = Path(tempfile.mkdtemp(prefix="expense-tracker-data-model-verify-"))
    db_path = workdir / "verify.db"
    failures: list[str] = []
    try:
        ddl = read_sql(DDL_FILE)
        seed = read_sql(SEED_FILE)
        conn = connect(db_path)
        try:
            conn.executescript(ddl)
            print(f"Schema applied: {DDL_FILE.name}")
            conn.executescript(seed)
            print(f"Seed applied: {SEED_FILE.name}")

            expense_count = scalar_count(conn, "SELECT COUNT(*) FROM expense")
            currency_count = scalar_count(conn, "SELECT COUNT(*) FROM currency")
            print(f"Seed rows: {currency_count} currency, {expense_count} expense")

            failures.extend(check_rules(conn))
            failures.extend(run_queries(conn))
        finally:
            conn.close()
    except Exception as error:  # noqa: BLE001 - reporter, must not crash silently
        print(f"[FAIL] verification aborted: {error}")
        failures.append(str(error))
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    if failures:
        print(f"\nRESULT: FAILED ({len(failures)} problem(s))")
        return 1
    print("\nRESULT: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
