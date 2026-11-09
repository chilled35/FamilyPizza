"""Apple Push Notification service client (token-based auth, HTTP/2).

Config lives outside the app directory, written by root and readable by the
`pizza` service user (see HANDOFF.md §6):

  /etc/pizza-app/apns.json      {"key_id": "...", "team_id": "...", "topic": "<bundle id>",
                                 "key_path": "/etc/pizza-app/AuthKey_<KEYID>.p8"}
  /etc/pizza-app/AuthKey_*.p8   the APNs auth key downloaded from Apple

No config file = push disabled (logged, never an error for the caller).
PIZZA_APNS_CONFIG overrides the path (local testing).
"""
import json
import logging
import os
import threading
import time
from dataclasses import dataclass
from pathlib import Path

import httpx
import jwt

log = logging.getLogger("pizza.apns")

CONFIG_PATH = Path(os.environ.get("PIZZA_APNS_CONFIG", "/etc/pizza-app/apns.json"))
HOSTS = {
    "production": "https://api.push.apple.com",       # TestFlight / App Store builds
    "sandbox": "https://api.sandbox.push.apple.com",  # builds run from Xcode
}
TOKEN_TTL_SECONDS = 45 * 60  # Apple: reuse the JWT, refresh it between 20 and 60 minutes

# Responses meaning "this device token will never work again": drop it from the DB.
# The app re-registers its token on every launch, so a wrongly dropped token comes back.
DEAD_TOKEN_REASONS = {"BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic", "ExpiredToken"}


@dataclass(frozen=True)
class ApnsConfig:
    key_id: str
    team_id: str
    topic: str
    key_pem: str


def load_config(path: Path | None = None) -> ApnsConfig | None:
    """Read the config + key. None (with a log line) if push is not set up or the config is broken."""
    path = path or CONFIG_PATH
    if not path.is_file():
        return None
    try:
        raw = json.loads(path.read_text())
        missing = [k for k in ("key_id", "team_id", "topic", "key_path") if not raw.get(k)]
        if missing:
            raise ValueError(f"missing {missing}")
        key_pem = Path(raw["key_path"]).read_text()
        return ApnsConfig(raw["key_id"].strip(), raw["team_id"].strip(), raw["topic"].strip(), key_pem)
    except Exception as e:  # noqa: BLE001 - any config problem disables push, never crashes the app
        log.error("APNs config %s unusable: %s", path, e)
        return None


@dataclass(frozen=True)
class PushResult:
    status: int            # HTTP status from Apple (200 = accepted)
    reason: str | None     # Apple's error reason, e.g. "BadDeviceToken"
    apns_id: str | None
    # Sandbox only: the ID to look up in Apple's Push Notifications Console delivery log
    # (icloud.developer.apple.com > Push Notifications > Delivery Log). Not the same as apns_id.
    unique_id: str | None = None

    @property
    def ok(self) -> bool:
        return self.status == 200

    @property
    def dead_token(self) -> bool:
        return self.status == 410 or self.reason in DEAD_TOKEN_REASONS


class ApnsClient:
    """One long-lived HTTP/2 connection to Apple, plus a cached provider JWT. Thread-safe."""

    def __init__(self, transport: httpx.BaseTransport | None = None) -> None:
        self._lock = threading.Lock()
        self._transport = transport
        self._http: httpx.Client | None = None
        self._jwt: str | None = None
        self._jwt_for: tuple[str, str] | None = None
        self._jwt_at = 0.0

    def _provider_token(self, cfg: ApnsConfig) -> str:
        now = time.time()
        if self._jwt and self._jwt_for == (cfg.key_id, cfg.team_id) and now - self._jwt_at < TOKEN_TTL_SECONDS:
            return self._jwt
        self._jwt = jwt.encode({"iss": cfg.team_id, "iat": int(now)}, cfg.key_pem,
                               algorithm="ES256", headers={"kid": cfg.key_id})
        self._jwt_for, self._jwt_at = (cfg.key_id, cfg.team_id), now
        return self._jwt

    def send(self, cfg: ApnsConfig, device_token: str, environment: str, payload: dict, *,
             collapse_id: str | None = None, expires_in: int | None = None) -> PushResult:
        """Send one alert push. Raises httpx.HTTPError on network failure."""
        headers = {
            "apns-topic": cfg.topic,
            "apns-push-type": "alert",
            "apns-priority": "10",
        }
        if collapse_id:
            headers["apns-collapse-id"] = collapse_id
        if expires_in:
            headers["apns-expiration"] = str(int(time.time()) + expires_in)
        url = f"{HOSTS[environment]}/3/device/{device_token}"
        with self._lock:  # pushes are rare; serialising keeps the JWT cache and connection simple
            headers["authorization"] = f"bearer {self._provider_token(cfg)}"
            if self._http is None:
                self._http = httpx.Client(http2=True, timeout=10, transport=self._transport)
            r = self._http.post(url, json=payload, headers=headers)
            reason = None
            if r.content:
                try:
                    reason = r.json().get("reason")
                except ValueError:
                    reason = r.text[:200]
            if r.status_code == 403 and reason in ("ExpiredProviderToken", "InvalidProviderToken"):
                self._jwt = None  # mint a fresh one next time
        return PushResult(r.status_code, reason, r.headers.get("apns-id"), r.headers.get("apns-unique-id"))


client = ApnsClient()
