"""demo-web: a server-side web app that logs users in with Keycloak (authorization code + PKCE).

Shows: login, decoded ID/access tokens, group-based page authorisation, calling an API with the
access token, refresh, and RP-initiated logout. Tokens are kept server-side in memory, keyed by a
random session id in the cookie, so they never reach the browser. Single replica only.
"""
import base64
import json
import os
import secrets
import time

import requests
from authlib.integrations.flask_client import OAuth
from flask import Flask, abort, redirect, render_template, request, session, url_for
from werkzeug.middleware.proxy_fix import ProxyFix

ISSUER = os.environ["OIDC_ISSUER"]                  # https://keycloak.localtest.me/realms/platform
PUBLIC_URL = os.environ["PUBLIC_URL"].rstrip("/")   # https://demo.localtest.me
API_URL = os.environ["API_URL"].rstrip("/")         # http://demo-api:8080
CLIENT_ID = os.environ["CLIENT_ID"]
CLIENT_SECRET = os.environ["CLIENT_SECRET"]
ADMIN_GROUP = os.environ.get("ADMIN_GROUP", "Platform Engineers")
# requests (and therefore Authlib) honours REQUESTS_CA_BUNDLE for the lab CA

app = Flask(__name__)
app.wsgi_app = ProxyFix(app.wsgi_app, x_proto=1, x_host=1)   # Envoy terminates TLS
app.secret_key = os.environ["SESSION_SECRET"]
app.config.update(SESSION_COOKIE_SECURE=True, SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE="Lax")

oauth = OAuth(app)
oauth.register(
    "keycloak",
    client_id=CLIENT_ID,
    client_secret=CLIENT_SECRET,
    server_metadata_url=f"{ISSUER}/.well-known/openid-configuration",
    client_kwargs={"scope": "openid profile email groups", "code_challenge_method": "S256"},
)

TOKENS: dict[str, dict] = {}   # session id -> token response


def log(event: str, **fields):
    print(json.dumps({"ts": int(time.time()), "app": "demo-web", "event": event, **fields}), flush=True)


def decode(jwt_str: str | None) -> dict:
    """Display-only decode of a JWT payload. The API does the real signature validation."""
    if not jwt_str:
        return {}
    payload = jwt_str.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))


def current_tokens() -> dict | None:
    sid = session.get("sid")
    return TOKENS.get(sid) if sid else None


def refresh(tokens: dict) -> dict:
    meta = oauth.keycloak.load_server_metadata()
    r = requests.post(meta["token_endpoint"], data={
        "grant_type": "refresh_token",
        "refresh_token": tokens["refresh_token"],
        "client_id": CLIENT_ID,
        "client_secret": CLIENT_SECRET,
    }, timeout=10)
    if r.status_code != 200:
        log("refresh_failed", status=r.status_code, body=r.text[:200])
        TOKENS.pop(session.get("sid"), None)
        session.clear()
        abort(401, "Refresh token rejected by Keycloak (session ended, user disabled, or expired). Log in again.")
    new = r.json()
    new["expires_at"] = int(time.time()) + int(new.get("expires_in", 0))
    TOKENS[session["sid"]] = new
    log("refreshed", user=decode(new.get("access_token")).get("preferred_username"))
    return new


def fresh_tokens() -> dict:
    tokens = current_tokens()
    if not tokens:
        abort(401, "Not logged in.")
    if tokens.get("expires_at", 0) - time.time() < 30:   # refresh 30 s before expiry
        tokens = refresh(tokens)
    return tokens


@app.get("/")
def index():
    tokens = current_tokens()
    user = decode(tokens.get("id_token")) if tokens else None
    return render_template("index.html", user=user)


@app.get("/login")
def login():
    return oauth.keycloak.authorize_redirect(f"{PUBLIC_URL}/callback")


@app.get("/callback")
def callback():
    token = oauth.keycloak.authorize_access_token()
    sid = secrets.token_urlsafe(24)
    token.setdefault("expires_at", int(time.time()) + int(token.get("expires_in", 0)))
    TOKENS[sid] = dict(token)
    session["sid"] = sid
    log("login", user=decode(token.get("id_token")).get("preferred_username"))
    return redirect(url_for("profile"))


@app.get("/profile")
def profile():
    tokens = current_tokens()
    if not tokens:
        return redirect(url_for("login"))
    now = int(time.time())
    return render_template(
        "profile.html",
        id_claims=decode(tokens.get("id_token")),
        access_claims=decode(tokens.get("access_token")),
        refresh_claims=decode(tokens.get("refresh_token")),
        now=now,
    )


@app.post("/refresh")
def refresh_now():
    tokens = current_tokens()
    if not tokens:
        return redirect(url_for("login"))
    refresh(tokens)
    return redirect(url_for("profile"))


@app.get("/admin")
def admin_page():
    tokens = current_tokens()
    if not tokens:
        return redirect(url_for("login"))
    claims = decode(tokens.get("id_token"))
    allowed = ADMIN_GROUP in claims.get("groups", [])
    log("admin_page", user=claims.get("preferred_username"), allowed=allowed)
    if not allowed:
        return render_template("result.html", title="Admin page", status=403,
                               body={"error": f"requires group '{ADMIN_GROUP}'", "your_groups": claims.get("groups", [])}), 403
    return render_template("result.html", title="Admin page", status=200,
                           body={"message": f"Welcome, member of {ADMIN_GROUP}", "groups": claims.get("groups", [])})


@app.get("/call/<endpoint>")
def call_api(endpoint: str):
    if endpoint not in {"public", "user", "admin"}:
        abort(404)
    headers = {}
    if endpoint != "public":
        headers["Authorization"] = f"Bearer {fresh_tokens()['access_token']}"
    r = requests.get(f"{API_URL}/api/{endpoint}", headers=headers, timeout=10)
    try:
        body = r.json()
    except ValueError:
        body = {"raw": r.text[:500]}
    return render_template("result.html", title=f"GET /api/{endpoint}", status=r.status_code, body=body), 200


@app.get("/logout")
def logout():
    tokens = current_tokens()
    meta = oauth.keycloak.load_server_metadata()
    TOKENS.pop(session.get("sid"), None)
    session.clear()
    params = {"post_logout_redirect_uri": f"{PUBLIC_URL}/", "client_id": CLIENT_ID}
    if tokens and tokens.get("id_token"):
        params["id_token_hint"] = tokens["id_token"]
    query = "&".join(f"{k}={requests.utils.quote(v, safe='')}" for k, v in params.items())
    return redirect(f"{meta['end_session_endpoint']}?{query}")


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.errorhandler(401)
def unauthorized(e):
    return render_template("result.html", title="Unauthorized", status=401, body={"error": e.description}), 401
