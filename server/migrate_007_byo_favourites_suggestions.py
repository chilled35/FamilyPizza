#!/usr/bin/env python3
"""Migration 007: build-your-own favourites and menu suggestions.

Rebuilds favourites (SQLite can't relax NOT NULL in place) so pizza_id may be NULL
(= a build-your-own favourite: sauce_id + toppings_json). Existing rows are copied
unchanged. A partial unique index keeps build-your-own labels unique per person
(the table's UNIQUE (user_id, pizza_id, label) treats NULL pizza_ids as all different).

Adds:
  suggestions (id, user_id, name, sauce_id, toppings_json '[{"id","side","extra"}]',
               status new|added|dismissed, pizza_id (the menu pizza it became),
               created_at, updated_at)
      a build-your-own pizza someone sent from the app for the owner to consider.

Idempotent, online backup first, one transaction, foreign_key_check before commit.

Usage:  ./venv/bin/python migrate_007_byo_favourites_suggestions.py [path/to/pizza.db]
"""
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

DEFAULT_DB = Path(__file__).resolve().parent / "pizza.db"
FAVOURITE_COLS = ["id", "user_id", "pizza_id", "label", "added_json", "removed_json", "sauce_id", "toppings_json"]


def fail(msg: str) -> None:
    print(f"ABORT: {msg}", file=sys.stderr)
    sys.exit(1)


def columns(conn: sqlite3.Connection, table: str) -> dict[str, sqlite3.Row]:
    return {row[1]: row for row in conn.execute(f"PRAGMA table_info({table})")}


def main() -> None:
    db_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_DB
    if not db_path.exists():
        fail(f"{db_path} not found")
    conn = sqlite3.connect(db_path, isolation_level=None)
    conn.execute("PRAGMA foreign_keys = ON")
    try:
        fav = columns(conn, "favourites")
        if "toppings_json" not in fav:
            fail("migration 006 has not been applied to this database")
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        pizza_nullable = fav["pizza_id"][3] == 0  # PRAGMA table_info: notnull flag
        if "suggestions" in tables and pizza_nullable:
            print("Migration 007 already applied; nothing to do.")
            return
        if "suggestions" in tables or pizza_nullable:
            fail("partly applied (suggestions table / nullable favourites.pizza_id): not touching it")
        if sorted(fav) != sorted(FAVOURITE_COLS):
            fail(f"unexpected favourites columns {sorted(fav)}; not touching it")

        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_path = db_path.with_name(f"{db_path.name}.bak-{stamp}-pre007")
        with sqlite3.connect(backup_path) as dst:
            conn.backup(dst)
        print(f"Backup written: {backup_path}")

        cols = ", ".join(FAVOURITE_COLS)
        conn.execute("BEGIN IMMEDIATE")
        try:
            conn.execute("""
                CREATE TABLE favourites_new (
                  id            INTEGER PRIMARY KEY,
                  user_id       INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                  pizza_id      INTEGER REFERENCES pizzas(id) ON DELETE CASCADE,
                  label         TEXT NOT NULL DEFAULT '',
                  added_json    TEXT NOT NULL DEFAULT '[]',
                  removed_json  TEXT NOT NULL DEFAULT '[]',
                  sauce_id      INTEGER REFERENCES sauces(id),
                  toppings_json TEXT NOT NULL DEFAULT '[]',
                  UNIQUE (user_id, pizza_id, label)
                )""")
            conn.execute(f"INSERT INTO favourites_new ({cols}) SELECT {cols} FROM favourites")
            before = conn.execute("SELECT count(*) FROM favourites").fetchone()[0]
            after = conn.execute("SELECT count(*) FROM favourites_new").fetchone()[0]
            if before != after:
                raise RuntimeError(f"favourites copy mismatch: {before} -> {after}")
            conn.execute("DROP TABLE favourites")
            conn.execute("ALTER TABLE favourites_new RENAME TO favourites")
            conn.execute("CREATE UNIQUE INDEX favourites_byo_label ON favourites (user_id, label) "
                         "WHERE pizza_id IS NULL")
            conn.execute("""
                CREATE TABLE suggestions (
                  id            INTEGER PRIMARY KEY,
                  user_id       INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                  name          TEXT NOT NULL DEFAULT '',
                  sauce_id      INTEGER REFERENCES sauces(id),
                  toppings_json TEXT NOT NULL DEFAULT '[]',
                  status        TEXT NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'added', 'dismissed')),
                  pizza_id      INTEGER REFERENCES pizzas(id),
                  created_at    TEXT NOT NULL DEFAULT (datetime('now')),
                  updated_at    TEXT NOT NULL DEFAULT (datetime('now'))
                )""")
            print(f"favourites: {after} row(s) kept; suggestions table created")
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
        print("Migration 007 applied.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
