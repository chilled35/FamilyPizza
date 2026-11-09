# Family Pizza

A home-network pizza ordering system for one family:

- **iPhone app** (SwiftUI, via TestFlight): browse the menu, customise a pizza (sauce, toppings,
  whole or half, normal or double) with a live drawing of it, build your own, save favourites,
  order, and follow the order live (Pending → Baking → Ready).
- **Kitchen iPad page** (`/kitchen`): incoming orders update live; the cook moves them along.
- **Owner page** (`/admin`): menu, toppings with photos, sauces, and pizza suggestions from the family.
- **Push notification** to the phone when the order is ready.

The server is FastAPI + SQLite in a small Debian LXC container on Proxmox, reachable only on
the home LAN.

## Layout

| Path | What |
|---|---|
| `server/` | FastAPI app (`main.py`), APNs client, kitchen and admin pages, schema, migrations |
| `server/deploy/` | systemd unit, drop-ins, sudoers line and APNs config example for the container |
| `ios/` | iPhone app. The Xcode project is generated from `ios/project.yml` with XcodeGen |
| `Food Images/` | Source photos for the toppings (uploaded through `/admin`) |
| `docs/SERVER_SETUP.md` | Step-by-step Proxmox container setup |
| `docs/HANDOFF.md`, `docs/claude.md` | Design decisions, API contract and build log |

## Quick start

- **Server:** follow [docs/SERVER_SETUP.md](docs/SERVER_SETUP.md).
- **App:** `brew install xcodegen`, then `cd ios && xcodegen && open FamilyPizza.xcodeproj`.
  First `cp ios/Local.xcconfig.example ios/Local.xcconfig` and put your Apple Team ID in it
  (git ignores it). Set the bundle ID in `ios/project.yml` and the server address in
  `ios/FamilyPizza/Config.swift`.

Secrets (the APNs `.p8` key) are never committed: see `.gitignore`.
