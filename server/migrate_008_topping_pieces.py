#!/usr/bin/env python3
"""Migration 008: owner-uploaded topping pieces.

Adds:
  toppings.piece_count  INTEGER NOT NULL DEFAULT 0  (how many pieces; 0 = no pieces sheet)
  toppings.pieces_hash  TEXT  (sha1 over all the pieces, versions the piece URLs)
  topping_pieces (topping_id -> toppings, n 1.., image BLOB PNG ~144 px, PRIMARY KEY (topping_id, n))
      the pieces cut from a "pieces sheet" the owner uploaded in /admin; the app scatters
      them on its pizza picture instead of the bundled pieces for that topping.

No data changes. Idempotent, online backup first, one transaction, foreign_key_check before commit.

Usage:  ./venv/bin/python migrate_008_topping_pieces.py [path/to/pizza.db]
"""
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

DEFAULT_DB = Path(__file__).resolve().parent / "pizza.db"


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
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        if "suggestions" not in tables:
            fail("migration 007 has not been applied to this database")
        tcols = columns(conn, "toppings")
        done = {"piece_count" in tcols, "pieces_hash" in tcols, "topping_pieces" in tables}
        if done == {True}:
            print("Migration 008 already applied; nothing to do.")
            return
        if done == {True, False}:
            fail("partly applied (toppings.piece_count / pieces_hash / topping_pieces): not touching it")

        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_path = db_path.with_name(f"{db_path.name}.bak-{stamp}-pre008")
        with sqlite3.connect(backup_path) as dst:
            conn.backup(dst)
        print(f"Backup written: {backup_path}")

        conn.execute("BEGIN IMMEDIATE")
        try:
            conn.execute("ALTER TABLE toppings ADD COLUMN piece_count INTEGER NOT NULL DEFAULT 0")
            conn.execute("ALTER TABLE toppings ADD COLUMN pieces_hash TEXT")
            conn.execute("""
                CREATE TABLE topping_pieces (
                  topping_id INTEGER NOT NULL REFERENCES toppings(id) ON DELETE CASCADE,
                  n          INTEGER NOT NULL,
                  image      BLOB NOT NULL,
                  PRIMARY KEY (topping_id, n)
                )""")
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
        print("Migration 008 applied.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
