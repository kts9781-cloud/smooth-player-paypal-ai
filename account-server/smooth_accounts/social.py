"""Browser OIDC login. Provider tokens never cross the app callback URL.

An app-held S256 verifier redeems a short-lived, single-use result. Existing
accounts are linked only from an authenticated session, never by email alone.
"""
import base64
import hashlib
import hmac
import json
import re
import secrets
import time
import uuid
from functools import lru_cache
from urllib.parse import urlencode

import httpx
import jwt

from .security import digest
from .service import Failure

ENDPOINTS = {
    "google": ("https://accounts.google.com/o/oauth2/v2/auth", "https://oauth2.googleapis.com/token", "https://www.googleapis.com/oauth2/v3/certs"),
    "apple": ("https://appleid.apple.com/auth/authorize", "https://appleid.apple.com/auth/token", "https://appleid.apple.com/auth/keys"),
}


def s256(value):
    return base64.urlsafe_b64encode(hashlib.sha256(value.encode()).digest()).rstrip(b"=").decode()


@lru_cache(maxsize=2)
def key_client(provider):
    return jwt.PyJWKClient(ENDPOINTS[provider][2], timeout=10, lifespan=3600)


class IdentityProvider:
    def __init__(self, config):
        self.c = config

    def secret(self, provider):
        if provider == "google":
            return self.c.google_login_secret
        now = int(time.time())
        return jwt.encode({"iss": self.c.apple_login_team, "iat": now, "exp": now + 300,
                           "aud": "https://appleid.apple.com", "sub": self.c.apple_login_client},
                          self.c.apple_login_key_pem, algorithm="ES256", headers={"kid": self.c.apple_login_key_id})

    def validate(self, provider, token, nonce):
        if not isinstance(token, str) or len(token) > 16384:
            raise ValueError("Invalid ID token")
        key = key_client(provider).get_signing_key_from_jwt(token).key
        issuer = ["https://accounts.google.com", "accounts.google.com"] if provider == "google" else "https://appleid.apple.com"
        client = getattr(self.c, provider + "_login_client")
        value = jwt.decode(token, key, algorithms=["RS256"], audience=client, issuer=issuer, leeway=60,
                           options={"require": ["exp", "iat", "iss", "aud", "sub", "nonce"], "strict_aud": True})
        if not isinstance(value["sub"], str) or not 1 <= len(value["sub"]) <= 255:
            raise ValueError("Invalid subject")
        if value.get("azp", client) != client or not isinstance(value["nonce"], str) or not hmac.compare_digest(value["nonce"], nonce):
            raise ValueError("Invalid nonce or authorized party")
        email = value.get("email", "")
        if email:
            if (value.get("email_verified") is not True and value.get("email_verified") != "true") or not isinstance(email, str):
                raise ValueError("Unverified email")
            email = email.strip().lower()
            if len(email) > 254 or not re.fullmatch(r"[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+", email):
                raise ValueError("Invalid email")
        return {"subject": value["sub"], "email": email}

    def exchange(self, provider, code, data):
        body = {"client_id": getattr(self.c, provider + "_login_client"), "client_secret": self.secret(provider),
                "code": code, "grant_type": "authorization_code", "redirect_uri": data["redirect_uri"]}
        if provider == "google":
            body["code_verifier"] = data["provider_verifier"]
        response = httpx.post(ENDPOINTS[provider][1], data=body, timeout=15, follow_redirects=False)
        response.raise_for_status()
        if len(response.content) > 65536:
            raise ValueError("Oversized token response")
        tokens = response.json()
        identity = self.validate(provider, tokens.get("id_token"), data["nonce"])
        # Only retain the token needed for revocation, encrypted in the database.
        identity["revoke_token"] = tokens.get("refresh_token") or tokens.get("access_token") or ""
        if provider == "apple" and not identity["revoke_token"]:
            raise ValueError("Apple did not supply a revocable token")
        if not isinstance(identity["revoke_token"], str) or len(identity["revoke_token"]) > 16384:
            raise ValueError("Invalid revocation token")
        return identity

    def revoke(self, provider, token):
        if provider == "google":
            response = httpx.post("https://oauth2.googleapis.com/revoke", data={"token": token}, timeout=10, follow_redirects=False)
        else:
            response = httpx.post("https://appleid.apple.com/auth/revoke", data={"client_id": self.c.apple_login_client,
                "client_secret": self.secret(provider), "token": token}, timeout=10, follow_redirects=False)
        if response.status_code == 400 and response.json().get("error") == "invalid_token":
            return  # Already expired/revoked.
        response.raise_for_status()


class SocialAuth:
    def __init__(self, service):
        self.s = service
        self.provider = IdentityProvider(service.c)

    def available(self, provider):
        return provider in ENDPOINTS and getattr(self.s.c, provider + "_login_enabled")

    def configuration(self, user=None):
        linked = {r["provider"] for r in self.s.db.all("SELECT provider FROM social_identities WHERE user_id=?", (user["id"],))} if user else set()
        return {"providers": [{"id": p, "enabled": self.available(p), "linked": p in linked} for p in ENDPOINTS]}

    def payload(self, row):
        return json.loads(self.s.secrets.decrypt(row["payload"]))

    def start(self, provider, challenge, client, owner, owner_token, ip):
        if not self.available(provider):
            raise Failure(503, "이 로그인 서비스를 준비하고 있습니다. 이메일 로그인을 이용해 주세요.")
        if not re.fullmatch(r"[A-Za-z0-9_-]{43}", challenge) or client not in ("apple", "android", "web"):
            raise Failure(400, "로그인 요청을 확인해 주세요.")
        self.s.rate("social-start:" + digest(ip), 30, 3600)
        identifier, state, verifier = str(uuid.uuid4()), secrets.token_urlsafe(32), secrets.token_urlsafe(48)
        now = self.s.now()
        data = {"state": state, "nonce": secrets.token_urlsafe(32), "provider_verifier": verifier, "client": client,
                "owner_session": digest(owner_token) if owner else "",
                "redirect_uri": self.s.c.origin + "/v1/auth/social/callback/" + provider}
        with self.s.db.transaction() as db:
            db.execute("DELETE FROM social_attempts WHERE expires<=?", (now,))
            db.execute("INSERT INTO social_attempts VALUES(?,?,?,?,?,?,?,'pending','',?)",
                       (identifier, digest(state), provider, challenge, owner["id"] if owner else None, now, now + 600,
                        self.s.secrets.encrypt(json.dumps(data))))
        return {"id": identifier, "authorizationURL": self.s.c.origin + "/v1/auth/social/browser/" + identifier, "expiresAt": now + 600}

    def browser(self, identifier):
        browser = secrets.token_urlsafe(32)
        with self.s.db.transaction() as db:
            row = db.execute("SELECT * FROM social_attempts WHERE id=?", (identifier,)).fetchone()
            if not row or row["expires"] <= self.s.now() or row["status"] != "pending" or not self.available(row["provider"]):
                raise Failure(400, "로그인 요청이 만료되었거나 이미 열렸습니다. 앱에서 다시 시작해 주세요.")
            db.execute("UPDATE social_attempts SET status='started',browser_digest=? WHERE id=?", (digest(browser), identifier))
        data, provider = self.payload(row), row["provider"]
        query = {"client_id": getattr(self.s.c, provider + "_login_client"), "redirect_uri": data["redirect_uri"],
                 "response_type": "code", "scope": "openid email" if provider == "google" else "email",
                 "state": data["state"], "nonce": data["nonce"]}
        if provider == "google":
            query.update(code_challenge=s256(data["provider_verifier"]), code_challenge_method="S256", prompt="select_account")
        else:
            query["response_mode"] = "form_post"
        return ENDPOINTS[provider][0] + "?" + urlencode(query), browser

    @staticmethod
    def cookie_name(identifier):
        return "smooth-social-" + identifier

    def callback(self, provider, fields, cookies):
        state = fields.get("state", "")
        if provider not in ENDPOINTS or not isinstance(state, str) or len(state) > 128:
            raise Failure(400, "로그인 응답을 확인하지 못했습니다.")
        with self.s.db.transaction() as db:
            row = db.execute("SELECT * FROM social_attempts WHERE state_digest=?", (digest(state),)).fetchone()
            if (not row or row["provider"] != provider or row["status"] != "started" or row["expires"] <= self.s.now()
                    or not hmac.compare_digest(row["browser_digest"], digest(cookies.get(self.cookie_name(row["id"]), "")))):
                raise Failure(400, "로그인을 시작한 브라우저에서 다시 시도해 주세요.")
            db.execute("UPDATE social_attempts SET status='exchanging' WHERE id=?", (row["id"],))
        data = self.payload(row)
        try:
            code = fields.get("code", "")
            if fields.get("error") or not isinstance(code, str) or not 1 <= len(code) <= 4096:
                raise Failure(400, "로그인이 취소되었거나 완료되지 않았습니다.")
            data["identity"] = self.provider.exchange(provider, code, data)
            status = "ready"
        except Exception:
            # Never echo provider errors, codes or tokens to browsers/logs.
            data["error"] = "로그인이 취소되었거나 인증을 확인하지 못했습니다. 다시 시도해 주세요."
            status = "error"
        with self.s.db.transaction() as db:
            db.execute("UPDATE social_attempts SET status=?,payload=? WHERE id=? AND status='exchanging'",
                       (status, self.s.secrets.encrypt(json.dumps(data)), row["id"]))
        return row["id"], data["client"]

    def complete(self, identifier, verifier, ip):
        if not re.fullmatch(r"[A-Za-z0-9._~-]{43,128}", verifier):
            raise Failure(400, "로그인 요청을 확인해 주세요.")
        self.s.rate("social-complete:" + digest(ip), 120, 600)
        failure = None
        with self.s.db.transaction() as db:
            row = db.execute("SELECT * FROM social_attempts WHERE id=?", (identifier,)).fetchone()
            if not row or row["expires"] <= self.s.now() or not hmac.compare_digest(row["challenge"], s256(verifier)):
                raise Failure(401, "로그인 요청이 만료되었거나 일치하지 않습니다.")
            if row["status"] in ("pending", "started", "exchanging"):
                return {"status": "pending"}
            if row["status"] == "consumed":
                raise Failure(401, "이미 사용한 로그인 응답입니다. 다시 로그인해 주세요.")
            data = self.payload(row)
            db.execute("UPDATE social_attempts SET status='consumed',payload='' WHERE id=?", (identifier,))
            if row["status"] == "error":
                failure = data["error"]
            else:
                value, provider = data["identity"], row["provider"]
                old = db.execute("SELECT deleted FROM social_deleted_identities WHERE digest=?", (digest(provider + ":" + value["subject"]),)).fetchone()
                identity = db.execute("SELECT * FROM social_identities WHERE provider=? AND subject=?", (provider, value["subject"])).fetchone()
                owner = row["owner_id"]
                if old and row["created"] <= old[0]:
                    failure = "삭제된 계정의 로그인 요청입니다. 앱에서 다시 시작해 주세요."
                elif owner:
                    active = db.execute("SELECT 1 FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.digest=? AND s.user_id=? AND s.expires>? AND u.deleted=0",
                                        (data["owner_session"], owner, self.s.now())).fetchone()
                    other = db.execute("SELECT subject FROM social_identities WHERE user_id=? AND provider=?", (owner, provider)).fetchone()
                    if not active or (identity and identity["user_id"] != owner) or (other and other[0] != value["subject"]):
                        failure = "계정이 변경되었거나 다른 계정에 연결된 로그인입니다."
                elif identity:
                    owner = identity["user_id"]
                elif not value["email"]:
                    failure = "이메일 계정으로 먼저 로그인한 뒤 로그인 방식을 연결해 주세요."
                elif db.execute("SELECT 1 FROM users WHERE email=?", (value["email"],)).fetchone():
                    failure = "이 이메일의 기존 계정이 있습니다. 이메일로 로그인한 뒤 Google·Apple 연결을 눌러 주세요."
                else:
                    owner = str(uuid.uuid4())
                    db.execute("INSERT INTO users VALUES(?,?,?,0)", (owner, value["email"], self.s.now()))
                if not failure:
                    user = db.execute("SELECT * FROM users WHERE id=? AND deleted=0", (owner,)).fetchone()
                    if not user:
                        failure = "계정을 사용할 수 없습니다. 다시 로그인해 주세요."
                    else:
                        revoke = value["revoke_token"]
                        sealed = self.s.secrets.encrypt(revoke) if revoke else (identity["revoke_token"] if identity else "")
                        db.execute("INSERT INTO social_identities VALUES(?,?,?,?,?) ON CONFLICT(provider,subject) DO UPDATE SET revoke_token=excluded.revoke_token",
                                   (provider, value["subject"], owner, sealed, self.s.now()))
                        token = secrets.token_urlsafe(48)
                        expires = self.s.now() + 30 * 86400
                        db.execute("INSERT INTO sessions VALUES(?,?,?)", (digest(token), owner, expires))
                        result = {"token": token, "userId": owner, "email": user["email"], "expiresAt": expires}
        if failure:
            raise Failure(409, failure)
        return {"status": "complete", "session": result}

    def queue_deletion(self, db, owner):
        for row in db.execute("SELECT * FROM social_identities WHERE user_id=?", (owner,)).fetchall():
            if row["revoke_token"]:
                db.execute("INSERT INTO social_revocations VALUES(?,?,?,?)", (str(uuid.uuid4()), row["provider"], row["revoke_token"], self.s.now()))
            db.execute("INSERT INTO social_deleted_identities VALUES(?,?) ON CONFLICT(digest) DO UPDATE SET deleted=excluded.deleted",
                       (digest(row["provider"] + ":" + row["subject"]), self.s.now()))
        db.execute("DELETE FROM social_identities WHERE user_id=?", (owner,))
        db.execute("DELETE FROM social_attempts WHERE owner_id=?", (owner,))

    def revoke_pending(self, deadline):
        failures = 0
        for row in self.s.db.all("SELECT * FROM social_revocations ORDER BY created LIMIT 5"):
            if time.monotonic() >= deadline:
                break
            try:
                self.provider.revoke(row["provider"], self.s.secrets.decrypt(row["token"]))
                with self.s.db.transaction() as db:
                    db.execute("DELETE FROM social_revocations WHERE id=?", (row["id"],))
            except Exception:
                failures += 1
        return failures
