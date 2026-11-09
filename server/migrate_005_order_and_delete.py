#!/usr/bin/env python3
"""Migration 005: owner-set order and delete for toppings and menu pizzas.

Adds:
  toppings.sort_order  INTEGER NOT NULL DEFAULT 0  (list order in /admin and the app)
  toppings.deleted     INTEGER NOT NULL DEFAULT 0  (1 = deleted in /admin)
  pizzas.sort_order    INTEGER NOT NULL DEFAULT 0
  pizzas.deleted       INTEGER NOT NULL DEFAULT 0

Existing rows get sort_order 10, 20, 30... in today's (alphabetical) order, so nothing
moves until the owner reorders.

"Deleted" rows stay in the table because order history refers to them by id; they are
hidden everywhere except past orders. No data changes beyond the new columns.

Idempotent, online backup first, one transaction, foreign_key_check before commit.

Usage:  ./venv/bin/python migrate_005_order_and_delete.py [path/to/pizza.db]
"""
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

DEFAULT_DB = Path(__file__).resolve().parent / "pizza.db"
TABLES = ("toppings", "pizzas")


def fail(msg: str) -> None:
    print(f"ABORT: {msg}", file=sys.stderr)
    sys.exit(1)


def columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}


def main() -> None:
    db_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_DB
    if not db_path.exists():
        fail(f"{db_path} not found")
    conn = sqlite3.connect(db_path, isolation_level=None)
    conn.execute("PRAGMA foreign_keys = ON")
    try:
        if "sauce_id" not in columns(conn, "pizzas"):
            fail("migration 004 has not been applied to this database")
        have = {t: columns(conn, t) & {"sort_order", "deleted"} for t in TABLES}
        if all(len(h) == 2 for h in have.values()):
            print("Migration 005 already applied; nothing to do.")
            return
        if any(have.values()):
            fail(f"partly applied, unexpected columns: {have}")

        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_path = db_path.with_name(f"{db_path.name}.bak-{stamp}-pre005")
        with sqlite3.connect(backup_path) as dst:
            conn.backup(dst)
        print(f"Backup written: {backup_path}")

        conn.execute("BEGIN IMMEDIATE")
        try:
            for table in TABLES:
                conn.execute(f"ALTER TABLE {table} ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0")
                conn.execute(f"ALTER TABLE {table} ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0")
                ids = [r[0] for r in conn.execute(f"SELECT id FROM {table} ORDER BY name COLLATE NOCASE, id")]
                conn.executemany(f"UPDATE {table} SET sort_order = ? WHERE id = ?",
                                 [((i + 1) * 10, row_id) for i, row_id in enumerate(ids)])
                print(f"{table}: {len(ids)} row(s) numbered in alphabetical order")
            problems = conn.execute("PRAGMA foreign_key_check").fetchall()
            if problems:
                raise RuntimeError(f"foreign_key_check: {problems}")
            conn.execute("COMMIT")
        except Exception:
            conn.execute("ROLLBACK")
            raise
        integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            fail(f"integrity_check: {integrity} (restore from {backup_path})")
        print("Migration 005 applied.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
