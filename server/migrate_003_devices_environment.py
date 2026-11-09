#!/usr/bin/env python3
"""Migration 003: record which APNs environment a device token belongs to.

Tokens from builds run in Xcode only work against Apple's *sandbox* push
server; TestFlight/App Store tokens only against *production*. Adds:

  devices.environment TEXT NOT NULL DEFAULT 'production'
      CHECK (environment IN ('production', 'sandbox'))

Purely additive (ALTER TABLE ADD COLUMN). Idempotent, online backup first,
one transaction.

Usage:  ./venv/bin/python migrate_003_devices_environment.py [path/to/pizza.db]
"""
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

DEFAULT_DB = Path(__file__).resolve().parent / "pizza.db"

OLD_COLUMNS = {"id", "user_id", "token"}
NEW_COLUMNS = OLD_COLUMNS | {"environment"}


def fail(msg: str) -> None:
    print(f"ABORT: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    db_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_DB
    if not db_path.is_file():
        fail(f"database not found: {db_path}")

    conn = sqlite3.connect(db_path, isolation_level=None)
    try:
        cols = {row[1] for row in conn.execute("PRAGMA table_info(devices)")}
        if cols == NEW_COLUMNS:
            print("Migration 003 already applied; nothing to do.")
            return
        if cols != OLD_COLUMNS:
            fail(f"unexpected devices columns {sorted(cols)}; not touching it")

        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_path = db_path.with_name(f"{db_path.name}.bak-{stamp}-pre003")
        with sqlite3.connect(backup_path) as dst:
            conn.backup(dst)
        print(f"Backup written: {backup_path}")

        conn.execute("BEGIN IMMEDIATE")
        try:
            conn.execute(
                "ALTER TABLE devices ADD COLUMN environment TEXT NOT NULL DEFAULT 'production' "
                "CHECK (environment IN ('production', 'sandbox'))"
            )
            conn.execute("COMMIT")
        except Exception:
            conn.execute("ROLLBACK")
            raise

        integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            fail(f"integrity_check: {integrity} (restore from {backup_path})")
        cols = [row[1] for row in conn.execute("PRAGMA table_info(devices)")]
        print(f"Migration 003 applied. devices columns: {cols}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
