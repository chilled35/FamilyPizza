#!/usr/bin/env python3
"""Check the APNs setup, or send a test push.

  ./venv/bin/python apns_check.py                 # credentials check (no phone needed)
  ./venv/bin/python apns_check.py --user Jason    # real test push to that user's registered devices
  ./venv/bin/python apns_check.py --config PATH   # use another apns.json

The credentials check sends to a made-up device token on both Apple
environments. Apple checks the key, team and bundle ID before the token, so
"BadDeviceToken" means the credentials are good.
"""
import argparse
import sqlite3
import sys
from pathlib import Path

import httpx

import apns

DUMMY_TOKEN = "0" * 64

MEANING = {
    "BadDeviceToken": "OK: Apple accepted key, team and bundle ID (made-up token rejected as expected)",
    "InvalidProviderToken": "FAIL: key_id / team_id don't match the .p8 key, or the key was revoked",
    "ExpiredProviderToken": "FAIL: server clock is wrong (JWT looks expired)",
    "TopicDisallowed": "FAIL: this key may not push to that bundle ID (topic)",
    "BadTopic": "FAIL: bundle ID (topic) is not valid",
    "MissingTopic": "FAIL: topic missing from apns.json",
    "Forbidden": "FAIL: Apple refused the key (APNs not enabled for it?)",
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", type=Path, default=apns.CONFIG_PATH)
    ap.add_argument("--user", help="send a real test push to this user's devices (by first name)")
    ap.add_argument("--db", type=Path, default=Path(__file__).resolve().parent / "pizza.db")
    args = ap.parse_args()

    if not args.config.is_file():
        print(f"No APNs config at {args.config}: push is disabled.")
        return 1
    cfg = apns.load_config(args.config)
    if cfg is None:
        print("APNs config present but unusable (see error above).")
        return 1
    print(f"Config: key_id={cfg.key_id} team_id={cfg.team_id} topic={cfg.topic}")

    if args.user:
        conn = sqlite3.connect(args.db)
        rows = conn.execute(
            "SELECT d.token, d.environment FROM devices d JOIN users u ON u.id = d.user_id "
            "WHERE u.name = ? COLLATE NOCASE", (args.user,)).fetchall()
        if not rows:
            print(f"No registered devices for user '{args.user}'.")
            return 1
        payload = {"aps": {"alert": {"title": "Family Pizza test 🍕", "body": "Push notifications are working."},
                           "sound": "default"}}
        targets = [(token, env, payload) for token, env in rows]
    else:
        targets = [(DUMMY_TOKEN, env, {"aps": {"alert": "check"}}) for env in ("production", "sandbox")]

    ok = True
    for token, env, payload in targets:
        try:
            r = apns.client.send(cfg, token, env, payload)
        except httpx.HTTPError as e:
            print(f"[{env}] network error: {e}")
            ok = False
            continue
        if args.user:
            verdict = "sent" if r.ok else f"FAIL ({'token is dead' if r.dead_token else 'see reason'})"
        else:
            verdict = MEANING.get(r.reason, "unexpected; see reason")
        ok &= r.ok if args.user else r.reason == "BadDeviceToken"
        print(f"[{env}] …{token[-6:]} -> HTTP {r.status} {r.reason or ''}  {verdict}")
        if r.unique_id:
            print(f"    apns-unique-id {r.unique_id}  (look up in Apple's Push Notifications Console delivery log)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
