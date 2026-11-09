# Family Pizza server: setting up the Proxmox container from scratch

This builds the box the app talks to: a small Debian LXC container on Proxmox running the
FastAPI server (`server/`) with SQLite, as a systemd service on port 8000. It is the same
setup as the live container (CT 101, `192.168.0.50`); the systemd files in
[`server/deploy/`](../server/deploy) are copied from it.

Every command block says **where it runs**:

- **Mac**: Terminal on your Mac, in your clone of this repo.
- **Proxmox host**: `root@<host>` shell. Use the web UI (node → **Shell**) or `ssh root@<proxmox-ip>`.
- **Container (root)**: from the Proxmox host shell, `pct enter 101`. `exit` gets you back to the host.
- **Container (pizza)**: from a container root shell, `su - pizza`. `exit` gets you back to root.

Values used below (change to suit your network):

| Thing | Value |
|---|---|
| Container ID | `101` |
| Hostname | `pizza-app` |
| IP / gateway / DNS | `192.168.0.50/24` / `192.168.0.1` / `192.168.0.1` |
| Bridge | `vmbr0` |
| Storage | `local-lvm` |
| Size | 2 cores, 2 GB RAM, 512 MB swap, 8 GB disk |
| App directory | `/opt/pizza-app` |
| Service user | `pizza` |
| Port | `8000` (plain HTTP, home LAN only) |

The app is **LAN-only by design**: nothing is exposed to the internet. The only outbound
traffic it needs is to Apple's push servers (`api.push.apple.com`, port 443).

---

## 1. Get a Debian 13 template

**Proxmox host**

```bash
pveam update
pveam available --section system | grep debian-13
```

Download the `debian-13-standard_…_amd64.tar.zst` name the last command printed:

```bash
pveam download local debian-13-standard_13.1-2_amd64.tar.zst
```

(The version in the file name changes over time; use the one listed.)

## 2. Create and start the container

**Proxmox host**

```bash
pct create 101 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
  --hostname pizza-app \
  --unprivileged 1 --features nesting=1 \
  --cores 2 --memory 2048 --swap 512 \
  --rootfs local-lvm:8 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.0.50/24,gw=192.168.0.1 \
  --nameserver 192.168.0.1 \
  --onboot 1
pct start 101
pct enter 101
```

You are now root inside the container. Set its root password:

**Container (root)**

```bash
passwd
```

On your router, add a **DHCP reservation** (or exclude `.50` from the DHCP pool) so nothing
else is ever handed that address.

## 3. Base system and automatic security updates

**Container (root)**

```bash
apt update && apt full-upgrade -y
apt install -y python3 python3-venv sqlite3 openssh-server ca-certificates curl unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now ssh
```

Check: `python3 --version` should be 3.13.x.

## 4. The `pizza` user and app directory

The service runs as an unprivileged `pizza` user, which also owns the code and the database.

**Container (root)**

```bash
adduser --disabled-password --gecos "" pizza
usermod -aG systemd-journal pizza      # lets it read the service logs
mkdir -p /opt/pizza-app
chown pizza:pizza /opt/pizza-app
```

Allow `pizza` to restart the service and nothing else (file in
[`server/deploy/sudoers-pizza`](../server/deploy/sudoers-pizza)):

```bash
apt install -y sudo
echo 'pizza ALL=(root) NOPASSWD: /usr/bin/systemctl restart pizza-app' > /etc/sudoers.d/pizza
chmod 440 /etc/sudoers.d/pizza
visudo -cf /etc/sudoers.d/pizza
```

## 5. SSH key for deploying from the Mac

**Mac**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/pizza_deploy -C pizza-deploy
cat ~/.ssh/pizza_deploy.pub
```

Copy the printed line, then:

**Container (root)**

```bash
mkdir -p /home/pizza/.ssh
nano /home/pizza/.ssh/authorized_keys     # paste the line, save
chown -R pizza:pizza /home/pizza/.ssh
chmod 700 /home/pizza/.ssh && chmod 600 /home/pizza/.ssh/authorized_keys
```

Add a short alias so `ssh pizza` works:

**Mac**

```bash
cat >> ~/.ssh/config <<'EOF'

Host pizza
    HostName 192.168.0.50
    User pizza
    IdentityFile ~/.ssh/pizza_deploy
    IdentitiesOnly yes
EOF
ssh pizza 'whoami'
```

The last command should print `pizza`.

## 6. Copy the server code

**Mac** (in the repo folder)

```bash
scp server/main.py server/apns.py server/apns_check.py server/admin.html server/kitchen.html \
    server/schema.sql server/requirements.txt server/migrate_*.py pizza:/opt/pizza-app/
```

## 7. Python environment and database

**Container (pizza)**

```bash
cd /opt/pizza-app
python3 -m venv venv
./venv/bin/pip install --upgrade pip
./venv/bin/pip install -r requirements.txt
sqlite3 pizza.db < schema.sql
sqlite3 pizza.db '.tables'
```

`.tables` should list `devices favourites order_items orders pizza_toppings pizzas sauces suggestions toppings users`.

`schema.sql` is always the current shape, so a **new** database needs no migrations. The
`migrate_00N_*.py` scripts only upgrade an older existing database (see §12).

## 8. The systemd service

Three files, all in [`server/deploy/`](../server/deploy):

- `pizza-app.service`: runs uvicorn on port 8000 and restarts it if it stops.
- `pizza-app.service.d/user.conf`: runs it as `pizza`.
- `pizza-app.service.d/shutdown.conf`: adds `--timeout-graceful-shutdown 3`. Without it, a
  restart hangs for 90 s whenever the kitchen iPad is connected (its live stream never closes).

Copy them over:

**Mac**

```bash
scp server/deploy/pizza-app.service pizza:/tmp/
scp server/deploy/pizza-app.service.d/*.conf pizza:/tmp/
```

**Container (root)**

```bash
mv /tmp/pizza-app.service /etc/systemd/system/
mkdir -p /etc/systemd/system/pizza-app.service.d
mv /tmp/user.conf /tmp/shutdown.conf /etc/systemd/system/pizza-app.service.d/
chown -R root:root /etc/systemd/system/pizza-app.service /etc/systemd/system/pizza-app.service.d
systemctl daemon-reload
systemctl enable --now pizza-app
systemctl status pizza-app --no-pager
```

## 9. Check it works

**Mac**

```bash
curl -s http://192.168.0.50:8000/health
```

It should print `{"status":"ok"}`. Then open these in a browser on the home network:

- `http://192.168.0.50:8000/admin`: the owner's page (menu, toppings, sauces, photos, suggestions).
- `http://192.168.0.50:8000/kitchen`: the kitchen dashboard. On the iPad: Safari → Share → **Add to Home Screen**.
- `http://192.168.0.50:8000/docs`: the API.

Logs:

**Container (pizza)**

```bash
journalctl -u pizza-app -f
```

## 10. Push notifications (APNs)

The "your pizza is ready" push needs an APNs key from your Apple Developer account. Without
it everything else works; the log just says `push not configured, skipped`.

1. On developer.apple.com: **Certificates, IDs & Profiles → Keys → +**. Tick **Apple Push
   Notifications service (APNs)**, environment **Sandbox & Production**. Download the
   `AuthKey_<KEYID>.p8`. **Apple lets you download it once**, so keep a copy somewhere safe
   (never in git: `.gitignore` already excludes `*.p8` and `Certs&Keys/`).
2. Note the **Key ID**, your **Team ID**, and the app's **bundle ID** (`PRODUCT_BUNDLE_IDENTIFIER` in `ios/project.yml`).

**Mac**

```bash
scp "Certs&Keys/AuthKey_<KEYID>.p8" pizza:/tmp/
```

**Container (root)**

```bash
mkdir -p /etc/pizza-app
mv /tmp/AuthKey_<KEYID>.p8 /etc/pizza-app/
nano /etc/pizza-app/apns.json     # see server/deploy/apns.json.example
chown -R root:pizza /etc/pizza-app
chmod 750 /etc/pizza-app
chmod 640 /etc/pizza-app/*
```

`apns.json`:

```json
{"key_id": "<KEYID>", "team_id": "<TEAMID>", "topic": "<bundle id>", "key_path": "/etc/pizza-app/AuthKey_<KEYID>.p8"}
```

It is read on every push, so no restart is needed. Check Apple accepts it:

**Container (pizza)**

```bash
cd /opt/pizza-app && ./venv/bin/python apns_check.py
```

`BadDeviceToken` for both production and sandbox means the key, team and bundle ID are
accepted (it deliberately sends to a made-up device). Once a phone has registered,
`./venv/bin/python apns_check.py --user <first name>` sends it a real test push.

## 11. Fill in the menu and point the app at the server

1. In `/admin`, add sauces (with a colour; a "No sauce" entry has a blank colour), toppings (pick a "Looks like" style, upload a
   photo; the ones in `Food Images/` work well), then pizzas.
2. The iPhone app's server address is in `ios/FamilyPizza/Config.swift`
   (`http://192.168.0.50:8000`). Change it there if you used a different IP, then rebuild.
3. Each phone asks for **Local Network** permission on first launch; it must be allowed.

## 12. Updating the server later

**Proxmox host**: snapshot first, so any update can be undone:

```bash
pct snapshot 101 pre_<version>
```

**Mac**: copy the changed files and restart:

```bash
scp server/main.py server/admin.html server/kitchen.html server/schema.sql pizza:/opt/pizza-app/
ssh pizza 'sudo systemctl restart pizza-app'
curl -s http://192.168.0.50:8000/health
```

If a release adds a migration, run it **before** the restart:

**Container (pizza)**

```bash
cd /opt/pizza-app && ./venv/bin/python migrate_00N_<name>.py
```

Each migration writes a `pizza.db.bak-<time>-pre00N` backup first, runs in one transaction,
and is safe to run twice. If `requirements.txt` changed, also run
`./venv/bin/pip install -r requirements.txt` before restarting.

To undo: **Proxmox host** `pct rollback 101 pre_<version>` (the container stops and comes back as it was).

## 13. Backups

`pizza.db` is the whole state (users, menu, photos, orders). Snapshots live on the same disk,
so also set up a real backup:

Proxmox web UI → **Datacenter → Backup → Add**: node, storage (anything not on the same disk),
schedule (e.g. daily 03:00), selection **101**, mode **Snapshot**, retention e.g. keep last 7.

One-off backup now:

**Proxmox host**

```bash
vzdump 101 --mode snapshot --storage <backup-storage> --compress zstd
```

## Optional: snapshot-only API token

Lets a script (or Claude Code) take snapshots of CT 101 without root on the host.

**Proxmox host**

```bash
pveum role add PizzaSnapshot --privs "VM.Snapshot,VM.Audit"
pveum user add claude@pve
pveum acl modify /vms/101 --users claude@pve --roles PizzaSnapshot
pveum user token add claude@pve snap --privsep 0
```

The last command prints the token secret once. Store it on the Mac as
`~/.config/pizza/pve-token` (mode 600), one line:
`Authorization: PVEAPIToken=claude@pve!snap=<secret>`. Then:

**Mac**

```bash
curl -s -k -H @$HOME/.config/pizza/pve-token -X POST --data-urlencode snapname=pre_test \
  https://<proxmox-ip>:8006/api2/json/nodes/<node>/lxc/101/snapshot
```

`-k` skips the self-signed certificate check; to be stricter, pin the host key with
`--pinnedpubkey`. To revoke: `pveum user delete claude@pve`.
