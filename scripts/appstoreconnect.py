"""Minimal App Store Connect API client shared by Pelu's scripts.

Requires Python's cryptography package. Credentials stay in the ignored
`.appstoreconnect.local.json`; relative key paths resolve from its directory.
Never print the configuration or the private key.
"""
import base64
import json
import time
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

API_ROOT = "https://api.appstoreconnect.apple.com/v1/"
CONFIG_PATH = Path(__file__).resolve().parent.parent / ".appstoreconnect.local.json"


class APIError(Exception):
    def __init__(self, status, errors):
        self.status = status
        self.errors = errors
        details = "; ".join(e.get("detail") or e.get("title") or e.get("code", "") for e in errors)
        super().__init__(f"App Store Connect returned HTTP {status}" + (f": {details}" if details else ""))


def _b64(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


class Client:
    def __init__(self):
        config = json.loads(CONFIG_PATH.read_text())
        key_path = Path(config["private_key_path"]).expanduser()
        if not key_path.is_absolute():
            key_path = CONFIG_PATH.parent / key_path
        key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
        if not isinstance(key, ec.EllipticCurvePrivateKey) or not isinstance(key.curve, ec.SECP256R1):
            raise ValueError("Expected a P-256 App Store Connect private key")
        self._key = key
        self._key_id = config["key_id"]
        self._issuer_id = config["issuer_id"]
        self.bundle_id = config["bundle_id"]
        self._token = None
        self._token_issued = 0

    def _bearer(self):
        now = int(time.time())
        if self._token is None or now - self._token_issued > 240:
            header = {"alg": "ES256", "kid": self._key_id, "typ": "JWT"}
            payload = {"iss": self._issuer_id, "iat": now, "exp": now + 300,
                       "aud": "appstoreconnect-v1"}
            message = ".".join(_b64(json.dumps(part, separators=(",", ":")).encode())
                               for part in (header, payload))
            r, s = decode_dss_signature(self._key.sign(message.encode(), ec.ECDSA(hashes.SHA256())))
            self._token = message + "." + _b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
            self._token_issued = now
        return self._token

    def request(self, method, path, params=None, body=None):
        url = API_ROOT + path + ("?" + urlencode(params) if params else "")
        headers = {"Authorization": "Bearer " + self._bearer()}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        try:
            with urlopen(Request(url, data=data, method=method, headers=headers), timeout=30) as response:
                raw = response.read()
        except HTTPError as error:
            try:
                errors = json.loads(error.read()).get("errors", [])
            except ValueError:
                errors = []
            raise APIError(error.code, errors) from None
        return json.loads(raw) if raw else None

    def get(self, path, params=None):
        return self.request("GET", path, params)["data"]

    def app(self):
        apps = self.get("apps", {"filter[bundleId]": self.bundle_id, "limit": 2})
        if len(apps) != 1:
            raise ValueError("Expected exactly one accessible app with the configured bundle ID")
        return apps[0]
