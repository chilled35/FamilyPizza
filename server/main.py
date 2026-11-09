"""Family Pizza backend (FastAPI + SQLite). See HANDOFF.md for the API contract."""
import asyncio
import hashlib
import json
import logging
import os
import sqlite3
import threading
from collections import defaultdict
from pathlib import Path
from typing import Annotated, AsyncIterator, Iterator, Literal
from uuid import UUID

import httpx
from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Request, Response, status
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.sse import EventSourceResponse, ServerSentEvent
from pydantic import BaseModel, ConfigDict, Field, StringConstraints

import apns

APP_DIR = Path(__file__).resolve().parent
DB_PATH = Path(os.environ.get("PIZZA_DB", APP_DIR / "pizza.db"))

# App log lines (e.g. push results) go to stderr -> journald, alongside uvicorn's.
log = logging.getLogger("pizza")
if not log.handlers:
    _handler = logging.StreamHandler()
    _handler.setFormatter(logging.Formatter("%(levelname)s:     %(name)s: %(message)s"))
    log.addHandler(_handler)
    log.setLevel(logging.INFO)
    log.propagate = False

app = FastAPI(title="Family Pizza", version="0.9.0")


# --------------------------------------------------------------------------- db

def _connect() -> sqlite3.Connection:
    # check_same_thread=False: FastAPI may run a sync dependency and the sync
    # endpoint on different threadpool threads; each connection is still used
    # by one request at a time.
    conn = sqlite3.connect(DB_PATH, timeout=5, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def get_db() -> Iterator[sqlite3.Connection]:
    conn = _connect()
    try:
        yield conn
    finally:
        conn.close()


DB = Annotated[sqlite3.Connection, Depends(get_db)]


# ------------------------------------------------------------- live updates

class _KitchenHub:
    """Wakes every open /api/stream connection when kitchen orders change.

    In-process only: correct because the service runs a single uvicorn worker.
    `notify()` is called from sync endpoints (threadpool threads), so it hands
    the wake-up to each subscriber's event loop thread-safely.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._subscribers: dict[asyncio.Event, asyncio.AbstractEventLoop] = {}

    def subscribe(self) -> asyncio.Event:
        event = asyncio.Event()
        with self._lock:
            self._subscribers[event] = asyncio.get_running_loop()
        return event

    def unsubscribe(self, event: asyncio.Event) -> None:
        with self._lock:
            self._subscribers.pop(event, None)

    def notify(self) -> None:
        with self._lock:
            subscribers = list(self._subscribers.items())
        for event, loop in subscribers:
            try:
                loop.call_soon_threadsafe(event.set)
            except RuntimeError:  # loop already closed (shutdown)
                pass


kitchen_hub = _KitchenHub()


# ----------------------------------------------------------------------- models

Name = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=60)]
Description = Annotated[str, StringConstraints(strip_whitespace=True, max_length=300)]
HexColour = Annotated[str, StringConstraints(strip_whitespace=True, pattern=r"^(#[0-9a-fA-F]{6})?$")]

# How the iOS app draws a topping on its pizza picture. Keep in step with ToppingStyle in
# ios/FamilyPizza/PizzaArt.swift and the <select> in admin.html. Unknown styles draw as "generic".
TOPPING_STYLES = ("cheese", "pepperoni", "ham", "mushroom", "onion", "pepper", "pineapple",
                  "chilli", "olive", "basil", "sweetcorn", "tomato", "sausage", "chicken", "generic")
ToppingStyle = Literal[TOPPING_STYLES]
Side = Literal["whole", "left", "right"]  # where a topping goes
Amount = Annotated[int, Field(ge=0, le=2)]  # how much on one half: 0 none, 1 normal, 2 double
Levels = tuple[int, int]  # (left, right) amounts of one topping

BUILD_YOUR_OWN = "Build your own"


class _Body(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Topping(BaseModel):
    id: int
    name: str


class ToppingInfo(Topping):
    style: str
    image_url: str | None  # relative to the server, versioned (cache for ever); null = no photo yet


class ToppingWithStatus(ToppingInfo):
    active: bool


class Sauce(BaseModel):
    id: int
    name: str
    colour: str  # '#rrggbb' for the app's picture; '' = no sauce layer (e.g. "No sauce")


class SauceWithStatus(Sauce):
    active: bool


class BaseTopping(ToppingWithStatus):
    left: int   # amount on the left half: 0 none, 1 normal, 2 double (never 0 on both halves)
    right: int  # amount on the right half


class MenuPizza(BaseModel):
    id: int
    name: str
    description: str
    sauce: Sauce | None  # default sauce; the person may pick another
    toppings: list[BaseTopping]  # base toppings, once each; active=false means currently unavailable


class BaseToppingIn(_Body):
    id: int
    left: Amount = 1
    right: Amount = 1


class AdminPizza(MenuPizza):
    active: bool


class ToppingCreate(_Body):
    name: Name
    active: bool = True
    style: ToppingStyle | None = None  # None = guessed from the name


class ToppingUpdate(_Body):
    name: Name | None = None
    active: bool | None = None
    style: ToppingStyle | None = None


class SauceCreate(_Body):
    name: Name
    colour: HexColour = ""
    active: bool = True


class SauceUpdate(_Body):
    name: Name | None = None
    colour: HexColour | None = None
    active: bool | None = None


class ReorderBody(_Body):
    ids: list[int] = Field(max_length=1000)  # every non-deleted id, in the new order


class PizzaCreate(_Body):
    name: Name
    description: Description = ""
    active: bool = True
    toppings: list[BaseToppingIn] = Field(default_factory=list, max_length=100)
    sauce_id: int | None = None  # None = the first sauce in the list (Tomato)


class PizzaUpdate(_Body):
    name: Name | None = None
    description: Description | None = None
    active: bool | None = None
    toppings: list[BaseToppingIn] | None = Field(None, max_length=100)  # replaces the whole base-topping set
    sauce_id: int | None = None


# Identity: `uuid` is the keychain UUID from the iOS app. Any case is accepted;
# it is stored and returned canonical lowercase.
FirstName = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=40)]
Label = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=40)]
Note = Annotated[str, StringConstraints(strip_whitespace=True, max_length=200)]
ApnsToken = Annotated[str, StringConstraints(strip_whitespace=True, pattern=r"^[0-9a-fA-F]{64,200}$")]
OrderStatus = Literal["new", "preparing", "ready", "collected"]


class RegisterBody(_Body):
    uuid: UUID
    name: FirstName


class User(BaseModel):
    id: int
    uuid: str
    name: str
    created_at: str


class DeviceBody(_Body):
    uuid: UUID
    apns_token: ApnsToken
    # Builds run from Xcode get sandbox tokens; TestFlight/App Store builds get production ones.
    environment: Literal["production", "sandbox"] = "production"


class PlacedTopping(_Body):
    id: int
    side: Side = "whole"
    extra: bool = False


class Customisation(_Body):
    """One pizza in an order.

    Menu pizza: `pizza_id`, then either `added`/`removed` (changes to the recipe) or `toppings`
    (the whole pizza as it should be made, halves and doubles included); `sauce_id` omitted or
    null = the pizza's default.
    Build your own: `pizza_id` null, `sauce_id` required, `toppings` with a side each.
    """
    pizza_id: int | None = None
    sauce_id: int | None = None
    added: list[int] = Field(default_factory=list, max_length=20)    # extra toppings (may repeat a base topping = "extra")
    removed: list[int] = Field(default_factory=list, max_length=20)  # must be base toppings of the pizza
    toppings: list[PlacedTopping] = Field(default_factory=list, max_length=40)


class FavouriteCreate(_Body):
    """Menu pizza: `pizza_id` + added/removed or toppings, as in an order.
    Build your own: `pizza_id` null/omitted, `sauce_id` required, `toppings`."""
    uuid: UUID
    label: Label
    pizza_id: int | None = None
    sauce_id: int | None = None  # menu pizza: None = the pizza's default sauce
    added: list[int] = Field(default_factory=list, max_length=20)
    removed: list[int] = Field(default_factory=list, max_length=20)
    toppings: list[PlacedTopping] = Field(default_factory=list, max_length=40)  # instead of added/removed


class OrderCreate(_Body):
    uuid: UUID
    items: list[Customisation] = Field(min_length=1, max_length=20)
    note: Note = ""


class StatusBody(_Body):
    status: OrderStatus


class PlacedToppingOut(Topping):
    side: Side
    extra: bool


class ItemOut(BaseModel):
    pizza_id: int | None  # null = build your own
    pizza_name: str
    sauce: Sauce | None   # null only on orders placed before sauces existed (v0.5)
    added: list[Topping]
    removed: list[Topping]
    # Build your own, or a menu pizza whose halves/doubles can't be said with added/removed
    # (added/removed then approximate it for older clients). In the order they were added.
    toppings: list[PlacedToppingOut]


class FavouriteOut(ItemOut):
    id: int
    label: str
    sauce_id: int | None  # as saved: null = the pizza's default (`sauce` shows it resolved)
    available: bool  # false if the pizza is off the menu or a needed topping/sauce is unavailable


class OrderOut(BaseModel):
    id: int
    status: OrderStatus
    note: str
    created_at: str  # ISO 8601 UTC, e.g. 2026-11-08T20:55:14Z
    updated_at: str
    items: list[ItemOut]


class KitchenOrder(OrderOut):
    user_name: str


SuggestionName = Annotated[str, StringConstraints(strip_whitespace=True, max_length=40)]
SuggestionStatus = Literal["new", "added", "dismissed"]


class SuggestionCreate(_Body):
    """A build-your-own pizza sent to the owner as an idea for the menu."""
    uuid: UUID
    name: SuggestionName = ""  # what the sender calls it; may be empty
    sauce_id: int
    toppings: list[PlacedTopping] = Field(default_factory=list, max_length=40)


class SuggestionOut(BaseModel):
    id: int
    user_name: str
    name: str
    sauce: Sauce | None
    toppings: list[PlacedToppingOut]
    status: SuggestionStatus  # new -> added (became a menu pizza) or dismissed
    pizza_id: int | None      # the menu pizza it became
    created_at: str           # ISO 8601 UTC
    updated_at: str


class SuggestionUpdate(_Body):
    status: SuggestionStatus
    pizza_id: int | None = None  # with "added": the menu pizza it became


# ---------------------------------------------------------------------- helpers

# Keep in step with migrate_004_sauces_photos_halves.py.
_STYLE_WORDS = [
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
    return next((style for word, style in _STYLE_WORDS if word in lower), "generic")


def _name_taken(db: sqlite3.Connection, table: str, name: str, exclude_id: int | None = None) -> bool:
    # table is always a literal from this module, never user input
    row = db.execute(
        f"SELECT 1 FROM {table} WHERE name = ? COLLATE NOCASE AND id IS NOT ?"
        + (" AND deleted = 0" if table in ("toppings", "pizzas") else ""), (name, exclude_id)
    ).fetchone()
    return row is not None


def _next_sort_order(db: sqlite3.Connection, table: str) -> int:
    # table is always a literal from this module, never user input
    return db.execute(f"SELECT COALESCE(MAX(sort_order), 0) + 10 FROM {table} WHERE deleted = 0").fetchone()[0]


def _validate_base_toppings(db: sqlite3.Connection, toppings: list[BaseToppingIn]) -> list[BaseToppingIn]:
    ids = [t.id for t in toppings]
    if len(ids) != len(set(ids)):
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "A topping is listed more than once")
    if ids:
        marks = ",".join("?" * len(ids))
        found = {r[0] for r in db.execute(f"SELECT id FROM toppings WHERE deleted = 0 AND id IN ({marks})", ids)}
        missing = sorted(i for i in ids if i not in found)
        if missing:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, f"Unknown topping id(s): {missing}")
    empty = [t.id for t in toppings if t.left == 0 and t.right == 0]
    if empty:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT,
                            f"Topping id(s) {empty} on neither half: leave them out instead")
    return toppings


def _validate_sauce_id(db: sqlite3.Connection, sauce_id: int) -> int:
    if db.execute("SELECT 1 FROM sauces WHERE id = ?", (sauce_id,)).fetchone() is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, f"Unknown sauce id {sauce_id}")
    return sauce_id


def _default_sauce_id(db: sqlite3.Connection) -> int | None:
    row = db.execute("SELECT id FROM sauces ORDER BY sort_order, id LIMIT 1").fetchone()
    return row[0] if row else None


def _image_url(topping_id: int, image_hash: str | None) -> str | None:
    return f"/api/toppings/{topping_id}/image?v={image_hash[:12]}" if image_hash else None


# Never select toppings.image here: list queries must stay small.
_TOPPING_COLS = "id, name, active, style, image_hash"


def _topping_dict(r: sqlite3.Row) -> dict:
    return {"id": r["id"], "name": r["name"], "active": bool(r["active"]),
            "style": r["style"], "image_url": _image_url(r["id"], r["image_hash"])}


def _fetch_toppings(db: sqlite3.Connection, active_only: bool) -> list[dict]:
    sql = f"SELECT {_TOPPING_COLS} FROM toppings WHERE deleted = 0"
    if active_only:
        sql += " AND active = 1"
    sql += " ORDER BY sort_order, name COLLATE NOCASE"
    return [_topping_dict(r) for r in db.execute(sql)]


def _sauce_dict(r: sqlite3.Row) -> dict:
    return {"id": r["id"], "name": r["name"], "colour": r["colour"], "active": bool(r["active"])}


def _fetch_sauces(db: sqlite3.Connection, active_only: bool) -> list[dict]:
    sql = "SELECT id, name, colour, active FROM sauces"
    if active_only:
        sql += " WHERE active = 1"
    sql += " ORDER BY sort_order, name COLLATE NOCASE"
    return [_sauce_dict(r) for r in db.execute(sql)]


def _sauce_map(db: sqlite3.Connection) -> dict[int, dict]:
    return {s["id"]: s for s in _fetch_sauces(db, active_only=False)}


def _fetch_pizzas(db: sqlite3.Connection, active_only: bool, pizza_id: int | None = None) -> list[dict]:
    sql = "SELECT id, name, description, active, sauce_id FROM pizzas"
    where, args = ["deleted = 0"], []
    if active_only:
        where.append("active = 1")
    if pizza_id is not None:
        where.append("id = ?")
        args.append(pizza_id)
    sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY sort_order, name COLLATE NOCASE"
    pizzas = db.execute(sql, args).fetchall()

    base = defaultdict(list)
    for r in db.execute(
        "SELECT pt.pizza_id, pt.left_amount, pt.right_amount, t.id, t.name, t.active, t.style, t.image_hash "
        "FROM pizza_toppings pt JOIN toppings t ON t.id = pt.topping_id ORDER BY t.sort_order, t.name COLLATE NOCASE"
    ):
        base[r["pizza_id"]].append({**_topping_dict(r), "left": r["left_amount"], "right": r["right_amount"]})
    smap = _sauce_map(db)

    return [
        {
            "id": p["id"],
            "name": p["name"],
            "description": p["description"],
            "active": bool(p["active"]),
            "sauce": smap.get(p["sauce_id"]),
            "toppings": base[p["id"]],
        }
        for p in pizzas
    ]


def _get_topping(db: sqlite3.Connection, topping_id: int) -> dict:
    r = db.execute(f"SELECT {_TOPPING_COLS} FROM toppings WHERE id = ? AND deleted = 0", (topping_id,)).fetchone()
    if r is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Topping not found")
    return _topping_dict(r)


def _get_sauce(db: sqlite3.Connection, sauce_id: int) -> dict:
    r = db.execute("SELECT id, name, colour, active FROM sauces WHERE id = ?", (sauce_id,)).fetchone()
    if r is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Sauce not found")
    return _sauce_dict(r)


def _get_pizza(db: sqlite3.Connection, pizza_id: int) -> dict:
    rows = _fetch_pizzas(db, active_only=False, pizza_id=pizza_id)
    if not rows:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Pizza not found")
    return rows[0]


def _set_base_toppings(db: sqlite3.Connection, pizza_id: int, toppings: list[BaseToppingIn]) -> None:
    db.execute("DELETE FROM pizza_toppings WHERE pizza_id = ?", (pizza_id,))
    db.executemany(
        "INSERT INTO pizza_toppings (pizza_id, topping_id, left_amount, right_amount) VALUES (?, ?, ?, ?)",
        [(pizza_id, t.id, t.left, t.right) for t in toppings],
    )


# ------------------------------------------------------------------------ pages

@app.get("/", response_class=HTMLResponse, include_in_schema=False)
def home():
    return """<!doctype html>
<html><head><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Family Pizza</title></head>
<body style="font-family:system-ui;text-align:center;padding:3rem">
  <h1>🍕 Family Pizza</h1>
  <p><a href="/kitchen">Kitchen</a> · <a href="/admin">Menu admin</a> · <a href="/docs">API docs</a></p>
</body></html>"""


@app.get("/admin", include_in_schema=False)
def admin_page():
    return FileResponse(APP_DIR / "admin.html", media_type="text/html")


@app.get("/kitchen", include_in_schema=False)
def kitchen_page():
    return FileResponse(APP_DIR / "kitchen.html", media_type="text/html")


@app.get("/health", tags=["meta"])
def health():
    return {"status": "ok"}


# ----------------------------------------------------------------- public menu

@app.get("/api/menu", response_model=list[MenuPizza], tags=["menu"])
def get_menu(db: DB):
    """Active pizzas with their default sauce and base toppings (for the iOS menu)."""
    return _fetch_pizzas(db, active_only=True)


@app.get("/api/toppings", response_model=list[ToppingInfo], tags=["menu"])
def get_toppings(db: DB):
    """Active toppings (for the iOS customise and build-your-own screens)."""
    return _fetch_toppings(db, active_only=True)


@app.get("/api/sauces", response_model=list[Sauce], tags=["menu"])
def get_sauces(db: DB):
    """Active sauces, in the owner's order (Tomato first)."""
    return _fetch_sauces(db, active_only=True)


@app.get("/api/toppings/{topping_id}/image", tags=["menu"], response_class=Response,
         responses={200: {"content": {"image/png": {}, "image/jpeg": {}, "image/webp": {}}},
                    404: {"description": "No photo uploaded for this topping"}})
def topping_image(topping_id: int, db: DB, request: Request, v: str | None = None):
    """A topping's photo. Use the versioned `image_url` from the menu: that URL never changes
    content, so it is cacheable for ever. Works for switched-off toppings too (order history)."""
    r = db.execute("SELECT image, image_type, image_hash FROM toppings WHERE id = ?", (topping_id,)).fetchone()
    if r is None or r["image"] is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No photo for this topping")
    etag = f'"{r["image_hash"]}"'
    versioned = v is not None and r["image_hash"].startswith(v)
    headers = {"ETag": etag,
               "Cache-Control": "public, max-age=31536000, immutable" if versioned else "no-cache"}
    if request.headers.get("if-none-match") == etag:
        return Response(status_code=status.HTTP_304_NOT_MODIFIED, headers=headers)
    return Response(r["image"], media_type=r["image_type"], headers=headers)


# ------------------------------------------------------------------- admin API
# LAN-open in v1 (same trust model as the rest of the app). Deleting a pizza or topping
# only marks it deleted (order history refers to it by id): it disappears from the menu,
# the app and /admin, but past orders still show its name. Sauces can only be switched off.

@app.get("/api/admin/toppings", response_model=list[ToppingWithStatus], tags=["admin"])
def admin_list_toppings(db: DB):
    return _fetch_toppings(db, active_only=False)


@app.post("/api/admin/toppings", response_model=ToppingWithStatus,
          status_code=status.HTTP_201_CREATED, tags=["admin"])
def admin_create_topping(body: ToppingCreate, db: DB):
    if _name_taken(db, "toppings", body.name):
        raise HTTPException(status.HTTP_409_CONFLICT, f"Topping '{body.name}' already exists")
    style = body.style or guess_style(body.name)
    deleted = db.execute("SELECT id FROM toppings WHERE name = ? COLLATE NOCASE AND deleted = 1",
                         (body.name,)).fetchone()
    with db:
        order = _next_sort_order(db, "toppings")
        if deleted:
            # Names are unique, so adding a deleted topping again brings it back (photo included).
            db.execute("UPDATE toppings SET name = ?, active = ?, style = ?, deleted = 0, sort_order = ? "
                       "WHERE id = ?", (body.name, int(body.active), style, order, deleted["id"]))
            topping_id = deleted["id"]
        else:
            topping_id = db.execute("INSERT INTO toppings (name, active, style, sort_order) VALUES (?, ?, ?, ?)",
                                    (body.name, int(body.active), style, order)).lastrowid
    return _get_topping(db, topping_id)


@app.patch("/api/admin/toppings/{topping_id}", response_model=ToppingWithStatus, tags=["admin"])
def admin_update_topping(topping_id: int, body: ToppingUpdate, db: DB):
    _get_topping(db, topping_id)
    if body.name is not None and _name_taken(db, "toppings", body.name, exclude_id=topping_id):
        raise HTTPException(status.HTTP_409_CONFLICT, f"Topping '{body.name}' already exists")
    if body.name is not None and db.execute(
            "SELECT 1 FROM toppings WHERE name = ? COLLATE NOCASE AND deleted = 1 AND id != ?",
            (body.name, topping_id)).fetchone():
        raise HTTPException(status.HTTP_409_CONFLICT,
                            f"A deleted topping is called '{body.name}': add it as a new topping to bring it back")
    with db:
        if body.name is not None:
            db.execute("UPDATE toppings SET name = ? WHERE id = ?", (body.name, topping_id))
        if body.active is not None:
            db.execute("UPDATE toppings SET active = ? WHERE id = ?", (int(body.active), topping_id))
        if body.style is not None:
            db.execute("UPDATE toppings SET style = ? WHERE id = ?", (body.style, topping_id))
    return _get_topping(db, topping_id)


@app.delete("/api/admin/toppings/{topping_id}", status_code=status.HTTP_204_NO_CONTENT,
            response_class=Response, tags=["admin"])
def admin_delete_topping(topping_id: int, db: DB):
    """Delete a topping: it comes off every menu pizza's base toppings and out of every list.
    Past orders keep its name. Adding a topping with the same name later brings it back."""
    _get_topping(db, topping_id)
    with db:
        db.execute("DELETE FROM pizza_toppings WHERE topping_id = ?", (topping_id,))
        db.execute("UPDATE toppings SET deleted = 1, active = 0 WHERE id = ?", (topping_id,))
    return Response(status_code=status.HTTP_204_NO_CONTENT)


def _reorder(db: sqlite3.Connection, table: str, ids: list[int]) -> None:
    # table is always a literal from this module, never user input
    current = {r[0] for r in db.execute(f"SELECT id FROM {table} WHERE deleted = 0")}
    if len(ids) != len(set(ids)) or set(ids) != current:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT,
                            "Send every id exactly once (the list may have changed: reload the page)")
    with db:
        db.executemany(f"UPDATE {table} SET sort_order = ? WHERE id = ?",
                       [((i + 1) * 10, row_id) for i, row_id in enumerate(ids)])


@app.put("/api/admin/toppings/order", response_model=list[ToppingWithStatus], tags=["admin"])
def admin_reorder_toppings(body: ReorderBody, db: DB):
    """Set the topping order (as listed in the app): every topping id, first to last."""
    _reorder(db, "toppings", body.ids)
    return _fetch_toppings(db, active_only=False)


MAX_IMAGE_BYTES = 512 * 1024  # admin.html sends ~256 px images, typically 20-120 KB


def _sniff_image(data: bytes) -> str | None:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


def _store_topping_image(topping_id: int, data: bytes | None, mime: str | None) -> dict:
    conn = _connect()
    try:
        _get_topping(conn, topping_id)
        digest = hashlib.sha1(data).hexdigest() if data is not None else None
        with conn:
            conn.execute("UPDATE toppings SET image = ?, image_type = ?, image_hash = ? WHERE id = ?",
                         (data, mime, digest, topping_id))
        return _get_topping(conn, topping_id)
    finally:
        conn.close()


@app.put("/api/admin/toppings/{topping_id}/image", response_model=ToppingWithStatus, tags=["admin"],
         openapi_extra={"requestBody": {"required": True, "content": {
             "image/png": {"schema": {"type": "string", "format": "binary"}},
             "image/jpeg": {"schema": {"type": "string", "format": "binary"}},
             "image/webp": {"schema": {"type": "string", "format": "binary"}}}}})
async def admin_upload_topping_image(topping_id: int, request: Request):
    """Upload (or replace) a topping's photo: the raw PNG/JPEG/WebP bytes as the body, at most
    512 KB. The /admin page crops and shrinks photos to 256 px before sending."""
    data = bytearray()
    async for chunk in request.stream():
        data += chunk
        if len(data) > MAX_IMAGE_BYTES:
            raise HTTPException(status.HTTP_413_CONTENT_TOO_LARGE,
                                f"Photo too big (max {MAX_IMAGE_BYTES // 1024} KB)")
    mime = _sniff_image(bytes(data[:16]))
    if mime is None:
        raise HTTPException(status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, "Send a PNG, JPEG or WebP image")
    return await run_in_threadpool(_store_topping_image, topping_id, bytes(data), mime)


@app.delete("/api/admin/toppings/{topping_id}/image", response_model=ToppingWithStatus, tags=["admin"])
def admin_delete_topping_image(topping_id: int):
    """Remove a topping's photo (the app falls back to its drawn icon)."""
    return _store_topping_image(topping_id, None, None)


@app.get("/api/admin/sauces", response_model=list[SauceWithStatus], tags=["admin"])
def admin_list_sauces(db: DB):
    return _fetch_sauces(db, active_only=False)


@app.post("/api/admin/sauces", response_model=SauceWithStatus,
          status_code=status.HTTP_201_CREATED, tags=["admin"])
def admin_create_sauce(body: SauceCreate, db: DB):
    if _name_taken(db, "sauces", body.name):
        raise HTTPException(status.HTTP_409_CONFLICT, f"Sauce '{body.name}' already exists")
    with db:
        # New sauces go after the seeded ones but before "No sauce" (90).
        cur = db.execute("INSERT INTO sauces (name, colour, active, sort_order) VALUES (?, ?, ?, 60)",
                         (body.name, body.colour, int(body.active)))
    return _get_sauce(db, cur.lastrowid)


@app.patch("/api/admin/sauces/{sauce_id}", response_model=SauceWithStatus, tags=["admin"])
def admin_update_sauce(sauce_id: int, body: SauceUpdate, db: DB):
    _get_sauce(db, sauce_id)
    if body.name is not None and _name_taken(db, "sauces", body.name, exclude_id=sauce_id):
        raise HTTPException(status.HTTP_409_CONFLICT, f"Sauce '{body.name}' already exists")
    with db:
        for col in ("name", "colour"):
            val = getattr(body, col)
            if val is not None:
                db.execute(f"UPDATE sauces SET {col} = ? WHERE id = ?", (val, sauce_id))
        if body.active is not None:
            db.execute("UPDATE sauces SET active = ? WHERE id = ?", (int(body.active), sauce_id))
    return _get_sauce(db, sauce_id)


@app.get("/api/admin/pizzas", response_model=list[AdminPizza], tags=["admin"])
def admin_list_pizzas(db: DB):
    return _fetch_pizzas(db, active_only=False)


@app.get("/api/admin/pizzas/{pizza_id}", response_model=AdminPizza, tags=["admin"])
def admin_get_pizza(pizza_id: int, db: DB):
    return _get_pizza(db, pizza_id)


@app.post("/api/admin/pizzas", response_model=AdminPizza,
          status_code=status.HTTP_201_CREATED, tags=["admin"])
def admin_create_pizza(body: PizzaCreate, db: DB):
    if _name_taken(db, "pizzas", body.name):
        raise HTTPException(status.HTTP_409_CONFLICT, f"Pizza '{body.name}' already exists")
    toppings = _validate_base_toppings(db, body.toppings)
    sauce_id = _validate_sauce_id(db, body.sauce_id) if body.sauce_id is not None else _default_sauce_id(db)
    with db:
        cur = db.execute(
            "INSERT INTO pizzas (name, description, active, sauce_id, sort_order) VALUES (?, ?, ?, ?, ?)",
            (body.name, body.description, int(body.active), sauce_id, _next_sort_order(db, "pizzas")),
        )
        _set_base_toppings(db, cur.lastrowid, toppings)
    return _get_pizza(db, cur.lastrowid)


@app.patch("/api/admin/pizzas/{pizza_id}", response_model=AdminPizza, tags=["admin"])
def admin_update_pizza(pizza_id: int, body: PizzaUpdate, db: DB):
    _get_pizza(db, pizza_id)
    if body.name is not None and _name_taken(db, "pizzas", body.name, exclude_id=pizza_id):
        raise HTTPException(status.HTTP_409_CONFLICT, f"Pizza '{body.name}' already exists")
    toppings = None if body.toppings is None else _validate_base_toppings(db, body.toppings)
    if body.sauce_id is not None:
        _validate_sauce_id(db, body.sauce_id)
    with db:
        for col in ("name", "description", "sauce_id"):
            val = getattr(body, col)
            if val is not None:
                db.execute(f"UPDATE pizzas SET {col} = ? WHERE id = ?", (val, pizza_id))
        if body.active is not None:
            db.execute("UPDATE pizzas SET active = ? WHERE id = ?", (int(body.active), pizza_id))
        if toppings is not None:
            _set_base_toppings(db, pizza_id, toppings)
    return _get_pizza(db, pizza_id)


@app.delete("/api/admin/pizzas/{pizza_id}", status_code=status.HTTP_204_NO_CONTENT,
            response_class=Response, tags=["admin"])
def admin_delete_pizza(pizza_id: int, db: DB):
    """Delete a menu pizza. People's saved favourites of it go too (they could never be
    ordered again). Past orders keep its name."""
    _get_pizza(db, pizza_id)
    with db:
        db.execute("DELETE FROM favourites WHERE pizza_id = ?", (pizza_id,))
        db.execute("UPDATE pizzas SET deleted = 1, active = 0 WHERE id = ?", (pizza_id,))
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@app.put("/api/admin/pizzas/order", response_model=list[AdminPizza], tags=["admin"])
def admin_reorder_pizzas(body: ReorderBody, db: DB):
    """Set the menu order: every pizza id, first to last."""
    _reorder(db, "pizzas", body.ids)
    return _fetch_pizzas(db, active_only=False)


# ------------------------------------------------- identity / orders helpers

def _iso(ts: str) -> str:
    """SQLite datetime('now') (UTC, 'YYYY-MM-DD HH:MM:SS') -> ISO 8601 'YYYY-MM-DDTHH:MM:SSZ'."""
    return ts.replace(" ", "T") + "Z"


def _topping_map(db: sqlite3.Connection) -> dict[int, tuple[str, bool]]:
    return {r[0]: (r[1], bool(r[2])) for r in db.execute("SELECT id, name, active FROM toppings")}


def _pizza_map(db: sqlite3.Connection) -> dict[int, tuple[str, bool, int | None]]:
    """pizza id -> (name, active, default sauce id)"""
    return {r[0]: (r[1], bool(r[2]), r[3]) for r in db.execute("SELECT id, name, active, sauce_id FROM pizzas")}


def _base_map(db: sqlite3.Connection) -> defaultdict[int, dict[int, Levels]]:
    """pizza id -> {base topping id: (left, right) amounts}"""
    base = defaultdict(dict)
    for r in db.execute("SELECT pizza_id, topping_id, left_amount, right_amount FROM pizza_toppings"):
        base[r[0]][r[1]] = (r[2], r[3])
    return base


def _recipe(db: sqlite3.Connection, pizza_id: int) -> dict[int, Levels]:
    return {r[0]: (r[1], r[2]) for r in db.execute(
        "SELECT topping_id, left_amount, right_amount FROM pizza_toppings WHERE pizza_id = ?", (pizza_id,))}


def _check_halves(name: str, toppings: list[PlacedTopping], tmap: dict[int, tuple[str, bool]]) -> dict[int, Levels]:
    """Validate placed toppings; return {topping id: (left, right) amounts}.

    A topping may be listed once per half (e.g. double on the left, normal on the right),
    but no half twice: "whole" covers both halves.
    """
    unknown = sorted({t.id for t in toppings if t.id not in tmap})
    if unknown:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, f"{name}: unknown topping id(s) {unknown}")
    halves: dict[int, list[str]] = {}
    levels: dict[int, Levels] = {}
    for t in toppings:
        sides = ["left", "right"] if t.side == "whole" else [t.side]
        halves.setdefault(t.id, []).extend(sides)
        left, right = levels.get(t.id, (0, 0))
        amount = 2 if t.extra else 1
        levels[t.id] = (amount if "left" in sides else left, amount if "right" in sides else right)
    twice = sorted({tmap[i][0] for i, h in halves.items() if len(h) != len(set(h))})
    if twice:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT,
                            f"{name}: {', '.join(twice)} listed more than once for the same half")
    return levels


def _as_changes(recipe: dict[int, Levels], ordered: dict[int, Levels]) -> tuple[list[int], list[int], bool]:
    """A menu pizza made as `ordered` -> (added, removed, exact).

    exact: added/removed say it fully (left off, "+ X" all over, or a normal-all-over topping
    made double all over). Otherwise they only approximate it: removed = left off entirely,
    added = more of it on some half.
    """
    added, removed, exact = [], [], True
    for tid in recipe.keys() | ordered.keys():
        was, now = recipe.get(tid, (0, 0)), ordered.get(tid, (0, 0))
        if now == was:
            continue
        if now == (0, 0):
            removed.append(tid)
        elif was in ((0, 0), (1, 1)) and now == (was[0] + 1, was[1] + 1):
            added.append(tid)
        else:
            exact = False
            if now[0] > was[0] or now[1] > was[1]:
                added.append(tid)
    return sorted(added), sorted(removed), exact


def _user_row(db: sqlite3.Connection, uuid: UUID) -> sqlite3.Row | None:
    return db.execute(
        "SELECT id, device_uuid, name, created_at FROM users WHERE device_uuid = ?", (str(uuid),)
    ).fetchone()


def _require_user(db: sqlite3.Connection, uuid: UUID) -> int:
    row = _user_row(db, uuid)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Unknown device: call POST /api/register first")
    return row["id"]


def _check_item(
    db: sqlite3.Connection, item: Customisation, tmap: dict[int, tuple[str, bool]],
    smap: dict[int, dict], *, orderable: bool
) -> dict:
    """Validate one pizza; return it normalised as
    {pizza_id, sauce_id (resolved), added, removed, toppings} ready to store.

    422 for malformed input. With orderable=True also 409 if the pizza is off the
    menu or any topping or sauce it needs is unavailable (the app should refresh the menu).
    """
    if item.pizza_id is None:
        return _check_build_your_own(item, tmap, smap, orderable=orderable)

    pizza = db.execute("SELECT name, active, sauce_id FROM pizzas WHERE id = ?", (item.pizza_id,)).fetchone()
    if pizza is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, f"Unknown pizza id {item.pizza_id}")
    pname = pizza["name"]
    if item.sauce_id is not None and item.sauce_id not in smap:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, f"{pname}: unknown sauce id {item.sauce_id}")
    sauce_id = item.sauce_id if item.sauce_id is not None else pizza["sauce_id"]
    recipe = _recipe(db, item.pizza_id)
    toppings: list[dict] = []

    if item.toppings:
        # The whole pizza as it should be made. Stored as added/removed when they say it exactly,
        # so it reads (and favourites behave) like any other change to the recipe.
        if item.added or item.removed:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT,
                                f"{pname}: send `toppings` or `added`/`removed`, not both")
        ordered = _check_halves(pname, item.toppings, tmap)
        added, removed, exact = _as_changes(recipe, ordered)
        if not exact:
            toppings = [{"id": t.id, "side": t.side, "extra": t.extra} for t in item.toppings]
        needed = set(ordered)
    else:
        added, removed = sorted(set(item.added)), sorted(set(item.removed))
        unknown = [t for t in added + removed if t not in tmap]
        if unknown:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, f"{pname}: unknown topping id(s) {unknown}")
        not_base = [tmap[t][0] for t in removed if t not in recipe]
        if not_base:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT,
                                f"{pname}: can't remove {', '.join(not_base)} (not on this pizza)")
        both = [tmap[t][0] for t in added if t in set(removed)]
        if both:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT,
                                f"{pname}: {', '.join(both)} both added and removed")
        needed = set(added) | (set(recipe) - set(removed))

    if orderable:
        if not pizza["active"]:
            raise HTTPException(status.HTTP_409_CONFLICT, f"{pname} is not on the menu any more")
        off = sorted(tmap[t][0] for t in needed if not tmap[t][1])
        if sauce_id is not None and not smap[sauce_id]["active"]:
            off.append(smap[sauce_id]["name"])
        if off:
            raise HTTPException(status.HTTP_409_CONFLICT,
                                f"{pname}: {', '.join(off)} currently unavailable")
    return {"pizza_id": item.pizza_id, "sauce_id": sauce_id, "added": added, "removed": removed,
            "toppings": toppings}


def _check_build_your_own(item: Customisation, tmap: dict[int, tuple[str, bool]],
                          smap: dict[int, dict], *, orderable: bool) -> dict:
    name = BUILD_YOUR_OWN
    if item.added or item.removed:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT,
                            f"{name}: send `toppings`, not `added`/`removed`")
    if item.sauce_id is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, f"{name}: choose a sauce")
    if item.sauce_id not in smap:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, f"{name}: unknown sauce id {item.sauce_id}")
    ids = list(_check_halves(name, item.toppings, tmap))
    if orderable:
        off = sorted({tmap[i][0] for i in ids if not tmap[i][1]})
        if not smap[item.sauce_id]["active"]:
            off.append(smap[item.sauce_id]["name"])
        if off:
            raise HTTPException(status.HTTP_409_CONFLICT, f"{name}: {', '.join(off)} currently unavailable")
    return {"pizza_id": None, "sauce_id": item.sauce_id, "added": [], "removed": [],
            "toppings": [{"id": t.id, "side": t.side, "extra": t.extra} for t in item.toppings]}


def _expand(pmap, tmap, smap, pizza_id: int | None, sauce_id: int | None,
            added: list[int], removed: list[int], toppings: list[dict]) -> dict:
    def names(ids: list[int]) -> list[dict]:
        return [{"id": t, "name": tmap[t][0]} for t in ids if t in tmap]

    if pizza_id is None:
        pizza_name = BUILD_YOUR_OWN
    else:
        pizza_name = pmap[pizza_id][0] if pizza_id in pmap else f"Pizza #{pizza_id}"
    sauce = smap.get(sauce_id)
    return {
        "pizza_id": pizza_id,
        "pizza_name": pizza_name,
        "sauce": {k: sauce[k] for k in ("id", "name", "colour")} if sauce else None,
        "added": names(added),
        "removed": names(removed),
        "toppings": [{"id": t["id"], "name": tmap[t["id"]][0], "side": t["side"], "extra": t["extra"]}
                     for t in toppings if t["id"] in tmap],
    }


def _favourites(db: sqlite3.Connection, user_id: int) -> list[dict]:
    tmap, pmap, smap, base = _topping_map(db), _pizza_map(db), _sauce_map(db), _base_map(db)
    out = []
    for f in db.execute(
        "SELECT id, pizza_id, sauce_id, label, added_json, removed_json, toppings_json FROM favourites "
        "WHERE user_id = ? ORDER BY label COLLATE NOCASE, id",
        (user_id,),
    ):
        added, removed = json.loads(f["added_json"]), json.loads(f["removed_json"])
        toppings = json.loads(f["toppings_json"])
        if f["pizza_id"] is None:  # build your own: always on offer, made as saved
            on_menu, sauce_id = True, f["sauce_id"]
            needed, removable = {t["id"] for t in toppings}, True
        else:
            pizza = pmap.get(f["pizza_id"], ("", False, None))
            on_menu = pizza[1]
            sauce_id = f["sauce_id"] if f["sauce_id"] is not None else pizza[2]
            pbase = set(base[f["pizza_id"]])
            if toppings:  # saved with halves: made as saved, whatever the recipe says now
                needed, removable = {t["id"] for t in toppings}, True
            else:
                needed = set(added) | (pbase - set(removed))
                removable = set(removed) <= pbase  # owner may have changed the pizza since it was saved
        available = (
            on_menu
            and removable
            and all(tmap.get(t, ("", False))[1] for t in needed)
            and (sauce_id is None or smap.get(sauce_id, {"active": False})["active"])
        )
        out.append({**_expand(pmap, tmap, smap, f["pizza_id"], sauce_id, added, removed, toppings),
                    "id": f["id"], "label": f["label"], "sauce_id": f["sauce_id"],
                    "available": bool(available)})
    return out


def _load_orders(db: sqlite3.Connection, where: str, args: tuple, order_by: str,
                 limit: int | None = None) -> list[dict]:
    # where/order_by are always literals from this module, never user input
    sql = ("SELECT o.id, o.status, o.note, o.created_at, o.updated_at, u.name AS user_name "
           f"FROM orders o JOIN users u ON u.id = o.user_id WHERE {where} ORDER BY {order_by}")
    if limit:
        sql += f" LIMIT {int(limit)}"
    rows = db.execute(sql, args).fetchall()
    if not rows:
        return []
    ids = [r["id"] for r in rows]
    tmap, pmap, smap = _topping_map(db), _pizza_map(db), _sauce_map(db)
    items = defaultdict(list)
    for it in db.execute(
        f"SELECT order_id, pizza_id, sauce_id, added_json, removed_json, toppings_json FROM order_items "
        f"WHERE order_id IN ({','.join('?' * len(ids))}) ORDER BY id",
        ids,
    ):
        items[it["order_id"]].append(
            _expand(pmap, tmap, smap, it["pizza_id"], it["sauce_id"], json.loads(it["added_json"]),
                    json.loads(it["removed_json"]), json.loads(it["toppings_json"]))
        )
    return [
        {
            "id": r["id"],
            "status": r["status"],
            "note": r["note"],
            "created_at": _iso(r["created_at"]),
            "updated_at": _iso(r["updated_at"]),
            "user_name": r["user_name"],
            "items": items[r["id"]],
        }
        for r in rows
    ]


# --------------------------------------------------------- identity / devices

@app.post("/api/register", response_model=User, tags=["identity"],
          responses={201: {"model": User, "description": "User created"}})
def register(body: RegisterBody, db: DB, response: Response):
    """Create the user for this keychain UUID, or return the existing one.

    Idempotent on `uuid`: safe to call on every launch. If `name` differs from the
    stored one it is updated. 201 when created, 200 when it already existed.
    """
    with db:
        cur = db.execute(
            "INSERT INTO users (device_uuid, name) VALUES (?, ?) ON CONFLICT(device_uuid) DO NOTHING",
            (str(body.uuid), body.name),
        )
        if cur.rowcount == 1:
            response.status_code = status.HTTP_201_CREATED
        else:
            db.execute("UPDATE users SET name = ? WHERE device_uuid = ? AND name != ?",
                       (body.name, str(body.uuid), body.name))
    row = _user_row(db, body.uuid)
    return {"id": row["id"], "uuid": row["device_uuid"], "name": row["name"], "created_at": _iso(row["created_at"])}


@app.post("/api/devices", status_code=status.HTTP_204_NO_CONTENT, response_class=Response, tags=["identity"])
def register_device(body: DeviceBody, db: DB):
    """Store or refresh this phone's APNs token (hex). Call whenever iOS hands the app a token.

    `environment`: "sandbox" for builds installed from Xcode (development provisioning profile)
    and the simulator, "production" (default) for TestFlight/App Store builds. The iOS app reads
    this from its embedded provisioning profile. A user may have several devices. A token already
    stored under another user is moved to this one.
    """
    user_id = _require_user(db, body.uuid)
    with db:
        db.execute(
            "INSERT INTO devices (user_id, token, environment) VALUES (?, ?, ?) "
            "ON CONFLICT(token) DO UPDATE SET user_id = excluded.user_id, environment = excluded.environment",
            (user_id, body.apns_token.lower(), body.environment),
        )
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# ------------------------------------------------------------------ favourites

@app.get("/api/favourites", response_model=list[FavouriteOut], tags=["favourites"])
def list_favourites(uuid: UUID, db: DB):
    """This user's saved pizzas + customisations, sorted by label."""
    return _favourites(db, _require_user(db, uuid))


@app.post("/api/favourites", response_model=FavouriteOut, status_code=status.HTTP_201_CREATED,
          tags=["favourites"])
def create_favourite(body: FavouriteCreate, db: DB):
    """Save a menu pizza + customisation (and sauce; null = its default), or a build-your-own
    pizza (`pizza_id` null, `sauce_id` + `toppings`), under a label.
    409 if this user already has that label for that pizza (or for build your own)."""
    user_id = _require_user(db, body.uuid)
    item = Customisation(pizza_id=body.pizza_id, sauce_id=body.sauce_id, added=body.added, removed=body.removed,
                         toppings=body.toppings)
    checked = _check_item(db, item, _topping_map(db), _sauce_map(db), orderable=False)
    try:
        with db:
            cur = db.execute(
                "INSERT INTO favourites (user_id, pizza_id, sauce_id, label, added_json, removed_json, toppings_json) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (user_id, body.pizza_id, body.sauce_id, body.label,
                 json.dumps(checked["added"]), json.dumps(checked["removed"]), json.dumps(checked["toppings"])),
            )
    except sqlite3.IntegrityError:
        what = "a build-your-own favourite" if body.pizza_id is None else "a favourite"
        raise HTTPException(status.HTTP_409_CONFLICT,
                            f"You already have {what} called '{body.label}'"
                            + ("" if body.pizza_id is None else " for this pizza"))
    return next(f for f in _favourites(db, user_id) if f["id"] == cur.lastrowid)


@app.delete("/api/favourites/{favourite_id}", status_code=status.HTTP_204_NO_CONTENT,
            response_class=Response, tags=["favourites"])
def delete_favourite(favourite_id: int, uuid: UUID, db: DB):
    """Delete one of this user's favourites (`uuid` query parameter must own it)."""
    user_id = _require_user(db, uuid)
    with db:
        cur = db.execute("DELETE FROM favourites WHERE id = ? AND user_id = ?", (favourite_id, user_id))
    if cur.rowcount == 0:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Favourite not found")
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# ----------------------------------------------------------------- suggestions

def _load_suggestions(db: sqlite3.Connection, where: str, args: tuple) -> list[dict]:
    # where is always a literal from this module, never user input
    tmap, smap = _topping_map(db), _sauce_map(db)
    rows = db.execute(
        "SELECT s.id, s.name, s.sauce_id, s.toppings_json, s.status, s.pizza_id, s.created_at, s.updated_at, "
        f"u.name AS user_name FROM suggestions s JOIN users u ON u.id = s.user_id WHERE {where} "
        "ORDER BY s.id DESC LIMIT 200", args)
    out = []
    for r in rows:
        item = _expand({}, tmap, smap, None, r["sauce_id"], [], [], json.loads(r["toppings_json"]))
        out.append({"id": r["id"], "user_name": r["user_name"], "name": r["name"], "sauce": item["sauce"],
                    "toppings": item["toppings"], "status": r["status"], "pizza_id": r["pizza_id"],
                    "created_at": _iso(r["created_at"]), "updated_at": _iso(r["updated_at"])})
    return out


@app.post("/api/suggestions", response_model=SuggestionOut, status_code=status.HTTP_201_CREATED,
          tags=["suggestions"])
def create_suggestion(body: SuggestionCreate, db: DB):
    """Send a build-your-own pizza to the owner as an idea for the menu. It shows in /admin
    under Suggestions, where the owner can add it to the menu or dismiss it."""
    user_id = _require_user(db, body.uuid)
    item = Customisation(pizza_id=None, sauce_id=body.sauce_id, toppings=body.toppings)
    checked = _check_item(db, item, _topping_map(db), _sauce_map(db), orderable=False)
    with db:
        cur = db.execute("INSERT INTO suggestions (user_id, name, sauce_id, toppings_json) VALUES (?, ?, ?, ?)",
                         (user_id, body.name, checked["sauce_id"], json.dumps(checked["toppings"])))
    return _load_suggestions(db, "s.id = ?", (cur.lastrowid,))[0]


@app.get("/api/admin/suggestions", response_model=list[SuggestionOut], tags=["admin"])
def admin_list_suggestions(db: DB):
    """Menu suggestions from the app, newest first (the last 200)."""
    return _load_suggestions(db, "1 = 1", ())


@app.patch("/api/admin/suggestions/{suggestion_id}", response_model=SuggestionOut, tags=["admin"])
def admin_update_suggestion(suggestion_id: int, body: SuggestionUpdate, db: DB):
    """Mark a suggestion added (optionally with the menu pizza it became), dismissed, or new again."""
    if db.execute("SELECT 1 FROM suggestions WHERE id = ?", (suggestion_id,)).fetchone() is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Suggestion not found")
    pizza_id = body.pizza_id if body.status == "added" else None
    if pizza_id is not None and db.execute("SELECT 1 FROM pizzas WHERE id = ?", (pizza_id,)).fetchone() is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, f"Unknown pizza id {pizza_id}")
    with db:
        db.execute("UPDATE suggestions SET status = ?, pizza_id = ?, updated_at = datetime('now') WHERE id = ?",
                   (body.status, pizza_id, suggestion_id))
    return _load_suggestions(db, "s.id = ?", (suggestion_id,))[0]


# ---------------------------------------------------------------------- orders

@app.post("/api/orders", response_model=OrderOut, status_code=status.HTTP_201_CREATED, tags=["orders"])
def create_order(body: OrderCreate, db: DB):
    """Place an order (1-20 pizzas): menu pizzas and/or build-your-own (see `Customisation`).

    422 = malformed (unknown ids, removing a topping the pizza doesn't have, ...).
    409 = something is no longer available; the app should refresh /api/menu and retry.
    """
    user_id = _require_user(db, body.uuid)
    tmap, smap = _topping_map(db), _sauce_map(db)
    checked = [_check_item(db, item, tmap, smap, orderable=True) for item in body.items]
    with db:
        cur = db.execute("INSERT INTO orders (user_id, note) VALUES (?, ?)", (user_id, body.note))
        db.executemany(
            "INSERT INTO order_items (order_id, pizza_id, sauce_id, added_json, removed_json, toppings_json) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            [(cur.lastrowid, c["pizza_id"], c["sauce_id"], json.dumps(c["added"]), json.dumps(c["removed"]),
              json.dumps(c["toppings"])) for c in checked],
        )
    kitchen_hub.notify()
    return _load_orders(db, "o.id = ?", (cur.lastrowid,), "o.id")[0]


@app.get("/api/orders", response_model=list[OrderOut], tags=["orders"])
def list_orders(uuid: UUID, db: DB):
    """This user's 50 most recent orders, newest first (poll this for status)."""
    return _load_orders(db, "o.user_id = ?", (_require_user(db, uuid),), "o.id DESC", limit=50)


def _owned_order(order_id: int, uuid: UUID) -> int:
    """Dependency: 404 unless `uuid` placed this order (checked before a stream starts)."""
    conn = _connect()
    try:
        user_id = _require_user(conn, uuid)
        row = conn.execute("SELECT 1 FROM orders WHERE id = ? AND user_id = ?", (order_id, user_id)).fetchone()
    finally:
        conn.close()
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Order not found")
    return order_id


def _order_snapshot(order_id: int) -> dict | None:
    conn = _connect()
    try:
        rows = _load_orders(conn, "o.id = ?", (order_id,), "o.id")
        return rows[0] if rows else None
    finally:
        conn.close()


@app.get("/api/orders/{order_id}/stream", response_class=EventSourceResponse, tags=["orders"])
async def order_stream(order_id: Annotated[int, Depends(_owned_order)]) -> AsyncIterator[ServerSentEvent]:
    """Server-Sent Events for the iOS order tracker (`uuid` query parameter must own the order).

    Sends `event: order` (same shape as one entry of GET /api/orders) on connect and whenever
    the order changes, e.g. the kitchen taps Start / Ready. Ends after `collected`.
    Keep-alive comments every 15 s.
    """
    changed = kitchen_hub.subscribe()
    try:
        yield ServerSentEvent(comment="connected", retry=3000)
        last = None
        while True:
            changed.clear()
            order = await run_in_threadpool(_order_snapshot, order_id)
            if order is None:
                return
            order.pop("user_name", None)
            if order != last:
                yield ServerSentEvent(event="order", data=order)
                last = order
            if order["status"] == "collected":
                return
            await changed.wait()
    finally:
        kitchen_hub.unsubscribe(changed)


@app.get("/api/kitchen/orders", response_model=list[KitchenOrder], tags=["kitchen"])
def kitchen_orders(db: DB):
    """All orders not yet collected, oldest first."""
    return _load_orders(db, "o.status != 'collected'", (), "o.id")


@app.post("/api/orders/{order_id}/status", response_model=KitchenOrder, tags=["kitchen"])
def set_order_status(order_id: int, body: StatusBody, db: DB, background: BackgroundTasks):
    """Set an order's status (new / preparing / ready / collected).

    Any change is allowed, so a mis-tap can be undone. Setting the current status is a no-op.
    Changing *into* `ready` sends the "ready to collect" push to the orderer's phone(s),
    after the response (the kitchen never waits on Apple).
    """
    row = db.execute("SELECT status FROM orders WHERE id = ?", (order_id,)).fetchone()
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Order not found")
    if row["status"] != body.status:
        with db:
            db.execute("UPDATE orders SET status = ?, updated_at = datetime('now') WHERE id = ?",
                       (body.status, order_id))
        kitchen_hub.notify()
        if body.status == "ready":
            background.add_task(_push_order_ready, order_id)
    return _load_orders(db, "o.id = ?", (order_id,), "o.id")[0]


def _push_order_ready(order_id: int) -> None:
    """Background task: push "your pizza is ready" to every device of the order's user.

    Never raises: push problems are logged (journalctl -u pizza-app) and don't affect orders.
    Dead tokens (uninstalled app, wrong app) are deleted; the app re-registers on launch.
    """
    cfg = apns.load_config()
    if cfg is None:
        log.info("Order %s ready: push not configured, skipped", order_id)
        return
    conn = _connect()
    try:
        devices = conn.execute(
            "SELECT d.id, d.token, d.environment, u.name FROM orders o "
            "JOIN users u ON u.id = o.user_id JOIN devices d ON d.user_id = o.user_id WHERE o.id = ?",
            (order_id,),
        ).fetchall()
        if not devices:
            log.info("Order %s ready: user has no registered device, no push", order_id)
            return
        payload = {
            "aps": {
                "alert": {"title": "Your pizza is ready 🍕", "body": f"Order #{order_id} is ready to collect."},
                "sound": "default",
            },
            "order_id": order_id,
        }
        for d in devices:
            who = f"order {order_id} -> {d['name']} ({d['environment']} …{d['token'][-6:]})"
            try:
                result = apns.client.send(cfg, d["token"], d["environment"], payload,
                                          collapse_id=f"order-{order_id}", expires_in=3600)
            except httpx.HTTPError as e:
                log.warning("Push %s failed (network): %s", who, e)
                continue
            if result.ok:
                trace = f", apns-unique-id {result.unique_id}" if result.unique_id else ""
                log.info("Push %s sent (apns-id %s%s)", who, result.apns_id, trace)
            elif result.dead_token:
                with conn:
                    conn.execute("DELETE FROM devices WHERE id = ?", (d["id"],))
                hint = " (sandbox/production mix-up?)" if result.reason == "BadDeviceToken" else ""
                log.warning("Push %s rejected: %s %s%s; token removed", who, result.status, result.reason, hint)
            else:
                log.error("Push %s rejected: %s %s", who, result.status, result.reason)
    except Exception:  # noqa: BLE001 - a background task must never take anything else down
        log.exception("Push for order %s crashed", order_id)
    finally:
        conn.close()


def _kitchen_snapshot() -> list[dict]:
    conn = _connect()
    try:
        return _load_orders(conn, "o.status != 'collected'", (), "o.id")
    finally:
        conn.close()


@app.get("/api/stream", response_class=EventSourceResponse, tags=["kitchen"])
async def kitchen_stream() -> AsyncIterator[ServerSentEvent]:
    """Server-Sent Events for the kitchen dashboard.

    Sends `event: orders` with the full active-order list (same shape as
    GET /api/kitchen/orders) on connect and after every change. Keep-alive
    comments every 15 s. Browsers reconnect automatically (`retry: 3000`).
    """
    changed = kitchen_hub.subscribe()
    try:
        yield ServerSentEvent(comment="connected", retry=3000)
        while True:
            changed.clear()  # clear before reading, so a change during the read triggers another send
            orders = await run_in_threadpool(_kitchen_snapshot)
            yield ServerSentEvent(event="orders", data=orders)
            await changed.wait()
    finally:
        kitchen_hub.unsubscribe(changed)
