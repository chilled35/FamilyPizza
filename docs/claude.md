# Family Pizza Ordering System — Project Decisions

> Working context & decision log. Updated as we go.
> Last updated: 2026-11-09

## 1. Goal

A home-LAN pizza-ordering system for the family:

- Menu of pizzas (owner-editable), plus **Build your own**
- Family members create accounts and save favourites
- Owner maintains a topping list (each with a **photo**) and a **sauce** list; members customise their pizza
- Every pizza is the **standard thin crust** (no base options), with a choice of sauce
- Build your own allows a topping on the **whole pizza or only the left/right half**; menu pizzas can too (owner sets halves/doubles in `/admin`, people change them per half in the app; v0.8.0)
- The app shows a **live picture of the pizza** being built in the top 30% of the screen
- Orders placed from an **iPhone app** land on a **kitchen iPad** dashboard for review
- After checkout the app shows a **live order tracker** (Pending → Baking → Ready), driven by the kitchen's buttons
- Owner sends a **"order ready for collection"** push notification back to the member's phone

## 2. Hosting decision

| Candidate | Verdict |
|-----------|---------|
| Synology DS214play (2014, ARM, 1 GB) | Rejected — old, no Docker, ARM limits |
| Synology DS216j (2015, ARM, 512 MB) | Rejected — weakest option |
| **Proxmox server (Dell PC)** | **Chosen** — modern x86, already running, isolates cleanly from Home Assistant |

**Running on:** existing Proxmox host at `192.168.0.196:8006` (also hosts Home Assistant).

### Container vs VM
- **LXC container** chosen over a full VM — lighter on RAM/CPU, near-instant boot, leaves more headroom for Home Assistant. Full kernel isolation of a VM isn't needed here.
- Snapshot the LXC in Proxmox before any major change.

## 3. Access model

- **Home LAN only.** No internet exposure, no public domain/DDNS, no public TLS.
- **Exception:** the server needs *outbound* internet to reach Apple's push service (APNs). This is one-way out; nothing is exposed inbound.

## 4. Chosen stack (optimised for easiest/quickest + self-maintaining)

| Layer | Choice | Why |
|-------|--------|-----|
| Container OS | **Debian 13 LXC** | Lean, well-supported, `unattended-upgrades` for auto OS patching |
| Backend | **Python + FastAPI** (Uvicorn) | Minimal code for this feature set; auto-generates API docs that make building the iOS client much easier |
| Database | **SQLite** | Zero DB admin; single file; backed up by LXC snapshot |
| Kitchen iPad | **Web dashboard** served by the backend, saved to the iPad home screen; live order updates via Server-Sent Events | No second app to build/maintain |
| Phone app | **SwiftUI**, built in Xcode, distributed via **TestFlight** | What you asked for; needed for real push notifications |
| Push notifications | **Apple APNs** | Only reliable way to notify a backgrounded iPhone |
| Transport (LAN) | HTTP on LAN + an App Transport Security exception in the iOS app for the server's LAN host | Simplest. Can harden to local HTTPS later |
| OS maintenance | `unattended-upgrades` on the LXC (automatic) | Meets "update/maintain itself" for the OS |
| Backups | Proxmox scheduled backup job for the LXC | One-click restore |

### What self-maintains vs what doesn't
- **Automatic:** container OS security updates.
- **Manual:** your own app code (you deploy when you change it), and the **TestFlight build** (rebuild every ~90 days — expected).
- **Separate:** the Proxmox *host* itself updates on its own schedule (not the container's) — we'll note the no-subscription repo setup so it doesn't nag.

## 5. Prerequisites / costs

- **Apple Developer Program** — ~£79/year (UK). Required for **both** APNs push *and* TestFlight distribution. ⚠️ Confirm whether you already have this.
- Xcode on a Mac (you have long-term Mac proficiency — fine).
- A spare LAN IP to reserve as the container's static address.

## 6. Data model (as built, v0.9.0 / migration 007)

- **users** — id, device_uuid (keychain UUID), name, created_at (no passwords; see HANDOFF §3)
- **sauces** — id, name, colour (`#rrggbb` the app paints; `''` = no sauce layer), active, sort_order. Seeded: Tomato, BBQ, Garlic & herb, Pesto, No sauce
- **toppings** — id, name, active, style (how the app draws it), image/image_type/image_hash (owner-uploaded photo, stored in the DB), sort_order, deleted
- **pizzas** — id, name, description, active, sauce_id (default sauce), sort_order (menu order), deleted; base toppings via pizza_toppings, each with left_amount/right_amount (0 none, 1 normal, 2 double)
- **favourites** — user_id → pizza_id + added/removed + sauce_id (NULL = the pizza's usual sauce), or toppings_json when the halves were changed; pizza_id NULL = a build-your-own favourite (sauce_id + toppings_json; v0.9.0)
- **suggestions** — a build-your-own pizza sent from the app as a menu idea: user_id, name, sauce_id, toppings_json, status new/added/dismissed, pizza_id it became (v0.9.0)
- **orders** — id, user_id, status (`new` → `preparing` → `ready` → `collected`; shown as Pending / Baking / Ready / Collected), note, timestamps
- **order_items** — pizza_id (NULL = build your own), sauce_id, added/removed (menu pizzas), toppings `[{id, side: whole|left|right, extra}]` (build your own, or a menu pizza whose halves were changed; a topping may appear once per half, e.g. double left + normal right)
- "Deleted" pizzas and toppings stay in their tables (order history refers to them) but are hidden everywhere else
- **devices** — user_id → APNs device token + environment (for push)

## 7. Security notes

- 🔴 **`root/root` on Proxmox must be changed immediately** and the credentials treated as compromised (they were shared in chat).
- LAN-only means low exposure, but still use a real password for the pizza-app accounts, not shared/blank ones.
- The container runs unprivileged where possible. Inside it, the app runs as the non-root user `pizza` (since 2026-11-08).

## 8. Open questions / blockers

1. **Apple Developer account** — do you already have one? (Blocks push + TestFlight.)
2. **Proxmox resources** — pending output of the sizing command (CPU/RAM/storage + existing CTs/VMs).
3. **LXC creation method** — recommend a clean manual Debian template create (I'll give exact steps) over community helper scripts, so you understand each step. Confirm OK.
4. **Container hostname + reserved IP** — e.g. `pizza-app` at a static `192.168.0.x`.

## 9. Working method

- Claude writes the code and deploys it to CT 101 over SSH as the unprivileged `pizza` user. Its only sudo right is restarting the service (set up 2026-11-08; see HANDOFF §2).
- Claude takes CT 101 **snapshots** itself (since 2026-11-09) through a Proxmox API token that can only snapshot CT 101 (`claude@pve!snap`; HANDOFF §2). It never deletes or rolls back snapshots.
- **Jason runs** anything else on the Proxmox host or as root: rollbacks, backups, `apt`, unit changes. Claude never logs into the Proxmox host. Each command block is labelled with where it runs and how to get there.
- Proceed in order: size the box → create LXC → stand up the backend + kitchen dashboard → confirm it works in a browser → then build the iOS app.

## 9a. As-built facts (live environment)

- **Proxmox host:** pve-manager 8.4.16, kernel 6.8.12-18-pve. Intel i3-6100T (4 threads), 15 GB RAM (~11 GB free), hostname `ha`.
- **Existing:** VM 100 = Home Assistant (HAOS 17.0) at `192.168.0.210:8123`. Untouched.
- **Storage:** container disk on `local-lvm` (223 GB free). NFS `Synology` store avoided (91% full).
- **Pizza container:** CT **101**, hostname `pizza-app`, Debian 13.6, unprivileged, nesting on, 2 cores / 2 GB RAM / 512 MB swap / 8 GB disk, `--onboot 1`.
- **Network:** static **192.168.0.50/24**, gw/DNS `192.168.0.1`, bridge `vmbr0`. ⚠️ TODO: add a DHCP reservation for `.50` on the router to pin it.
- **App path:** `/opt/pizza-app`, Python 3.13 venv at `/opt/pizza-app/venv`, FastAPI (`fastapi[standard]`) + uvicorn, SQLite 3.46.
- **Service:** `pizza-app.service` (systemd) → `uvicorn main:app --host 0.0.0.0 --port 8000`, `Restart=always`, enabled on boot.
- **Auto-updates:** `unattended-upgrades` enabled in the container.
- **Reachable at:** `http://192.168.0.50:8000` (`/` landing, `/health`, `/docs`).

## 10. Status

- [x] Hosting target chosen (Proxmox LXC)
- [x] Stack chosen
- [x] Proxmox sized
- [x] `root` password changed (Proxmox host + container)
- [x] Apple Developer account confirmed (Jason already has one)
- [x] LXC created (CT 101 @ 192.168.0.50)
- [x] Base system + auto-updates + FastAPI running as a service
- [x] Database schema created + starter data loaded (12 toppings, 2 pizzas)
- [x] Identity model decided: hybrid — first name + keychain UUID (survives reinstalls; not IDFV)
- [x] Build handed off to Claude Code (see `HANDOFF.md`)
- [ ] Router DHCP reservation for 192.168.0.50
- [x] `users` → keychain-UUID schema (migration 001; see HANDOFF §3)
- [x] Menu/toppings API + admin edit page (`/admin`): deployed live as v0.2.0 on 2026-11-08
- [x] Accounts (register/devices) & favourites API: live as v0.3.0 on 2026-11-08
- [x] Orders API + kitchen order/status API: live as v0.3.0 on 2026-11-08
- [x] Kitchen iPad dashboard (`/kitchen`) + SSE live updates: live as v0.4.0 on 2026-11-08
- [ ] Add `/kitchen` to the iPad home screen (Safari → Share → Add to Home Screen)
- [x] APNs push ("order ready"): code live as v0.5.0 on 2026-11-08 (HANDOFF §6)
- [x] APNs key + Bundle ID (`com.aspinalljason.familypizza`) created and placed in `/etc/pizza-app/`; `apns_check.py` passes on both environments (2026-11-08)
- [x] iOS app built (SwiftUI, `ios/`, XcodeGen) and tested in the simulator, 2026-11-09 (HANDOFF §7)
- [x] App run on a real iPhone; push received; tapping it opens My orders (2026-11-09; notification-tap crash found and fixed)
- [x] TestFlight: App Store Connect record, build 1.0 (1) uploaded, installed on Jason's phone, production push verified (2026-11-09)
- [x] Family members invited to the TestFlight "Family" group and installed (2026-11-09)
- [x] **v0.6.0 server** written and tested locally (2026-11-09): sauces, topping photos (admin upload, stored in DB, cached by the app), topping draw styles, build-your-own with half toppings, per-order live stream for the tracker, kitchen shows sauce + halves, columns renamed Pending / Baking / Ready. Migration 004 (HANDOFF §4, §8 step 8)
- [x] **v0.6.0 deployed live** 2026-11-09 (snapshot `pre_v060`; migration 004 applied, backup `pizza.db.bak-20261109-141438-pre004`; rollback copies `*.v0.5.1` / `*.v0.5`)
- [x] **iOS 1.1 (2)** written and tested in the simulator against v0.6.0 (2026-11-09): live pizza picture, sauce picker, topping photos, Build your own with half-and-half, order tracker, new App Store icon (HANDOFF §7)
- [x] **v0.7.0 live** 2026-11-09: owner sets the order of pizzas and toppings in `/admin` and can delete them; build-your-own toppings can be double on one half (migration 005, snapshot `pre_v070`)
- [x] **iOS 1.1 (3)** (2026-11-09): tap ◐ ● ◑ to cycle none → normal → double, with a glow and "2×" on doubles; Build your own at the top of the menu
- [ ] iOS 1.1 (3) uploaded to TestFlight (server is ready for it; 1.1 (2) was never uploaded)
- [ ] Real topping photos uploaded at `/admin` (until then the app shows drawn icons)
- [x] **v0.8.0 server + iOS 1.2 (4)** written and tested locally (2026-11-09): half-and-half and double base toppings on menu pizzas (admin ◐ ● ◑ per topping, kitchen shows halves, app customises per half), admin toppings as a tile grid. Migration 006 (HANDOFF §4 v0.8.0, §8 step 10)
- [x] **v0.8.0 live** 2026-11-09 16:04 (snapshot `pre_v080`; migration 006 applied, backup `pizza.db.bak-20261109-160453-pre006`; rollback copies `*.v0.7*`)
- [x] Cheese in its own section, like the sauce, in the admin pizza dialog and the app (any topping that "Looks like" Cheese); `admin.html` live 2026-11-09 16:21; app part ships with 1.2 (4)
- [x] **v0.9.0 server + app**: build-your-own favourites (☆ on Build your own) and menu suggestions (app → `/admin` Suggestions, Add to menu / Dismiss); written and tested locally 2026-11-09, migration 007 (HANDOFF §4 v0.9.0, §8 step 11)
- [x] **v0.9.0 live** 2026-11-09 16:44 (snapshot `pre_v090`; migration 007 applied, backup `pizza.db.bak-20261109-164423-pre007`; rollback copies `*.v0.8*`)
- [x] iOS 1.2 (4) uploaded to TestFlight 2026-11-09 17:42 (instead of 1.1 (3); needs v0.9.0). Also adds a launch splash with the version number, and a centred Menu title
- [x] 1.2 (4) distributed to the "Family" TestFlight group; working on the family's phones (2026-11-09)
- [x] Source on GitHub: https://github.com/chilled35/FamilyPizza (public; no keys). Fresh-server guide: `docs/SERVER_SETUP.md`
