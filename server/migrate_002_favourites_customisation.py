#!/usr/bin/env python3
"""Migration 002: store the customisation on a favourite.

The original `favourites` table only had (user_id, pizza_id, label), so a
"pizza + customisation" favourite could not be saved. This adds the same two
columns `order_items` uses:

  added_json   TEXT NOT NULL DEFAULT '[]'   -- extra topping ids
  removed_json TEXT NOT NULL DEFAULT '[]'   -- base topping ids removed

Purely additive (ALTER TABLE ADD COLUMN, no rebuild). Idempotent, takes an
online backup first, runs in one transaction.

Usage:  ./venv/bin/python migrate_002_favourites_customisation.py [path/to/pizza.db]
"""
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

DEFAULT_DB = Path(__file__).resolve().parent / "pizza.db"

OLD_COLUMNS = {"id", "user_id", "pizza_id", "label"}
NEW_COLUMNS = OLD_COLUMNS | {"added_json", "removed_json"}


def fail(msg: str) -> None:
    print(f"ABORT: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    db_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_DB
    if not db_path.is_file():
        fail(f"database not found: {db_path}")

    conn = sqlite3.connect(db_path, isolation_level=None)
    try:
        cols = {row[1] for row in conn.execute("PRAGMA table_info(favourites)")}
        if cols == NEW_COLUMNS:
            print("Migration 002 already applied; nothing to do.")
            return
        if cols != OLD_COLUMNS:
            fail(f"unexpected favourites columns {sorted(cols)}; not touching it")

        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_path = db_path.with_name(f"{db_path.name}.bak-{stamp}-pre002")
        with sqlite3.connect(backup_path) as dst:
            conn.backup(dst)
        print(f"Backup written: {backup_path}")

        conn.execute("BEGIN IMMEDIATE")
        try:
            conn.execute("ALTER TABLE favourites ADD COLUMN added_json TEXT NOT NULL DEFAULT '[]'")
            conn.execute("ALTER TABLE favourites ADD COLUMN removed_json TEXT NOT NULL DEFAULT '[]'")
            conn.execute("COMMIT")
        except Exception:
            conn.execute("ROLLBACK")
            raise

        integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            fail(f"integrity_check: {integrity} (restore from {backup_path})")
        cols = [row[1] for row in conn.execute("PRAGMA table_info(favourites)")]
        print(f"Migration 002 applied. favourites columns: {cols}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
