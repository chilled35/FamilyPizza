#!/usr/bin/env python3
"""Migration 001: switch `users` from username/password to keychain-UUID identity.

Old: id, name, username UNIQUE, pw_hash NOT NULL, is_admin, created_at
New: id, device_uuid UNIQUE, name, is_admin, created_at

SQLite cannot drop NOT NULL / UNIQUE in place, so the table is rebuilt using the
documented procedure (https://sqlite.org/lang_altertable.html#otheralter):
foreign keys off, create new table, drop old, rename new, foreign_key_check, commit.

Safety:
  * Idempotent: exits 0 without changes if already applied.
  * Refuses to run if `users` has any rows (there is no UUID to map them to).
  * Takes an online backup (sqlite3 backup API) next to the DB before changing anything.
  * The whole rebuild is a single transaction; any failure rolls back.

Usage:  ./venv/bin/python migrate_001_users_device_uuid.py [path/to/pizza.db]
"""
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

DEFAULT_DB = Path(__file__).resolve().parent / "pizza.db"

OLD_COLUMNS = {"id", "name", "username", "pw_hash", "is_admin", "created_at"}
NEW_COLUMNS = {"id", "device_uuid", "name", "is_admin", "created_at"}

CREATE_USERS_NEW = """
CREATE TABLE users_new (
  id          INTEGER PRIMARY KEY,
  device_uuid TEXT NOT NULL UNIQUE,
  name        TEXT NOT NULL,
  is_admin    INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL DEFAULT (datetime('now'))
)
"""


def fail(msg: str) -> None:
    print(f"ABORT: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    db_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_DB
    if not db_path.is_file():
        fail(f"database not found: {db_path}")

    conn = sqlite3.connect(db_path, isolation_level=None)  # manual transaction control
    try:
        cols = {row[1] for row in conn.execute("PRAGMA table_info(users)")}
        if cols == NEW_COLUMNS:
            print("Migration 001 already applied; nothing to do.")
            return
        if cols != OLD_COLUMNS:
            fail(f"unexpected users columns {sorted(cols)}; not touching it")

        n_users = conn.execute("SELECT COUNT(*) FROM users").fetchone()[0]
        if n_users:
            fail(f"users has {n_users} row(s); this migration only handles an empty table")

        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_path = db_path.with_name(f"{db_path.name}.bak-{stamp}-pre001")
        with sqlite3.connect(backup_path) as dst:
            conn.backup(dst)
        print(f"Backup written: {backup_path}")

        conn.execute("PRAGMA foreign_keys = OFF")  # must be outside a transaction
        conn.execute("BEGIN IMMEDIATE")
        try:
            conn.execute(CREATE_USERS_NEW)
            conn.execute("DROP TABLE users")
            conn.execute("ALTER TABLE users_new RENAME TO users")
            problems = conn.execute("PRAGMA foreign_key_check").fetchall()
            if problems:
                raise RuntimeError(f"foreign_key_check failed: {problems}")
            conn.execute("COMMIT")
        except Exception:
            conn.execute("ROLLBACK")
            raise
        finally:
            conn.execute("PRAGMA foreign_keys = ON")

        integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            fail(f"integrity_check: {integrity} (restore from {backup_path})")
        cols = [row[1] for row in conn.execute("PRAGMA table_info(users)")]
        print(f"Migration 001 applied. users columns: {cols}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
