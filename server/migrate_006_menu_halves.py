#!/usr/bin/env python3
"""Migration 006: half-and-half and double base toppings on menu pizzas.

Adds:
  pizza_toppings.left_amount   INTEGER NOT NULL DEFAULT 1  (0 none, 1 normal, 2 double)
  pizza_toppings.right_amount  INTEGER NOT NULL DEFAULT 1
  favourites.toppings_json     TEXT NOT NULL DEFAULT '[]'  (a favourite whose halves can't be
                                                            said with added/removed:
                                                            [{"id", "side", "extra"}])

Every existing base topping becomes normal on both halves, which is what it meant before.
No other data changes.

Idempotent, online backup first, one transaction, foreign_key_check before commit.

Usage:  ./venv/bin/python migrate_006_menu_halves.py [path/to/pizza.db]
"""
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

DEFAULT_DB = Path(__file__).resolve().parent / "pizza.db"
AMOUNT = "INTEGER NOT NULL DEFAULT 1 CHECK ({col} BETWEEN 0 AND 2)"


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
        if "sort_order" not in columns(conn, "pizzas"):
            fail("migration 005 has not been applied to this database")
        new = {
            "pizza_toppings": columns(conn, "pizza_toppings") & {"left_amount", "right_amount"},
            "favourites": columns(conn, "favourites") & {"toppings_json"},
        }
        if len(new["pizza_toppings"]) == 2 and len(new["favourites"]) == 1:
            print("Migration 006 already applied; nothing to do.")
            return
        if any(new.values()):
            fail(f"partly applied, unexpected columns: {new}")
        if columns(conn, "pizza_toppings") != {"pizza_id", "topping_id"}:
            fail(f"unexpected pizza_toppings columns {sorted(columns(conn, 'pizza_toppings'))}; not touching it")

        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_path = db_path.with_name(f"{db_path.name}.bak-{stamp}-pre006")
        with sqlite3.connect(backup_path) as dst:
            conn.backup(dst)
        print(f"Backup written: {backup_path}")

        conn.execute("BEGIN IMMEDIATE")
        try:
            for col in ("left_amount", "right_amount"):
                conn.execute(f"ALTER TABLE pizza_toppings ADD COLUMN {col} {AMOUNT.format(col=col)}")
            conn.execute("ALTER TABLE favourites ADD COLUMN toppings_json TEXT NOT NULL DEFAULT '[]'")
            n = conn.execute("SELECT count(*) FROM pizza_toppings").fetchone()[0]
            print(f"pizza_toppings: {n} row(s), all normal on both halves")
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
        print("Migration 006 applied.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
