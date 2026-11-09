# Family Pizza — Build Handoff for Claude Code

> **Purpose of this file:** detailed build brief so Claude Code can continue this project without re-deriving anything. Read `claude.md` first for the high-level decisions, then this for the concrete build state and the work remaining.
> **Author:** handed off from a Claude chat session. **Date:** 2026-11-08.
> **You are here:** server foundation is live and running as a service with starter data in the DB. Next work = app logic (identity, menu API, ordering, kitchen dashboard), then the iOS app.

---

## 1. What we're building

A **home-LAN-only** pizza-ordering system for one family:

- Family order from a **custom iPhone app** (SwiftUI, distributed via TestFlight, rebuilt ~every 90 days).
- Orders land on a **kitchen iPad** web dashboard where the owner reviews them and advances status.
- Owner can **push a notification back** to the orderer's phone ("ready for collection") via APNs.
- Owner maintains the **menu** (pizzas) and **topping list**; family **customise** (add/remove toppings) and save **favourites**.

The iPhone app is **hard-coded to talk to `http://192.168.0.50:8000`** (the server below). No internet-facing exposure; the only outbound internet need is the server → Apple APNs for push.

---

## 2. As-built environment (verified live, do not assume — this is real)

**Proxmox host** (`ha`): pve-manager 8.4.16, Intel i3-6100T (4 threads), 15 GB RAM. Also runs **VM 100 = Home Assistant (HAOS 17.0)** at `192.168.0.210:8123` — **leave it alone**.

**Pizza container — LXC CT 101:**
- Hostname `pizza-app`, Debian 13.6, unprivileged, nesting on, 2 cores / 2 GB RAM / 512 MB swap / 8 GB disk on `local-lvm`, starts on boot.
- Static IP **192.168.0.50/24**, gw/DNS `192.168.0.1`, bridge `vmbr0`.
- ⚠️ **TODO:** add a DHCP reservation for `.50` on the router to pin it permanently.

**App runtime (inside CT 101):**
- Path: `/opt/pizza-app/`
- Python **3.13.5**, venv at `/opt/pizza-app/venv`
- Installed: FastAPI **0.162.2**, uvicorn **0.54.0**, pydantic **2.14.3** (plus fastapi-cli etc.); for APNs (v0.5.0): httpx[http2] **0.28.1**, h2 **4.4.1**, PyJWT[crypto] **2.15.1**, cryptography **50.0.2**. Pinned in `requirements.txt`.
- DB: **SQLite 3.46.1**, file `/opt/pizza-app/pizza.db`
- `unattended-upgrades` enabled (OS self-patches).

**systemd service** `/etc/systemd/system/pizza-app.service` → runs `uvicorn main:app --host 0.0.0.0 --port 8000`, `Restart=always`, enabled on boot. Currently **active**.

**Reachable now:** `http://192.168.0.50:8000/` (placeholder page), `/health` → `{"status":"ok"}`, `/docs` (auto OpenAPI — use this to build the iOS client).

**Current files in `/opt/pizza-app/`** (checked 2026-11-09 16:45):
- Code: `main.py` (API v0.9.0), `apns.py`, `apns_check.py`, `kitchen.html`, `admin.html`, `schema.sql`, `requirements.txt`.
- Migrations: `migrate_001_users_device_uuid.py`, `migrate_002_favourites_customisation.py`, `migrate_003_devices_environment.py`, `migrate_004_sauces_photos_halves.py`, `migrate_005_order_and_delete.py`, `migrate_006_menu_halves.py`, `migrate_007_byo_favourites_suggestions.py`.
- Rollback copies: `main.py.v0.8.0` + `admin.html.v0.8.1` (with the cheese section) + `schema.sql.v0.8`, `admin.html.v0.8.0` (before the cheese section), `main.py.v0.7.0` + `admin.html.v0.7` + `kitchen.html.v0.7` + `schema.sql.v0.7`, `main.py.v0.6.0` + `admin.html.v0.6` + `kitchen.html.v0.6` + `schema.sql.v0.6`, `main.py.v0.5.1` + `admin.html.v0.5` + `kitchen.html.v0.5` + `schema.sql.v0.5`, `main.py.v0.5.0` + `apns.py.v0.5.0`, `main.py.v0.4.0`, `main.py.v0.2.0`.
- Data: `pizza.db`, plus `pizza.db.bak-*-pre001/-pre002/-pre003/-pre004/-pre005/-pre006/-pre007` migration backups.
- `staging-v060/`, `staging-v070/`, `staging-v080/`, `staging-v090/`: each release's files as copied before go-live (same checksums as went live); safe to delete.
- `venv/`.

APNs config lives outside the app directory, in `/etc/pizza-app/` (§6).

**Source of truth:** `~/Developer/pizza-app/server/` on Jason's Mac. Claude Code runs there, *not* on the container. Deploy route: `scp` straight to the container as `pizza`, then a restart (see Working method below).

### Working method (important)
- **Updated 2026-11-08.** Claude Code runs on Jason's Mac. It deploys to CT 101 itself over SSH as the unprivileged user **`pizza`** (Mac alias `ssh pizza`, key `~/.ssh/pizza_deploy`).
  - `pizza` owns `/opt/pizza-app`, and the service runs as `pizza` (drop-in `/etc/systemd/system/pizza-app.service.d/user.conf`).
  - Its only sudo right is `systemctl restart pizza-app` (`/etc/sudoers.d/pizza`). It is in `systemd-journal`, so it can read logs.
  - Deploy: `scp server/<files> pizza:/opt/pizza-app/ && ssh pizza 'sudo systemctl restart pizza-app'`.
  - Claude still says so **before** any migration or other destructive step.
  - Live checks after a deploy use `curl`, file checksums, `ssh pizza` and `journalctl` only. Claude doesn't run JavaScript in the built-in browser on `192.168.0.50`, because each call asks Jason for approval. Click-through and console checks happen on a local server (`localhost:8765`) with the same files before deploying.
- **Snapshots (since 2026-11-09):** Claude takes CT 101 snapshots itself through the Proxmox API, with a token that can only snapshot CT 101.
  - Proxmox user `claude@pve`, role `PizzaSnapshot` (`VM.Snapshot`, `VM.Audit`) on `/vms/101` only; token `claude@pve!snap` (no privilege separation, so it has exactly the user's rights).
  - On the Mac: `~/.config/pizza/pve-token` (mode 600, one `Authorization: PVEAPIToken=…` header line; never print it) and `~/.config/pizza/pve-pin` (the host certificate's public-key pin; the certificate is self-signed).
  - Take one: `curl -s --insecure --pinnedpubkey "$(cat ~/.config/pizza/pve-pin)" -H @$HOME/.config/pizza/pve-token -X POST --data-urlencode snapname=pre_vXYZ https://192.168.0.196:8006/api2/json/nodes/ha/lxc/101/snapshot` (`--insecure` only skips the CA check; the pin still has to match). GET the same URL to list them.
  - `VM.Snapshot` also allows deleting CT 101 snapshots; Claude only ever creates. It cannot roll back (`VM.Snapshot.Rollback` not granted): restores stay Jason's. To revoke: delete user `claude@pve` in Proxmox.
- Claude does **not** log into the Proxmox host. Jason runs the host-side and root-side work: rollbacks, backups, `apt`, and service or unit changes.
- When giving Jason commands, label **each block** with where it runs (Mac / Proxmox host `root@ha` / container `root@pizza-app`) and how to get there (`pct enter 101` from the host, `exit` to leave). Don't assume he knows his way around Proxmox.
- Jason is a very experienced infra engineer but new to Proxmox specifically; he's comfortable with the shell, Macs, Python-adjacent work, and has an **Apple Developer account**.
- He prefers: correct-first-time, terse comms, direct action over asking, candour over false confidence.

---

## 3. Database schema (already created)

Full DDL is in `/opt/pizza-app/schema.sql`. Tables: `users`, `toppings`, `pizzas`, `pizza_toppings`, `favourites`, `orders`, `order_items`, `devices`. Starter data loaded: 12 toppings, 2 pizzas (Margherita, Pepperoni) with base toppings.

**Identity model (confirmed decision — build to this):**
Hybrid. On first launch the iOS app:
1. Generates a **UUID** and stores it in the **iOS keychain** (survives TestFlight reinstalls; does NOT use `identifierForVendor`, which resets on reinstall).
2. Asks the user for their **first name** (friendly label only).
3. Registers both with the server.

Server identifies a device/user by the **keychain UUID**, not by name and not by any Apple-provided hardware ID. No PINs, no passwords, no login screen after first launch. Identity = possession of the phone (acceptable for a family app — documented, not accidental).

> **Schema decision (resolved 2026-11-08):** option (b), done cleanly: `users` rebuilt as
> `id, device_uuid TEXT NOT NULL UNIQUE, name TEXT NOT NULL, is_admin INTEGER NOT NULL DEFAULT 0, created_at`.
> `username` and `pw_hash` are **dropped**, not kept nullable. SQLite can't relax `NOT NULL`/`UNIQUE` in place, so a table rebuild was needed either way, and dead password columns would only mislead. Option (a) was rejected because storing a UUID in a column named `username` is misleading.
> - Migration: `migrate_001_users_device_uuid.py`. It is idempotent, refuses to run if `users` has rows (it had 0), writes an online backup `pizza.db.bak-<ts>-pre001` first, and does the rebuild in one transaction with `foreign_key_check`.
> - `schema.sql` is updated to the new shape for fresh installs.
> - `device_uuid` is stored canonical **lowercase**. iOS `uuidString` is uppercase, so the step-3 endpoints (`/api/register` etc.) must normalise every incoming uuid with `str(uuid.UUID(value))`.
> - `is_admin` is kept but unused. The admin page and API are **LAN-open in v1**, the same trust model as the rest of the app.
> - The `devices` table (user_id → token) is for **APNs tokens**, separate from the identity UUID.

---

## 4. API to build (contract)

FastAPI, JSON, served from the same app that serves the kitchen dashboard. Suggested endpoints (adjust as sensible, keep `/docs` accurate):

> **Built, v0.3.0 (2026-11-08):** everything below except SSE and the APNs push. Shared conventions:
> - `uuid` is accepted in any case and stored and returned lowercase.
> - An unknown `uuid` gets **404** "call /api/register first".
> - **422** means a malformed request. **409** means "no longer available" (the app should refresh `/api/menu` and retry).
> - Timestamps are ISO 8601 UTC (`2026-11-08T21:03:34Z`).
> - Bodies use pydantic `extra="forbid"`.

**Identity / device**
- `POST /api/register` — body `{ uuid, name }` → creates/returns user. Idempotent on `uuid`. 201 when created, 200 when it already existed; a changed `name` is updated. Safe to call on every launch.
- `POST /api/devices` — body `{ uuid, apns_token, environment? }` → store/refresh APNs token for push. Returns 204. A user can have several devices; a token already stored under another user is moved to this one.
  - `apns_token` is hex, 64–200 chars.
  - `environment` is `"production"` (the default; TestFlight/App Store builds) or `"sandbox"` (builds run from Xcode). The iOS app must send `"sandbox"` in DEBUG builds, or its pushes are rejected and the token deleted (§6). Added in v0.5.0 with migration 003.

**Menu (read for app, write for admin)**: ✅ built (v0.2.0)
- `GET /api/menu`: active pizzas, sorted by name, as `{id, name, description, toppings:[{id, name, active}]}`. A base topping's `active=false` means it's currently unavailable (the app should show it struck through or block it).
- `GET /api/toppings`: active toppings `[{id, name}]`, for the customise screen.
- Admin (owner, LAN-open), all JSON with pydantic `extra="forbid"`:
  - `GET/POST /api/admin/toppings`, `PATCH /api/admin/toppings/{id}` `{name?, active?}`
  - `GET/POST /api/admin/pizzas`, `GET/PATCH /api/admin/pizzas/{id}` `{name?, description?, active?, topping_ids?}`. `topping_ids` replaces the whole base set.
  - Names are trimmed, 1–60 chars, unique case-insensitively (409 on a clash). Unknown topping ids give 422.
  - **No deletes by design.** Order history references pizzas and toppings, so deactivate instead.
- `GET /admin`: the owner's web page (`admin.html`). Add, rename and toggle toppings; create and edit pizzas with base-topping checkboxes. Works on iPad and phone, light and dark.

**Favourites**
- `GET /api/favourites?uuid=…` returns `[{id, label, pizza_id, pizza_name, added:[{id,name}], removed:[{id,name}], available}]`, sorted by label. `available=false` when:
  - the pizza is off the menu, or
  - a needed topping is switched off, or
  - a removed topping is no longer on the pizza.
- `POST /api/favourites` — body `{uuid, label, pizza_id, added, removed}` saves a pizza + customisation under a label. Returns 201, or 409 if that user already has the label for that pizza.
  - Schema: migration 002 added `favourites.added_json/removed_json`. The original table had nowhere to store the customisation.
- `DELETE /api/favourites/{id}?uuid=…` returns 204. It gives 404 unless the `uuid` owns the favourite.

**Orders**
- `POST /api/orders` — body `{uuid, note?, items:[{ pizza_id, added:[topping_id], removed:[topping_id] }]}`, 1–20 items. Returns the order (201).
  - `added` may repeat a base topping (meaning "extra"). `removed` must be base toppings, and the same topping can't be both added and removed.
  - Gives 409 if the pizza is off the menu or any topping the pizza needs is switched off. The server never silently drops a topping, so the app must remove unavailable base toppings explicitly.
- `GET /api/orders?uuid=…` — that user's last 50 orders, newest first, `[{id, status, note, created_at, updated_at, items:[{pizza_id, pizza_name, added, removed}]}]`. The app polls this for status.
- Kitchen:
  - `GET /api/kitchen/orders` returns every order not yet `collected`, oldest first, with `user_name`.
  - `POST /api/orders/{id}/status` takes `{status}`, one of `new`/`preparing`/`ready`/`collected`. Any change is allowed so a mis-tap can be undone, and setting the current status again is a no-op.
  - A change *into* `ready` sends the APNs push to all of that order's user's devices (v0.5.0, §6). Setting `ready` again, or any other status, sends nothing.

**Live updates**: ✅ built (v0.4.0)
- `GET /api/stream` uses Server-Sent Events via FastAPI's built-in `fastapi.sse.EventSourceResponse`, so no extra dependency.
  - On connect and after every change it sends `event: orders` with the full active-order list (the same shape as `GET /api/kitchen/orders`).
  - FastAPI adds a keep-alive `: ping` every 15 s, and the stream sets `retry: 3000`.
- Wiring: `create_order` and `set_order_status` (on an actual change) call `kitchen_hub.notify()`.
  - The hub is in-process only, which is correct **only because the service runs a single uvicorn worker**. Don't add `--workers`.
  - Bursts of changes coalesce, and each send is a fresh snapshot, so clients never drift.
- ⚠️ **Shutdown gotcha:** with an SSE client attached (the iPad, always), plain uvicorn never finishes a graceful shutdown. Every `systemctl restart` would hang for 90 s and then SIGKILL.
  - Fix: run uvicorn with `--timeout-graceful-shutdown 3`, set in the drop-in `/etc/systemd/system/pizza-app.service.d/shutdown.conf`, which overrides `ExecStart`.
  - Tested locally: the hang happened without the flag, and shutdown took 4 s with it.
  - Applied live on 2026-11-08: a restart with 2 stream clients connected took 3.2 s.

**Validation:** use pydantic models for all request bodies.

---

### v0.6.0 additions (live 2026-11-09, see §8 step 8)

Schema: migration 004 (`migrate_004_sauces_photos_halves.py`). It is idempotent, writes `pizza.db.bak-<ts>-pre004`, runs in one transaction with `foreign_key_check`, and refuses to touch tables whose columns it doesn't recognise.
- Adds `sauces`, `toppings.style/image/image_type/image_hash`, `pizzas.sauce_id`, `favourites.sauce_id`.
- Rebuilds `order_items` (SQLite can't relax `NOT NULL`): `pizza_id` becomes nullable (NULL = build your own), plus `sauce_id` and `toppings_json`. Existing rows are copied unchanged; their `sauce_id` is NULL (shown as no sauce line).
- **Data change:** "Tomato" was a topping standing in for the sauce. Every pizza now gets `sauce_id` = Tomato, the Tomato topping is taken off every base set and switched off (kept for order history). Turn it back on in `/admin` (e.g. renamed "Fresh tomato") if sliced tomato is wanted.
- Topping styles are guessed from names (Mozzarella → cheese, Peppers → pepper, …); the owner can change them in `/admin`.

**Menu / photos**
- `GET /api/menu`: each pizza gains `sauce {id, name, colour}` (its usual sauce); each base topping gains `style` and `image_url`.
- `GET /api/toppings`: `[{id, name, style, image_url}]`.
- `GET /api/sauces`: active sauces in order (Tomato first). `colour` is `#rrggbb`, or `''` for "No sauce".
- `GET /api/toppings/{id}/image?v=<hash>`: the photo bytes. `image_url` is relative and versioned by the photo's sha1, and that URL is served `Cache-Control: immutable` with an ETag, so phones fetch each photo once. Works for switched-off toppings too. 404 when there's no photo.
- **Topping styles** (`TOPPING_STYLES` in `main.py`, `ToppingStyle` in `PizzaArt.swift`, the `<select>` in `admin.html`; keep all three in step): cheese, pepperoni, ham, mushroom, onion, pepper, pineapple, chilli, olive, basil, sweetcorn, tomato, sausage, chicken, generic. `generic` = the app draws little discs cut from the topping's photo.

**Admin**
- `PUT /api/admin/toppings/{id}/image`: raw PNG/JPEG/WebP body, max 512 KB (413 over, 415 for anything else; checked by magic bytes, not the header). `DELETE …/image` removes it. Both return the topping.
- `PATCH /api/admin/toppings/{id}` and `POST /api/admin/toppings` accept `style` (POST guesses it when omitted).
- `GET/POST /api/admin/sauces`, `PATCH /api/admin/sauces/{id}` `{name?, colour?, active?}`. Same rules as toppings: unique names, no deletes.
- `POST/PATCH /api/admin/pizzas` accept `sauce_id` (POST defaults to the first sauce).
- `/admin` page: tap a topping's square to upload a photo. The page centre-crops it and shrinks it to 256 px in the browser (PNG stays PNG; otherwise JPEG 85%) before sending, so the server needs no imaging library. It also has a "Looks like" style dropdown per topping, a Sauces section (colour picker, rename, available), and a Sauce select in the pizza dialog.

**Orders**
- An order item is either a **menu pizza** `{pizza_id, sauce_id?, added, removed}` (`sauce_id` omitted/null = the pizza's usual sauce) or **build your own** `{pizza_id: null (or omitted), sauce_id, toppings: [{id, side: "whole"|"left"|"right", extra: bool}]}`.
  - Build your own: `sauce_id` is required, `added`/`removed` must be empty, each topping at most once, toppings may be empty. A menu pizza can't send `toppings` (422).
  - 409 also covers a switched-off sauce.
- Responses: each item gains `sauce` (null on pre-v0.6 orders) and `toppings` (`[{id, name, side, extra}]`, build your own only); `pizza_id` is null and `pizza_name` is "Build your own" for build-your-own items.
- Favourites: `POST` accepts `sauce_id`; `GET` returns `sauce_id` (as saved; null = usual) and `sauce` (resolved). `available` is also false when that sauce is switched off. Build-your-own favourites are not supported.
- `GET /api/orders/{id}/stream?uuid=…` (SSE, for the app's tracker): `event: order` with the order (same shape as `GET /api/orders` entries) on connect and whenever it changes. Ends after `collected`. 404 unless that `uuid` placed the order (checked by a dependency before the stream opens). Uses the same in-process hub as `/api/stream`.
- **Old app builds (1.0 (1))** keep working: they send no `sauce_id` (so the pizza's usual sauce is used) and ignore the new fields. One edge: build 1 can't decode an order list containing a build-your-own item (`pizza_id` null), so a person who orders build-your-own from 1.1 and still has build 1 on another phone sees an error in that phone's My orders. Update everyone to 1.1.

### v0.7.0 additions (live 2026-11-09, see §8 step 9)

- **Schema (migration 005):** `toppings` and `pizzas` gain `sort_order` (owner's list order; existing rows numbered 10, 20… alphabetically) and `deleted` (0/1).
- **Order:** `/api/menu`, `/api/toppings`, the admin lists and each pizza's base toppings are sorted by `sort_order`, then name. New pizzas and toppings go to the end. `PUT /api/admin/toppings/order` and `PUT /api/admin/pizzas/order` take `{"ids": [...]}`: every non-deleted id exactly once, first to last (422 otherwise).
- **Delete:** `DELETE /api/admin/toppings/{id}` and `DELETE /api/admin/pizzas/{id}` (204) mark the row deleted and switched off. Order history refers to ids, so rows are never removed: deleted ones vanish from every list and can't be ordered (409), but past orders still show their names.
  - Deleting a topping also takes it off every pizza's base toppings. Adding a topping with a deleted one's name brings that row back (same id, photo kept), at the end of the list. Renaming another topping to a deleted one's name is refused (409).
  - Deleting a pizza also deletes everyone's favourites of it. Its name is free for a new pizza.
  - Sauces still can't be deleted, only switched off.
- **Halves:** build-your-own may list the same topping once per half, e.g. `{"id":3,"side":"left","extra":true}` + `{"id":3,"side":"right"}` (double on the left, normal on the right). Overlaps (whole + a half, or a half twice) are 422.
- **Wording:** the kitchen card and the app say "Double X" (was "Extra X") for build-your-own; menu-pizza extras still say "Extra X".
- **Tested:** 24 API checks on the local server (reorder, partial/duplicate order lists, new items last, delete pizza with favourite, delete topping used on pizzas, old order keeps the name, re-adding revives with photo, rename blocked), the halves rule (3 cases), `/admin` at iPad width; then a dry run on the container against a copy of the live DB.

### v0.8.0 additions (live 2026-11-09 16:04, see §8 step 10)

Menu pizzas can now have half-and-half and double base toppings, the same as build your own, and people can change them per half in the app.

- **Schema (migration 006, `migrate_006_menu_halves.py`):** `pizza_toppings` gains `left_amount` and `right_amount` (0 none, 1 normal, 2 double; default 1, so every existing base topping stays normal all over). `favourites` gains `toppings_json`. No data changes.
- **Menu:** each base topping in `/api/menu` and the admin pizza lists gains `left` and `right` (0/1/2, never both 0). Each topping still appears once, so older apps keep working; they just draw everything normal all over.
- **Admin:** `POST/PATCH /api/admin/pizzas` take `toppings: [{id, left, right}]` (`left`/`right` default 1) **instead of** `topping_ids`, which is now refused (422). Duplicates, unknown ids and a topping on neither half are 422.
- **Orders:** a menu-pizza item may send `toppings: [{id, side, extra}]` (the whole pizza as it should be made, same shape and halves rule as build your own) instead of `added`/`removed`. Sending both is 422. Old `added`/`removed` items still work.
  - The server compares it with the recipe. If `added`/`removed` say it exactly (a topping left off, "+ X" normal all over, or normal all over made double all over), it is stored as `added`/`removed` with `toppings: []`, exactly like an old-style order.
  - Otherwise it keeps `toppings` and also stores approximate `added` (more on some half) and `removed` (left off entirely), so older apps still show something sensible.
- **Favourites:** `POST /api/favourites` accepts `toppings` the same way. A favourite stored with `toppings` is made exactly as saved, whatever the recipe says later. One stored as `added`/`removed` follows recipe changes, as before.
- **Kitchen (`/kitchen`):** a menu pizza whose halves were changed shows "· changed" and the whole pizza under All over / Left half / Right half, without the +/− line (which would only be approximate). A menu pizza whose recipe has halves or doubles shows its +/− changes and then the pizza as made from today's recipe.
- **`/admin`:** toppings are a grid of tiles across the page (◀▶ reorder). In the pizza dialog each topping has ◐ left / ● whole / ◑ right buttons that cycle none → normal → double, as in the app, with an orange glow and "2×" on doubles. The pizza list chips read "Double Ham" and "Pepperoni (left half)".
- **Deploy order:** server first. App 1.2 (4) always sends `toppings` for menu pizzas, which v0.7.0 refuses.
- **Cheese section (`admin.html` only, live 2026-11-09 16:21; rollback copy `admin.html.v0.8.0`):** a topping whose "Looks like" is Cheese counts as a cheese. The pizza dialog has Sauce, then **Cheese**, then **Toppings**, and a new pizza starts with the first cheese all over. The pizza list shows the cheese chip right after the sauce ("No cheese" when there is none). No API or schema change: a cheese is still a topping.
- **Tested:** 21 API checks on the local server (per-half recipe save and every 422, menu shape, unchanged and exact-change favourites stored as added/removed, half changes kept as toppings with approximate added/removed, order with halves, kitchen list, toppings + removed refused, same half twice refused, legacy order still accepted). Migration run twice on the local test DB (second run a no-op). `/admin` dialog and chips, `/kitchen` cards and app 1.2 (4) checked in the browser and simulator.

**Tested locally** on a copy of the live DB (migration run twice; second run a no-op): 40-odd API checks (photo upload/ETag/304/415/413, sauces CRUD, style validation, menu sauce swap, build-your-own halves, every 422/409 case, legacy order shapes, favourites with sauce), the per-order stream (emits only on its own order's changes, ends on collected, 404 for someone else's order), `/admin` photo upload end to end in a browser, and `/kitchen` rendering.

### v0.9.0 additions (live 2026-11-09 16:44, see §8 step 11)

Build-your-own favourites, and menu suggestions from the app.

- **Schema (migration 007, `migrate_007_byo_favourites_suggestions.py`):** `favourites` is rebuilt so `pizza_id` may be NULL (= build your own; rows copied unchanged), plus a partial unique index `favourites_byo_label (user_id, label) WHERE pizza_id IS NULL` (the table's UNIQUE treats NULL pizza ids as all different). New table `suggestions` (id, user_id, name, sauce_id, toppings_json, status `new`/`added`/`dismissed`, pizza_id, created_at, updated_at).
- **Favourites:** `POST /api/favourites` with `pizza_id` null/omitted saves a build-your-own pizza: `sauce_id` required, `toppings` as in an order, `added`/`removed` refused (422). Same label twice for build your own is 409. In `GET /api/favourites` such a favourite has `pizza_id: null`, `pizza_name: "Build your own"`, its sauce and toppings; `available` is false if the sauce or any topping is switched off.
- **Suggestions:** `POST /api/suggestions {uuid, name (optional, ≤40), sauce_id, toppings}` (201) sends a build-your-own pizza to the owner; validated like a build-your-own order but not refused for switched-off toppings. Admin: `GET /api/admin/suggestions` (newest first, last 200, with `user_name`, sauce and topping names) and `PATCH /api/admin/suggestions/{id} {status, pizza_id?}` (`pizza_id` only kept with `added`; unknown pizza 422).
- **`/admin`:** a **Suggestions** section at the top, shown once there are any: a card per new one (name or "Untitled pizza", who and when, sauce and toppings by half) with **Add to menu…** and **Dismiss**. Add to menu opens the new-pizza dialog filled in (name, sauce, cheese and toppings by half); saving it creates the pizza and marks the suggestion added. Handled ones fold into "N earlier", each with Undo.
- **Old apps:** 1.1 (and 1.2 builds from before this change) can't decode a favourites list containing a build-your-own favourite (`pizzaId` was not optional), so someone who saves one on 1.2 and still has 1.1 on another phone sees an error there. Same edge as v0.6.0's build-your-own orders; update everyone.
- **Tested:** 22 API checks on the local server (BYO favourite save, shape, duplicate label 409, missing sauce / `added` 422, switched-off topping unavailable, menu favourites unaffected, mixed list, delete; suggestion save and shape, empty name/toppings, unknown sauce 422, unknown device 404, same half twice 422, admin list order, added/dismissed/undo, unknown pizza 422, bad status 422) and the 21 v0.8.0 checks again. Migration 007 run twice on the local test DB. `/admin` Suggestions: Add to menu (prefilled dialog, pizza created, suggestion marked "added as …"), Dismiss and Undo.

### v0.10.0 additions (not deployed yet)

The server is the only source of every topping's pieces for the app's pizza picture: seeded from `Food Images/`, and changed by the owner in `/admin` without an app release. The app bundles no pieces (the asset catalog lost ~6 MB); until the pieces load, and offline, it draws the toppings as it did before photo pieces.

- **Schema (migration 008, `migrate_008_topping_pieces.py`):** `toppings.piece_count` (default 0) and `toppings.pieces_hash`, plus a new table `topping_pieces (topping_id, n, image BLOB, PRIMARY KEY (topping_id, n))`. No data changes.
- **Cutting (`topping_pieces.py`, new; needs Pillow, now in `requirements.txt`):** also used by `ios/tools/cut_toppings.py` (it imports it), which cuts `Food Images/` for seeding. It clears light, colourless background touching the edge (plus large enclosed holes for chilli/olive/onion styles), finds separate opaque areas, trims each and scales it to 144 px, PNG. At most 12 pieces; the sheet itself isn't kept.
- **API:** every topping (`/api/toppings`, menu base toppings, admin lists) gains `piece_urls: [..]`: relative, versioned `/api/toppings/{id}/pieces/{n}?v=<hash>`, served `Cache-Control: immutable` with an ETag (304 on match); `[]` when there are none. Older apps ignore the field.
- **Admin:** `PUT /api/admin/toppings/{id}/pieces` takes the raw sheet (PNG/JPEG/WebP, max 8 MB; 413 over, 415 not an image, 422 if it can't be read or no separate pieces are found) and returns the topping; `DELETE …/pieces` removes them. `/admin` shows a pieces strip on each topping tile (on sauce red, like the pizza): tap to add or replace a sheet, **Remove** to drop them.
- **App:** `pieceUrls` is decoded on `ToppingInfo`/`BaseTopping`; `ToppingImages` fetches a topping's pieces (all or none); `ToppingPieces.book(for:server:)` puts them in `byTopping` and, for the first topping of each style, `byStyle` (toppings the menu no longer lists, the splash pizza). Cheese-style toppings stay drawn melted. A topping with no server pieces is drawn. The bundled `Assets.xcassets/Toppings` is gone.
- **Seeding (`ios/tools/seed_server_pieces.py SERVER [--replace] [--dry-run]`):** cuts `Food Images/` exactly as `cut_toppings.py` does, picks each server topping's set (its style, or a name word for generic/chicken toppings; chicken mixes both kinds), lays its pieces out on a transparent sheet and uploads it through `PUT …/pieces`, as the owner would. Toppings that already have pieces are kept unless `--replace`; cheese and unmatched toppings are skipped. The server's re-cut gives back the same pieces in the same order (checked against the PNGs that used to be bundled; differences are 1 px edge shifts).
- **Tested locally:** migration 008 on a v0.9 DB (twice; second run a no-op) and on a fresh `schema.sql`; upload/replace/delete, 415/422, versioned URL immutable + 304, unversioned no-cache; `/admin` upload and preview in the browser; seeding the local copy of the live DB (11 toppings seeded, Mozzarella and the test topping skipped, second run keeps all); `cut_toppings.py` (now cutting only) still cuts the same pieces; app against the local server in the simulator (an owner-added "Artichoke" with a sheet scatters and drops its pieces; after removing the sheet it is drawn as before; a test sheet on Mushroom replaced its slices; a clean install with no bundled pieces draws the toppings until the menu loads, then shows the server's photo pieces).
- **Deploying:** snapshot the container, `pip install pillow==12.1.1` into `/opt/pizza-app/venv`, copy `main.py`, `admin.html`, `schema.sql`, `topping_pieces.py`, `requirements.txt`, `migrate_008_topping_pieces.py` (keep `main.py.v0.9.0` / `admin.html.v0.9` / `schema.sql.v0.9` as rollback copies), run migration 008, restart the service, then seed from the Mac: `cd ios && python3 tools/seed_server_pieces.py http://192.168.0.50:8000 --dry-run`, then without `--dry-run`. Seed before shipping the app build: it has no pieces of its own, so an unseeded server means drawn toppings. Old builds keep working with their bundled pieces.

## 5. Kitchen iPad dashboard

A web page served by the backend (e.g. `GET /kitchen`), opened in Safari on the iPad and **added to the home screen** (so it runs full-screen). Shows active orders as cards, auto-updates via SSE, with buttons to advance status. No separate app. Keep it legible from arm's length (big text, clear status colours).

✅ **Built (v0.4.0): `GET /kitchen` → `kitchen.html`.**
- **Layout:**
  - Three columns, New / Preparing / Ready, with counts. Each card shows the person's name, `#id · clock time · age`, pizzas with `+ added` (green) and `− removed` (red, struck through), and the note.
  - One big button per card: Start → Ready ✓ → Collected. A `↶` button moves the order back a step to undo a mis-tap.
  - Ages refresh every 30 s and turn red at 30 min if the order isn't ready.
  - Light and dark mode; the columns stack below 700 px. Full-screen meta tags are set for adding it to the home screen.
- **Alerts:**
  - A new order flashes its card. It also chimes, but only after **"Tap for sound"**, because iOS only allows audio after a tap. Tap it once each time the page loads.
  - The Screen Wake Lock is requested where Safari supports it.
- **Connection:**
  - A Live / Reconnecting… indicator. EventSource retries dropped connections itself.
  - If the stream gets an HTTP error, which makes EventSource give up, the page reopens it after 5 s.
  - If a status tap happens while the stream is down, the page fetches `/api/kitchen/orders` directly.
- No page-level auth (LAN-open, same as `/admin`).

**v0.6.0 kitchen changes:** columns are now **Pending / Baking / Ready** (API values unchanged: `new`/`preparing`/`ready`), the first button reads "Start baking", every pizza shows its sauce with a colour dot (bold "(swapped)" when it isn't the pizza's usual one), and build-your-own pizzas list toppings under **All over / Left half / Right half**, with "Extra X".

---

## 6. Push notifications (APNs)

- iOS backgrounded push **requires APNs** — there is no LAN-only alternative. The server needs **outbound** internet to `api.push.apple.com` (nothing inbound is exposed).
- Jason **has an Apple Developer account**. Use a **token-based APNs auth key** (`.p8` + Key ID + Team ID) — simpler and non-expiring vs certificates. Store the `.p8` on the container, referenced by the backend.
- Python: a small APNs client (e.g. an `httpx`-based HTTP/2 call, or a maintained library) sends the push when an order hits `ready`.
- `devices.token` holds the per-device APNs token the app registers via `POST /api/devices`.

✅ **Built (v0.5.0), live 2026-11-08. Push stays disabled until the config below exists.**
- **Code:**
  - `apns.py` is the client: httpx over HTTP/2, with an ES256 provider JWT (PyJWT) cached for 45 min.
    - Production host `api.push.apple.com`, sandbox host `api.sandbox.push.apple.com`. The host is chosen per device from `devices.environment`.
  - `set_order_status` queues `_push_order_ready` as a FastAPI background task, so it runs after the kitchen's response has been sent.
    - Payload: title "Your pizza is ready 🍕", body "Order #N is ready to collect.", default sound, plus `order_id`.
    - `apns-collapse-id: order-N`, so ready → undo → ready replaces the notification rather than stacking.
    - `apns-expiration`: 1 hour.
- **Failure handling:** the push never raises, and every outcome is logged to journald (logger `pizza`).
  - A dead token (HTTP 410, `BadDeviceToken`, `Unregistered`, `DeviceTokenNotForTopic`, `ExpiredToken`) deletes that `devices` row. The app re-registers on every launch.
  - `BadDeviceToken` is logged with a sandbox/production mix-up hint.
  - Network errors and Apple 5xx are logged and the token is kept.
- **Config** (Jason places it as root; files `root:pizza`, mode `640`, directory `root:pizza` `750`):
  - `/etc/pizza-app/apns.json`: `{"key_id": "...", "team_id": "...", "topic": "<bundle id>", "key_path": "/etc/pizza-app/AuthKey_<KEYID>.p8"}`
  - `/etc/pizza-app/AuthKey_<KEYID>.p8`: the APNs key from developer.apple.com (Keys, APNs, "Sandbox & Production"). It can only be downloaded once, so keep a copy off the server.
  - The config is read on every push, so placing or changing it needs no restart. A missing config logs "push not configured, skipped". A broken config logs an error and disables push.
- **Check:** run `./venv/bin/python apns_check.py` in `/opt/pizza-app` (works as `pizza`).
  - With no arguments, it sends to a made-up token on both environments. `BadDeviceToken` on both means the key, team and bundle ID are accepted. Other reasons are explained in its output.
  - `--user <first name>` sends a real test push to that user's registered devices.
- **Tested** on the Mac:
  - 15 checks against a mocked Apple: host per environment, headers, JWT signature/kid/iss and caching, no push for non-ready or ready→ready, dead-token deletion, an expired JWT reset on 403, 500 keeping the token, a network failure still giving the kitchen 200, a missing or broken config, and a user with no devices.
  - A real HTTP/2 round trip to both Apple hosts with a throwaway key returned 403 `InvalidProviderToken`, as expected.
  - The container reaches both Apple hosts over h2.

---

## 7. iOS app (SwiftUI, TestFlight)

- **Server base URL hard-coded** to `http://192.168.0.50:8000`.
- **Bundle ID must be exactly `com.aspinalljason.familypizza`** (your Apple Team ID, kept in `ios/Local.xcconfig`, not in git). It is the APNs topic the server pushes to. Enable the Push Notifications capability in Xcode.
- Send `environment: "sandbox"` to `POST /api/devices` from Xcode-installed builds and `"production"` from TestFlight builds (§4). The app works this out from its provisioning profile (below).
- **App Transport Security:** talking to a plain-HTTP LAN IP needs an ATS exception. Built with `NSAllowsLocalNetworking`, which is narrower than `NSAllowsArbitraryLoads`. Local HTTPS is noted as later hardening.
- First-launch flow: generate UUID → keychain → ask first name → `POST /api/register` → register for remote notifications → `POST /api/devices` with APNs token.
- Screens: menu list → pizza detail with add/remove toppings → place order → order status; plus favourites. Pull menu/toppings from the API so the owner's edits show without an app rebuild.
- Distribute via TestFlight; builds expire ~90 days (expected, Jason knows).

✅ **Built (v1.0, build 1), 2026-11-09.** Source: `~/Developer/pizza-app/ios/`.
- **Project:**
  - Generated by **XcodeGen** from `ios/project.yml`; `FamilyPizza.xcodeproj` is generated output. After changing `project.yml` or adding files, run `cd ios && xcodegen`.
  - Swift 6 language mode, iOS 17.0+, iPhone only. No third-party dependencies.
  - Automatic signing; the team comes from `ios/Local.xcconfig` (git-ignored) through `ios/Signing.xcconfig`. The entitlements file has `aps-environment: development`; Xcode switches it to production for TestFlight automatically.
  - `Info.plist`:
    - `NSAllowsLocalNetworking` for plain HTTP on the LAN. Arbitrary loads stay off.
    - `NSLocalNetworkUsageDescription`: iOS shows a Local Network permission prompt on first use, and the person must allow it.
    - `ITSAppUsesNonExemptEncryption = false`, so TestFlight uploads skip the export-compliance question.
- **Icon:** drawn by `ios/tools/make_icon.swift` (a pizza slice; opaque 1024 px).
- **Files** in `ios/FamilyPizza/`:
  - `Config.swift`:
    - Base URL `http://192.168.0.50:8000`. DEBUG builds only can override it with the launch argument `-PIZZA_BASE_URL <url>`.
    - The APNs environment comes from the app's embedded provisioning profile: development means `sandbox`; no profile (TestFlight/App Store) means `production`; the simulator is `sandbox`.
  - `DeviceIdentity.swift`: the keychain UUID (§3), lowercase, `AfterFirstUnlock`, not synced to iCloud.
  - `APIClient.swift`: URLSession with a 10 s timeout, snake_case JSON, and FastAPI error details turned into messages. "Server unreachable" reads "Can't reach the pizza server. Are you on the home Wi-Fi?"
  - `AppModel.swift`: all state and server calls.
    - It re-registers on every launch and foreground.
    - Any 404 "call register first" triggers re-registration and one retry, so a reset server database heals itself.
    - It uploads the push token whenever iOS supplies one.
  - `Views/`:
    - **Onboarding:** checks `GET /health`, asks for the first name, registers, then asks for notification permission.
    - **Menu:** base toppings that have run out are struck through.
    - **Pizza detail:**
      - Each base topping has None / Normal / Extra; Extra means the topping is repeated in `added`.
      - Extra toppings are tappable rows.
      - "Add to basket" is pinned to the bottom of the screen, and a ☆ button saves a favourite.
    - **Basket sheet:** a note of up to 200 characters, and at most 20 pizzas. A 409 refreshes the menu and explains why.
    - **Favourites:** tap to add to the basket, swipe to delete.
    - **My orders:**
      - Grouped into On the go / Earlier.
      - Polls every 10 s while that tab is open and an order is active, otherwise every 60 s.
      - The tab badge shows the number of ready orders.
    - **Settings:** change your name, see notification status, server URL and version.
  - `FamilyPizzaApp.swift`: an AppDelegate for the APNs token. A notification that arrives while the app is open still shows a banner and refreshes orders. Tapping a notification opens My orders. It uses the completion-handler delegate forms; see the device bug below.
- **Favourites and run-out toppings (decided while testing):**
  - A favourite stores only what the person chose. If a base topping has run out when they save, it is *not* stored as "No X".
  - When the favourite is ordered, run-out base toppings are left off and the person is told.
  - The Favourites tab judges availability from the current menu, not the server's `available` flag, which also counts run-out base toppings.
  - A favourite is blocked only if its pizza is off the menu, an added topping has run out, or a removed topping is no longer on the pizza.
- **Tested** in the iOS 27.1 simulator (iPhone 17) against a local copy of the live DB, with Basil and Sweetcorn switched off locally:
  - Onboarding and registration (201).
  - Notification permission, then a real sandbox APNs token (160 hex characters) uploaded with `environment: sandbox`.
  - Menu with Basil struck through, and the customise screen.
  - Basket, and an order whose server payload was correct (`added [1,7]`, `removed [11]`).
  - Favourites: saving one, the run-out note, and the blocked case.
  - A status change to ready appearing via polling, with the tab badge.
  - A notification arriving while the app is backgrounded, and while it is open (`xcrun simctl push` with the server's exact payload).
  - The offline state with the server stopped.
  - Fresh install against the **live** server: onboarding's `GET /health` returned 200 from 192.168.0.50, which proves the ATS setting works. Nothing was written to the live database.
- **Verified on Jason's iPhone 14 Pro, 2026-11-09** (Debug build from Xcode, sandbox APNs):
  - Registration (user 1 "Jason"), and Local Network allowed.
  - Token registered as `sandbox`, so the provisioning-profile detection works on a real device.
  - A first order placed from the phone.
  - `apns_check.py --user Jason` arrived.
  - Kitchen Ready pushes arrive on the locked phone.
  - Tapping one opens My orders and the app keeps running (10 s polling continued; no new crash report).
  - With the app open, the push reaches the app, which refreshes orders within 0.2 s.
- **Bug found on the device and fixed: tapping a notification crashed the app.**
  - The `async` forms of the `UNUserNotificationCenterDelegate` methods make iOS complete the callback on a background thread. UIKit then aborts, with `NSAssertionHandler` in `_updateSnapshotAndStateRestoration…`. The crash report was `FamilyPizza-2026-11-09-002507.ips`, pulled with `xcrun devicectl device copy from --domain-type systemCrashLogs`.
  - The simulator never showed it, because its taps on system banners don't register.
  - Fix: use the completion-handler forms and call completion on the main actor. **Don't switch back to the async forms.**
- **Focus hides banners.** With Sleep or Do Not Disturb on, the open-app banner (and lock-screen banners) are held back, and the notification goes quietly to Notification Centre. That is iOS behaviour, not a bug: it was confirmed on the phone at 00:28, and the banner showed with Focus off.
  - Option, not built: Time Sensitive notifications (`interruption-level: time-sensitive` plus the Time Sensitive capability) can break through Focus if each person allows them.
- **TestFlight verified 2026-11-09:**
  - Build 1.0 (1) was uploaded by Jason and installed through the internal group "Family". (Tester gotcha: "Invited" stays until the invitation email is opened on the phone and **View in TestFlight** is tapped.)
  - The TestFlight app registered a `production` token under the same user 1. The keychain identity survived replacing the Xcode build.
  - The Ready push for order 2 went over production APNs and arrived exactly once.
  - The old sandbox token was still accepted by Apple at that point (dead tokens are only rejected after a while). The server deletes it when Apple starts rejecting it.

**1.1 (2), written and tested in the simulator 2026-11-09 against a local v0.6.0** (not yet on TestFlight):
- **Pizza pictures** (`PizzaArt.swift`): pure SwiftUI `Canvas`, no image assets. Thin crust with baked rim, char and flour; sauce in the sauce's colour with texture, herb flecks and gloss (bare dough for "No sauce"); melted mozzarella; shaded, shadowed pieces for each topping style. Piece positions are seeded by topping id, so they don't jump around, and "Extra" adds pieces on top of the same ones. Half toppings stay on their side, with a dashed divider. Toppings animate in and out.
  - It imports only SwiftUI so `tools/make_icon.swift` can compile it on macOS.
- **Topping photos** (`ToppingImages.swift`): fetched in parallel right after the menu loads, held in memory, and backed by a 40 MB URL cache. The versioned, immutable URLs mean later launches don't hit the network. `ToppingThumb` shows the photo, or a drawn "plate of pieces" icon until a photo exists.
- **Menu:** pizza thumbnails, the sauce in each description, and a **Build your own** row.
- **Customise (menu pizza):** the live picture fills the top 30% of the screen (`PizzaStageLayout`), with a sauce picker (the usual sauce is tagged) and photo thumbnails on every topping row. The sauce is sent only when it differs from the usual one.
- **Build your own** (`BuildYourOwnView.swift`): base (thin crust, fixed), sauce picker, and every topping with ◐ left / ● whole / ◑ right (tap the selected one again to remove it) plus an Extra toggle. It starts with the first sauce and cheese all over. Caption under the picture: "Half and half" / "Left half customised" / …
- **Order tracker** (`OrderTrackerView.swift`): opens full screen after Send order, when an order in My orders is tapped, and when a push is tapped (it opens that order). It shows a big picture of the first pizza (slowly turning in an orange glow while baking, a green tick when ready), the status, a Pending → Baking → Ready step bar, and the items.
  - Live via `GET /api/orders/{id}/stream`. If the stream drops, it re-reads `/api/orders` and reconnects after 3 s. A Live / Connecting… badge shows which. The stream session has a 45 s timeout against the server's 15 s keep-alives.
- **App icon:** redrawn by `tools/make_icon.swift` with the app's own renderer: a pizza with a slice pulled out, on a dark, oven-glow ground. Opaque 1024 px (checked: `hasAlpha: no`).
- Onboarding shows a drawn pizza instead of the fork-and-knife symbol.
- `project.yml`: `MARKETING_VERSION` 1.1, `CURRENT_PROJECT_VERSION` 2. Debug (simulator) and Release (device, unsigned) builds compile clean under Swift 6.
- **Tested** in the iPhone 17 simulator (iOS 27.1) against a local v0.6.0 on a migrated copy of the live DB: menu with thumbnails and Build your own; a Margherita sauce swap to BBQ recolouring the picture; BYO with mozzarella whole, pepperoni left, extra mushroom right; the basket summary ("Tomato sauce · Mozzarella · Right: Extra Mushroom"); the kitchen card; the tracker opening after Send and following Pending → Baking → Ready live as the status was changed on the server; a topping photo uploaded through `/admin` appearing in the app; dark mode.
- Simulator tip: the simulator tool's screenshots can lag a few seconds behind taps. `xcrun simctl io <udid> screenshot` is always current.

**1.1 (3), 2026-11-09** (not yet on TestFlight; supersedes 1.1 (2), which was never uploaded):
- **Build your own toppings:** each of ◐ left / ● whole / ◑ right cycles none → normal → double → none on every tap; the Extra toggle is gone. A double glows orange with a "2×" badge, and the line under the topping name says what's chosen ("Double left · normal right"). When both halves match it's sent as one whole entry, otherwise one entry per half. The buttons use a tap gesture, not `Button`: inside a `Form` row a `Button` dropped the second of two quick taps.
- **Menu:** Build your own is first; the menu pizzas follow under "Our pizzas", in the owner's order from `/admin`.
- Tested in the simulator against a local v0.7.0 (quick double taps, mixed halves, basket text, kitchen card) and the live server (menu). Release (device, unsigned) build compiles.

**1.2 (4), 2026-11-09** (not yet on TestFlight; needs server v0.8.0):
- **Menu pizzas with halves:** the menu line, thumbnail and picture follow the recipe's halves and doubles ("Double Ham", "Pepperoni (left half)").
- **Customise screen:** every topping, the recipe's and the extras, has the same ◐ ● ◑ picker as Build your own, starting from the recipe. The line under a topping says what's chosen when it isn't plain normal all over, and what it usually is when changed ("Double left · normal right (usually whole pizza)"). "Start again" in the "Comes with" header resets to the recipe. The picture caption says "Half and half" etc.
- The app always sends `toppings` for a menu pizza. The basket, orders, tracker and favourites describe it against today's recipe: "No Basil · + Ham · Extra Mozzarella · Pepperoni: left half · + Chilli (right half)". A pizza with changed halves that's off the menu is listed in full.
- Favourites saved with halves are made as saved; base toppings that have run out are left off, other run-out toppings make it unavailable.
- **Cheese has its own section, like the sauce** (any topping drawn as cheese): Sauce → Cheese → Comes with → Add on the customise screen ("Start again" sits in the Cheese header), and Base → Sauce → Cheese → Toppings in Build your own. The menu line lists the cheese straight after the sauce.
- **Build your own:** ☆ in the toolbar saves it as a favourite (needs a name); "Suggest this pizza for the menu" at the bottom sends it to the owner (name optional). Both need server v0.9.0. Favourites lists it as "Build your own" with its sauce and toppings; ⊕ adds it to the basket as "<label> (Build your own)"; a switched-off sauce or topping makes it unavailable.
- Tested in the simulator against the local v0.9.0: BYO favourite saved (BBQ, double mozzarella left), listed and added to the basket; suggestion sent and shown in `/admin`. Release build compiles.
- `BaseTopping.left/right` are optional, so 1.2 still reads a v0.7.0 menu (all normal), but ordering a menu pizza needs v0.8.0.
- Tested in the iPhone 17 simulator against the local v0.8.0: menu text and thumbnail for a half-and-half recipe, customise (mozzarella double on the left, chilli added on the right), basket text, order sent and stored with halves, tracker picture, My orders text, favourites with halves and add-to-basket from one. Release (device, unsigned) build compiles.
- **Splash** (`Views/SplashView.swift`, shown from `FamilyPizzaApp`): on a cold launch only, the icon's oven-glow ground, the pizza spins in and gets cheese, pepperoni and basil, "Family Pizza" and "Version 1.2 (4)" (read from the bundle), about 3 s, then a fade. The static launch screen uses the same `LaunchBackground` colour asset (`UILaunchScreen.UIColorName` in `project.yml`), so there is no white flash. Checked on Jason's phone.
- **Menu:** the title is a bold "Menu" centred in the bar (inline title mode plus a `.principal` toolbar item; large titles can't be centred), and the "Thin crust…" note is centred.
- **Uploaded to TestFlight 2026-11-09 17:42** from the command line: `xcodebuild archive` (Release, `-allowProvisioningUpdates`), then `xcodebuild -exportArchive` with ExportOptions `method app-store-connect`, `destination upload`, your team ID, automatic signing. Archive kept at `ios/build/FamilyPizza-1.2-4.xcarchive`. The next upload needs `CURRENT_PROJECT_VERSION` 5.

**TestFlight (distribution to the family)**
- **Ready for upload:**
  - `PrivacyInfo.xcprivacy` declares UserDefaults (reason `CA92.1`) and no tracking. App Store Connect rejects uploads without required-reason declarations (ITMS-91053).
  - `ITSAppUsesNonExemptEncryption = false`.
  - The 1024 px opaque icon is in place.
  - The Release build compiles clean.
- **Build numbers:** `CURRENT_PROJECT_VERSION` in `ios/project.yml` must go up for every upload (1, 2, 3…). Bump `MARKETING_VERSION` for visible releases. Run `xcodegen` after editing.
- **Push in TestFlight:**
  - Exporting for App Store Connect re-signs with the distribution profile, so `aps-environment` becomes `production`.
  - The installed app has no `embedded.mobileprovision`, so `Config.apnsEnvironment` reports `production`.
  - When a phone switches from an Xcode build to TestFlight, its old sandbox token becomes dead. The next push to it gets rejected and the server deletes it automatically.
- **Testers:**
  - **Internal testing** (chosen): family members are added as App Store Connect users in Users and Access (any role, e.g. Customer Support), then put in an internal group. Builds are available with **no Beta App Review**.
  - External testing needs Beta App Review. A reviewer can't reach 192.168.0.50, so they would only see "Can't reach the pizza server", which risks rejection. Avoid it.
- **Builds expire after 90 days:** re-upload before then.

---

## 8. Next steps (in order)

1. ✅ **Identity schema decided** (§3). Migration 001 applied live on 2026-11-08; backup at `pizza.db.bak-20261108-204452-pre001`, Proxmox snapshot `pre_menu_api`.
2. ✅ **Menu + toppings API** and **admin page** (`/admin`). Deployed live as v0.2.0 on 2026-11-08 and verified from the Mac.
3. ✅ **register/devices**, **favourites**, **orders** + kitchen order API. Deployed live as v0.3.0 on 2026-11-08 and verified, with snapshot `pre_orders_api`.
   - ⚠️ **Correction (found during step 5):** by the time v0.4.0 was deployed, the container no longer had the step-3 state. Migration 002 was missing, as were its backup, `migrate_002_*.py` and the v0.2.0 copies, and the running `main.py` was v0.2.0. The cause is unknown; a rollback to `pre_orders_api` would explain it.
   - As a result, v0.4.0 ran from 21:13 to 23:37 without the favourites columns. There were 0 users, so nothing was affected.
   - Migration 002 was applied at 23:36 (backup `pizza.db.bak-20261108-233651-pre002`).
   - The rollback copy step 4 saved as `main.py.v0.3.0` was actually v0.2.0, and has been renamed to `main.py.v0.2.0`.
4. ✅ **Kitchen dashboard** (`/kitchen`) + SSE (`/api/stream`). Live as v0.4.0 on 2026-11-08. Needs the `shutdown.conf` systemd drop-in (§4 Live updates).
5. ✅ **APNs push on `ready`** (§6). Live as v0.5.0 on 2026-11-08. Snapshot `pre_push`; migration 003 applied (backup `pizza.db.bak-20261108-233651-pre003`); previous code kept as `main.py.v0.4.0`.
   - **Enabled 2026-11-08 23:49:**
     - Key ID, Team ID (both kept out of git; see `/etc/pizza-app/apns.json` and `ios/Local.xcconfig`), Bundle ID `com.aspinalljason.familypizza`.
     - Jason placed the key and `apns.json` in `/etc/pizza-app/`. His Mac copy is in `pizza-app/Certs&Keys/`, which `.gitignore` excludes.
     - `apns_check.py` returned `BadDeviceToken` on both production and sandbox, so Apple accepts the credentials.
     - End-to-end delivery to a real phone is not yet tested; it needs the iOS app (step 6).
6. ✅ **SwiftUI app** built and tested in the simulator on 2026-11-09 (§7).
   - ✅ Verified end to end on Jason's iPhone, 2026-11-09 (§7). One device-only crash was fixed along the way.
   - Server v0.5.1 (live 2026-11-09): push log lines and `apns_check.py` now include `apns-unique-id`, the ID that Apple's Push Notifications Console delivery log needs (icloud.developer.apple.com → Push Notifications; sandbox only). The `apns-id` is a different ID and can't be looked up there. Rollback copies: `main.py.v0.5.0`, `apns.py.v0.5.0`.
   - ✅ TestFlight build 1.0 (1) is live in the internal group "Family". Production APNs is verified on Jason's phone.
   - **Next, Jason:** add family members as App Store Connect users (Customer Support role), then to the "Family" group. Each person accepts the email on their phone, installs, and allows Notifications and Local Network.
7. Housekeeping: router DHCP reservation for `.50`; set up a **Proxmox backup job** for CT 101; optional local HTTPS.
8. **Sauces, photos, build your own, tracker (v0.6.0 server + app 1.1 (2))**: server **live as v0.6.0 on 2026-11-09**; app 1.1 (2) not yet uploaded (§4 v0.6.0, §5, §7).
   1. ✅ Jason: snapshot `pre_v060` of CT 101 taken.
   2. ✅ Claude, 2026-11-09 14:14: staged in `staging-v060/`, dry-ran migration 004 and the new server on a copy of the live DB, then went live. Migration backup `pizza.db.bak-20261109-141438-pre004`; 8 order rows kept; integrity and foreign-key checks clean; `/api/menu`, `/api/sauces`, `/admin`, `/kitchen`, kitchen order list all OK. Copied `main.py`, `admin.html`, `kitchen.html`, `schema.sql`, `migrate_004_sauces_photos_halves.py` to the container (keep `main.py.v0.5.1`, `admin.html.v0.5`, `kitchen.html.v0.5` as rollback copies), ran migration 004, restarted. No new Python dependencies. Orders placed before the migration have `sauce: null` (= the pizza's usual sauce).
   3. Jason: upload real topping photos at `/admin` (a close-up on a plain background works best; the page crops and shrinks them). Check each topping's "Looks like" style and the sauce colours.
   4. Jason: archive and upload app 1.1 (2) to TestFlight. Family members on 1.0 (1) should update (see the old-build edge in §4 v0.6.0).
   - Rollback: restore the snapshot, or put back the `.v0.5.1` copies and `pizza.db.bak-*-pre004`.
   - Not built: favourites for build-your-own pizzas, half-and-half on menu pizzas, base/crust options (decided: thin crust only).
9. **Double per half, admin delete and reorder (v0.7.0 server + app 1.1 (3))**: server **live as v0.7.0 on 2026-11-09 15:35** (§4 v0.7.0, §7 1.1 (3)).
   - Snapshot `pre_v070` taken by Claude through the API token. Migration 005 applied (backup `pizza.db.bak-20261109-153531-pre005`); integrity and foreign-key checks clean. Rollback copies `main.py.v0.6.0`, `admin.html.v0.6`, `kitchen.html.v0.6`, `schema.sql.v0.6`.
   - Checked live: version 0.7.0, `/api/menu`, `/api/toppings`, `/api/sauces`, `/admin`, `/kitchen`, kitchen order list.
   - Jason: archive and upload app **1.1 (3)** to TestFlight (instead of 1.1 (2)).
   - Rollback: restore the snapshot, or put back the `.v0.6*` copies and `pizza.db.bak-*-pre005` (the old code ignores the new columns, so the copies alone also work).
10. **Half-and-half and double on menu pizzas (v0.8.0 server + app 1.2 (4))**: server **live as v0.8.0 on 2026-11-09 16:04** (§4 v0.8.0, §7 1.2 (4)).
   - Snapshot `pre_v080` taken by Claude through the API token. Staged in `staging-v080/` (checksums match the Mac); dry run of migration 006 (twice) and the new server on a copy of the live DB: version, menu, `/admin`, `/kitchen`, admin lists, kitchen orders, recipe save all OK.
   - Live: rollback copies `main.py.v0.7.0`, `admin.html.v0.7`, `kitchen.html.v0.7`, `schema.sql.v0.7`; migration 006 applied (backup `pizza.db.bak-20261109-160453-pre006`; 9 base-topping rows, all normal on both halves); integrity and foreign-key checks clean; 10 order rows kept. No new Python dependencies.
   - Checked live: version 0.8.0, `/api/menu` (each base topping has `left`/`right`), `/admin` (tile grid, pizza dialog with ◐ ● ◑, no console errors), `/kitchen`, kitchen order list. The restart logged one "Cancel 1 running task(s)": the old process closing the kitchen iPad's open stream, expected.
   - Next, Jason: set halves/doubles on any menu pizza in `/admin` as wanted; reload any `/admin` tab that was open before 16:04 (the old page sends `topping_ids`, now refused).
   - Then Jason: archive and upload app **1.2 (4)** to TestFlight (instead of 1.1 (3)). Phones on 1.1 keep working against v0.8.0 but draw half recipes as whole.
   - Rollback: restore the snapshot, or the `.v0.7*` copies (v0.7.0 ignores the new columns, but would refuse 1.2's menu orders).

11. **Build-your-own favourites and menu suggestions (v0.9.0 server + app 1.2 (4))**: server **live as v0.9.0 on 2026-11-09 16:44** (§4 v0.9.0).
   - Snapshot `pre_v090` taken by Claude through the API token. Staged in `staging-v090/` (checksums match the Mac); dry run of migration 007 (twice) and the new server on a copy of the live DB: version, menu, admin lists, suggestions list, favourites list, a build-your-own favourite and a suggestion saved, all OK.
   - Live: rollback copies `main.py.v0.8.0`, `admin.html.v0.8.1`, `schema.sql.v0.8`; migration 007 applied (backup `pizza.db.bak-20261109-164423-pre007`; 0 favourites to copy; suggestions table created); integrity and foreign-key checks clean; 12 order rows kept. No new Python dependencies.
   - Checked live: version 0.9.0, `/health`, `/admin` (no console errors; Suggestions hidden until the first one arrives), `/kitchen`, `/api/menu`, `/api/toppings`, `/api/sauces`, kitchen orders, admin pizzas, admin suggestions (empty). The restart logged the usual "Cancel 1 running task(s)" (the kitchen iPad's open stream).
   - App 1.2 (4) now needs v0.9.0 (it was v0.8.0) for its build-your-own ☆ and suggestions; everything else works on v0.8.0.
   - Rollback: restore the snapshot, or the `.v0.8*` copies plus `pizza.db.bak-*-pre007` (v0.8.0 code would fail on a build-your-own favourite's NULL pizza_id).

After any backend change: `systemctl restart pizza-app` (and `./venv/bin/pip install …` for new deps). Check `/docs` reflects changes.

---

## 9. Guardrails carried over

- Home-LAN only; do not add public exposure without an explicit new decision (TLS, auth hardening, etc.).
- Do not touch VM 100 / Home Assistant or the host's other storage.
- Keep `pizza.db` backed up (it's the whole state) — Proxmox snapshot/backup covers it.
