#!/usr/bin/env python3
"""Migration 004: sauces, topping photos and styles, build-your-own / half-and-half items.

Adds:
  sauces (id, name UNIQUE, colour '#rrggbb' or '' for "no sauce", active, sort_order)
      seeded: Tomato, BBQ, Garlic & herb, Pesto, No sauce
  toppings.style       TEXT NOT NULL DEFAULT 'generic'  (how the app draws it on the pizza)
  toppings.image       BLOB      (owner-uploaded photo, ~256 px PNG/JPEG/WebP)
  toppings.image_type  TEXT      (its MIME type)
  toppings.image_hash  TEXT      (sha1, versions the image URL so phones cache it for ever)
  pizzas.sauce_id      -> sauces  (the pizza's default sauce; every existing pizza gets Tomato)
  favourites.sauce_id  -> sauces  (NULL = the pizza's default sauce)

Rebuilds order_items (SQLite can't relax NOT NULL in place) as:
  id, order_id, pizza_id NULL (NULL = build your own), sauce_id NULL (NULL = order placed
  before sauces existed), added_json, removed_json, toppings_json ('[{"id","side","extra"}]',
  build-your-own only). Existing rows are copied unchanged.

Data change: "Tomato" was a topping standing in for the sauce. It is taken off every
pizza's base set and switched off (not deleted: order history refers to it). The owner
can switch it back on in /admin, e.g. renamed "Fresh tomato", if sliced tomato is wanted.

Idempotent, online backup first, one transaction, foreign_key_check before commit.

Usage:  ./venv/bin/python migrate_004_sauces_photos_halves.py [path/to/pizza.db]
"""
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

DEFAULT_DB = Path(__file__).resolve().parent / "pizza.db"

SAUCES = [  # name, colour, sort_order
    ("Tomato", "#b5321e", 10),
    ("BBQ", "#5a1d0c", 20),
    ("Garlic & herb", "#efe4c6", 30),
    ("Pesto", "#5d7f2a", 40),
    ("No sauce", "", 90),
]

# Keep in step with guess_style() in main.py.
STYLE_WORDS = [
    ("pepperoni", "pepperoni"), ("salami", "pepperoni"), ("chorizo", "pepperoni"),
    ("mozzarella", "cheese"), ("cheese", "cheese"), ("cheddar", "cheese"),
    ("ham", "ham"), ("bacon", "ham"),
    ("mushroom", "mushroom"),
    ("onion", "onion"),
    ("pineapple", "pineapple"),
    ("chilli", "chilli"), ("chili", "chilli"), ("jalape", "chilli"),
    ("pepper", "pepper"),
    ("olive", "olive"),
    ("basil", "basil"), ("spinach", "basil"), ("rocket", "basil"), ("herb", "basil"),
    ("sweetcorn", "sweetcorn"), ("corn", "sweetcorn"),
    ("tomato", "tomato"),
    ("sausage", "sausage"), ("meatball", "sausage"),
    ("chicken", "chicken"),
]


def guess_style(name: str) -> str:
    lower = name.lower()
    return next((style for word, style in STYLE_WORDS if word in lower), "generic")


def fail(msg: str) -> None:
    print(f"ABORT: {msg}", file=sys.stderr)
    sys.exit(1)


def columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}


def main() -> None:
    db_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_DB
    if not db_path.is_file():
        fail(f"database not found: {db_path}")

    conn = sqlite3.connect(db_path, isolation_level=None)
    try:
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        if "sauces" in tables and "toppings_json" in columns(conn, "order_items"):
            print("Migration 004 already applied; nothing to do.")
            return
        if "sauces" in tables:
            fail("sauces exists but order_items was not rebuilt: half-applied? not touching it")
        expected = {
            "toppings": {"id", "name", "active"},
            "pizzas": {"id", "name", "description", "active"},
            "favourites": {"id", "user_id", "pizza_id", "label", "added_json", "removed_json"},
            "order_items": {"id", "order_id", "pizza_id", "added_json", "removed_json"},
        }
        for table, cols in expected.items():
            if columns(conn, table) != cols:
                fail(f"unexpected {table} columns {sorted(columns(conn, table))}; not touching it")

        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_path = db_path.with_name(f"{db_path.name}.bak-{stamp}-pre004")
        with sqlite3.connect(backup_path) as dst:
            conn.backup(dst)
        print(f"Backup written: {backup_path}")

        conn.execute("BEGIN IMMEDIATE")
        try:
            conn.execute("""
                CREATE TABLE sauces (
                  id         INTEGER PRIMARY KEY,
                  name       TEXT NOT NULL UNIQUE,
                  colour     TEXT NOT NULL DEFAULT '',
                  active     INTEGER NOT NULL DEFAULT 1,
                  sort_order INTEGER NOT NULL DEFAULT 50
                )""")
            conn.executemany("INSERT INTO sauces (name, colour, sort_order) VALUES (?, ?, ?)", SAUCES)
            tomato_sauce = conn.execute("SELECT id FROM sauces WHERE name = 'Tomato'").fetchone()[0]

            conn.execute("ALTER TABLE toppings ADD COLUMN style TEXT NOT NULL DEFAULT 'generic'")
            conn.execute("ALTER TABLE toppings ADD COLUMN image BLOB")
            conn.execute("ALTER TABLE toppings ADD COLUMN image_type TEXT")
            conn.execute("ALTER TABLE toppings ADD COLUMN image_hash TEXT")
            for topping_id, name in conn.execute("SELECT id, name FROM toppings").fetchall():
                conn.execute("UPDATE toppings SET style = ? WHERE id = ?", (guess_style(name), topping_id))

            conn.execute("ALTER TABLE pizzas ADD COLUMN sauce_id INTEGER REFERENCES sauces(id)")
            conn.execute("UPDATE pizzas SET sauce_id = ?", (tomato_sauce,))
            conn.execute("ALTER TABLE favourites ADD COLUMN sauce_id INTEGER REFERENCES sauces(id)")

            # The "Tomato" topping was the sauce: it moves to pizzas.sauce_id.
            row = conn.execute("SELECT id FROM toppings WHERE name = 'Tomato' COLLATE NOCASE").fetchone()
            if row:
                n = conn.execute("DELETE FROM pizza_toppings WHERE topping_id = ?", (row[0],)).rowcount
                conn.execute("UPDATE toppings SET active = 0 WHERE id = ?", (row[0],))
                print(f"Tomato topping (id {row[0]}) taken off {n} pizza(s) and switched off")

            conn.execute("""
                CREATE TABLE order_items_new (
                  id            INTEGER PRIMARY KEY,
                  order_id      INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
                  pizza_id      INTEGER REFERENCES pizzas(id),
                  sauce_id      INTEGER REFERENCES sauces(id),
                  added_json    TEXT NOT NULL DEFAULT '[]',
                  removed_json  TEXT NOT NULL DEFAULT '[]',
                  toppings_json TEXT NOT NULL DEFAULT '[]'
                )""")
            conn.execute("""
                INSERT INTO order_items_new (id, order_id, pizza_id, added_json, removed_json)
                SELECT id, order_id, pizza_id, added_json, removed_json FROM order_items""")
            before = conn.execute("SELECT count(*) FROM order_items").fetchone()[0]
            after = conn.execute("SELECT count(*) FROM order_items_new").fetchone()[0]
            if before != after:
                raise RuntimeError(f"order_items copy mismatch: {before} -> {after}")
            conn.execute("DROP TABLE order_items")
            conn.execute("ALTER TABLE order_items_new RENAME TO order_items")

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
        styles = conn.execute("SELECT name, style FROM toppings ORDER BY id").fetchall()
        print("Topping styles: " + ", ".join(f"{n}={s}" for n, s in styles))
        print(f"Migration 004 applied. order_items rows kept: {after}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
