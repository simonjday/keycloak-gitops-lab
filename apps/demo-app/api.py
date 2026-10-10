"""demo-api: a resource server that validates Keycloak access tokens.

- Offline validation: signature (JWKS), issuer, audience "demo-api", expiry.
- Authorisation: client roles in resource_access["demo-api"].roles ("reader", "admin").
- INTROSPECT=true additionally asks Keycloak whether the token is still active (immediate revocation).
"""
import json
import os
import threading
import time

import jwt
import requests
from flask import Flask, jsonify, request

ISSUER = os.environ["OIDC_ISSUER"]
AUDIENCE = os.environ.get("AUDIENCE", "demo-api")
CLIENT_ID = os.environ.get("CLIENT_ID", "demo-api")
CLIENT_SECRET = os.environ.get("CLIENT_SECRET", "")
INTROSPECT = os.environ.get("INTROSPECT", "false").lower() == "true"
JWKS_URL = f"{ISSUER}/protocol/openid-connect/certs"
INTROSPECT_URL = f"{ISSUER}/protocol/openid-connect/token/introspect"

app = Flask(__name__)
_jwks: dict = {"keys": None, "fetched": 0.0}
_lock = threading.Lock()


def log(event: str, **fields):
    print(json.dumps({"ts": int(time.time()), "app": "demo-api", "event": event, **fields}), flush=True)


def signing_key(kid: str):
    """Cached JWKS; refetch on unknown kid (key rotation) or after 10 minutes."""
    with _lock:
        stale = time.time() - _jwks["fetched"] > 600
        keys = _jwks["keys"]
        if keys is None or stale or kid not in {k.key_id for k in keys.keys}:
            keys = jwt.PyJWKSet.from_dict(requests.get(JWKS_URL, timeout=10).json())
            _jwks.update(keys=keys, fetched=time.time())
            log("jwks_refreshed", kids=[k.key_id for k in keys.keys])
        for k in keys.keys:
            if k.key_id == kid:
                return k.key
    raise jwt.InvalidTokenError(f"unknown kid {kid}")


def deny(status: int, reason: str, **extra):
    log("deny", status=status, reason=reason, **extra)
    return jsonify({"error": reason, **extra}), status


def authorize(required_role: str):
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return None, deny(401, "missing bearer token")
    token = auth[7:]
    try:
        kid = jwt.get_unverified_header(token).get("kid", "")
        claims = jwt.decode(token, signing_key(kid), algorithms=["RS256", "ES256", "PS256"],
                            audience=AUDIENCE, issuer=ISSUER, leeway=10)
    except jwt.ExpiredSignatureError:
        return None, deny(401, "token expired")
    except jwt.InvalidTokenError as e:
        return None, deny(401, f"invalid token: {e}")

    if INTROSPECT:
        r = requests.post(INTROSPECT_URL, data={"token": token}, auth=(CLIENT_ID, CLIENT_SECRET), timeout=10)
        if r.status_code != 200 or not r.json().get("active"):
            return None, deny(401, "token not active (introspection)", user=claims.get("preferred_username"))

    roles = claims.get("resource_access", {}).get(AUDIENCE, {}).get("roles", [])
    who = claims.get("preferred_username") or claims.get("client_id") or claims.get("sub")
    if required_role not in roles:
        return None, deny(403, f"requires role '{required_role}'", user=who, roles=roles)
    log("allow", user=who, role=required_role, introspect=INTROSPECT)
    return {"user": who, "roles": roles, "exp_in_seconds": claims["exp"] - int(time.time()),
            "validation": "jwks+introspection" if INTROSPECT else "jwks only"}, None


@app.get("/api/public")
def public():
    return jsonify({"message": "public endpoint, no token required"})


@app.get("/api/user")
def user():
    result, err = authorize("reader")
    return err or jsonify({"message": "reader access granted", **result})


@app.get("/api/admin")
def admin():
    result, err = authorize("admin")
    return err or jsonify({"message": "admin access granted", **result})


@app.get("/healthz")
def healthz():
    return {"status": "ok", "introspect": INTROSPECT}
