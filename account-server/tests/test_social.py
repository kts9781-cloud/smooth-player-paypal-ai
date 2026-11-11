import secrets
import time
from dataclasses import replace
from types import SimpleNamespace
from urllib.parse import parse_qs, urlsplit

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from .test_accounts import env, login, payload
from smooth_accounts.social import IdentityProvider, s256
from smooth_accounts.providers import LIFETIME, VerifiedPurchase


@pytest.fixture
def social(env):
    client, service, *_ = env
    service.c = replace(service.c, google_login_enabled=True, google_login_client="fixture.apps.googleusercontent.com",
                        apple_login_enabled=True, apple_login_client="com.example.login")
    class Provider:
        identity = {"subject": "subject-1", "email": "social@example.test", "revoke_token": "secret-revoke"}
        calls = 0
        revoked = []
        def exchange(self, provider, code, data):
            self.calls += 1
            assert code == "fixture-code"
            assert len(data["nonce"]) >= 32
            return dict(self.identity)
        def revoke(self, provider, token):
            self.revoked.append((provider, token))
    service.social.provider = Provider()
    return env


def begin(env, provider="google", headers=None, client_kind="apple"):
    client, service, *_ = env
    verifier = secrets.token_urlsafe(48)
    response = client.post("/v1/auth/social/start", json={"provider": provider, "challenge": s256(verifier), "client": client_kind}, headers=headers)
    assert response.status_code == 200, response.text
    attempt = response.json()
    response = client.get(urlsplit(attempt["authorizationURL"]).path, follow_redirects=False)
    assert response.status_code == 303
    assert "HttpOnly" in response.headers["set-cookie"]
    query = parse_qs(urlsplit(response.headers["location"]).query)
    assert query["response_type"] == ["code"]
    if provider == "google":
        assert query["scope"] == ["openid email"]
        assert query["code_challenge_method"] == ["S256"]
    return attempt, verifier, {"state": query["state"][0], "code": "fixture-code"}


def callback(env, fields, provider="google"):
    client = env[0]
    if provider == "apple":
        return client.post("/v1/auth/social/callback/apple", data=fields,
                           headers={"Origin": "https://appleid.apple.com"}, follow_redirects=False)
    return client.get("/v1/auth/social/callback/google", params=fields, follow_redirects=False)


def finish(env, attempt, verifier):
    return env[0].post("/v1/auth/social/complete", json={"id": attempt["id"], "verifier": verifier})


def test_unconfigured_does_not_offer_a_fake_login(env):
    assert all(not p["enabled"] for p in env[0].get("/v1/auth/providers").json()["providers"])
    assert env[0].post("/v1/auth/social/start", json={"provider": "google", "challenge": "a" * 43, "client": "web"}).status_code == 503


@pytest.mark.parametrize("provider", ["google", "apple"])
def test_new_login_and_stable_subject(social, provider):
    client, service, *_ = social
    a, v, fields = begin(social, provider)
    assert finish(social, a, v).json() == {"status": "pending"}
    result = callback(social, fields, provider)
    assert result.status_code == 303
    assert result.headers["location"] == "smoothplayer-auth://complete?attempt=" + a["id"]
    session = finish(social, a, v).json()["session"]
    assert session["email"] == "social@example.test"
    assert finish(social, a, v).status_code == 401
    service.social.provider.identity["email"] = "renamed@example.test"
    a, v, fields = begin(social, provider)
    callback(social, fields, provider)
    second = finish(social, a, v).json()["session"]
    assert second["userId"] == session["userId"]
    assert second["email"] == session["email"]
    stored = str([dict(r) for r in service.db.all("SELECT * FROM social_identities")])
    assert "secret-revoke" not in stored


def test_explicit_link_preserves_account_license_and_nas(social):
    from .test_nas_sync import sync, records, change, S, SERVER, R, RECENT
    client, service, _, purchases, *_ = social
    headers, original = login(social)
    purchases.receipts["owned"] = VerifiedPurchase("owned", LIFETIME, True)
    client.post("/v1/purchases/apple", headers=headers, json={"signedTransaction": "owned"})
    original_nas = records(sync(social, headers, [change(S, SERVER), change(R, RECENT)]))
    # Distinct private relay email can link only with the existing authenticated session.
    service.social.provider.identity["email"] = "relay@privaterelay.appleid.com"
    a, v, fields = begin(social, "apple", headers)
    callback(social, fields, "apple")
    result = finish(social, a, v).json()["session"]
    assert result["userId"] == original["userId"] and result["email"] == original["email"]
    linked = {"Authorization": "Bearer " + result["token"]}
    assert payload(client.get("/v1/me", headers=linked))["products"] == [LIFETIME]
    assert records(sync(social, linked)) == original_nas
    assert next(p for p in client.get("/v1/auth/providers", headers=linked).json()["providers"] if p["id"] == "apple")["linked"]
    # No new account/partition is created, including the NAS partition keyed by this ID.
    assert len(service.db.all("SELECT * FROM users")) == 1


def test_existing_email_requires_authenticated_link(social):
    _, service, *_ = social
    _, user = login(social, "social@example.test")
    a, v, fields = begin(social)
    callback(social, fields)
    result = finish(social, a, v)
    assert result.status_code == 409 and "기존 계정" in result.text
    assert len(service.db.all("SELECT * FROM users")) == 1
    assert not service.db.all("SELECT * FROM social_identities")


def test_cannot_link_identity_to_another_account(social):
    a, v, fields = begin(social)
    callback(social, fields)
    original = finish(social, a, v).json()["session"]
    headers, other = login(social)
    a, v, fields = begin(social, headers=headers)
    callback(social, fields)
    assert finish(social, a, v).status_code == 409
    assert social[1].db.one("SELECT user_id FROM social_identities")[0] == original["userId"]


def test_state_cookie_provider_pkce_and_replay(social):
    client, service, *_ = social
    a, v, fields = begin(social)
    assert callback(social, {**fields, "state": "incorrect"}).status_code == 400
    assert callback(social, fields, "apple").status_code == 400
    cookies = list(client.cookies.jar)
    client.cookies.clear()
    assert callback(social, fields).status_code == 400
    for cookie in cookies: client.cookies.jar.set_cookie(cookie)
    assert callback(social, fields).status_code == 303
    assert callback(social, fields).status_code == 400
    assert service.social.provider.calls == 1
    assert finish(social, a, "x" * 64).status_code == 401
    assert finish(social, a, v).status_code == 200
    assert finish(social, a, v).status_code == 401


def test_apple_origin_exception_is_narrow(social):
    client, *_ = social
    headers = {"Origin": "https://appleid.apple.com"}
    assert client.post("/v1/auth/social/start", headers=headers, json={}).status_code == 403
    assert client.get("/v1/auth/social/callback/apple", headers=headers).status_code == 403
    assert client.post("/v1/auth/social/callback/apple", headers=headers, json={}).status_code == 400
    assert client.post("/v1/auth/social/callback/apple", headers={"Origin": "https://evil.invalid"}, data={}).status_code == 403


def test_cancel_expiry_duplicate_fields(social):
    client, service, _, _, now, _ = social
    a, v, fields = begin(social)
    assert client.get("/v1/auth/social/callback/google", params=[("state", fields["state"]), ("state", fields["state"])]).status_code == 400
    callback(social, {"state": fields["state"], "error": "access_denied"})
    assert finish(social, a, v).status_code == 409
    assert service.social.provider.calls == 0
    a, v, fields = begin(social)
    now[0] += 601
    assert callback(social, fields).status_code == 400
    assert finish(social, a, v).status_code == 401


def test_logout_invalidates_pending_link(social):
    headers, _ = login(social)
    a, v, fields = begin(social, headers=headers)
    callback(social, fields)
    social[0].post("/v1/auth/logout", headers=headers)
    assert finish(social, a, v).status_code == 409


def test_deletion_revokes_and_old_callback_cannot_recreate_account(social):
    client, service, *_ = social
    a, v, fields = begin(social, "apple")
    callback(social, fields, "apple")
    session = finish(social, a, v).json()["session"]
    pending, verifier, fields = begin(social, "apple")
    callback(social, fields, "apple")
    client.delete("/v1/account", headers={"Authorization": "Bearer " + session["token"]})
    assert not service.db.all("SELECT * FROM social_identities")
    assert finish(social, pending, verifier).status_code == 409
    assert service.social.revoke_pending(time.monotonic() + 10) == 0
    assert service.social.provider.revoked == [("apple", "secret-revoke")]
    assert not service.db.all("SELECT * FROM social_revocations")


@pytest.mark.parametrize("client_kind,status", [("android", 200), ("web", 303)])
def test_platform_callback_never_contains_session(social, client_kind, status):
    a, v, fields = begin(social, client_kind=client_kind)
    result = callback(social, fields)
    assert result.status_code == status
    assert "fixture-code" not in result.text and "secret-revoke" not in result.text
    if client_kind == "web": assert result.headers["location"] == "/?social=complete"
    assert finish(social, a, v).status_code == 200


@pytest.mark.parametrize("provider", ["google", "apple"])
def test_signed_id_token_validation(env, monkeypatch, provider):
    service = env[1]
    config = replace(service.c, google_login_client="fixture.apps.googleusercontent.com", apple_login_client="com.example.login")
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    monkeypatch.setattr("smooth_accounts.social.key_client", lambda _: SimpleNamespace(get_signing_key_from_jwt=lambda _: SimpleNamespace(key=key.public_key())))
    now = int(time.time())
    claims = {"iss": "https://accounts.google.com" if provider == "google" else "https://appleid.apple.com", "aud": getattr(config, provider + "_login_client"),
              "sub": "fixture-sub", "nonce": "fixture-nonce", "iat": now, "exp": now + 300, "email": "Member@Example.test", "email_verified": True}
    verify = lambda c: IdentityProvider(config).validate(provider, jwt.encode(c, key, algorithm="RS256"), "fixture-nonce")
    assert verify(claims) == {"subject": "fixture-sub", "email": "member@example.test"}
    for changes in ({"iss": "https://evil.invalid"}, {"aud": "other"}, {"aud": [claims["aud"]]}, {"nonce": "wrong"}, {"exp": now - 100}, {"email_verified": False}, {"email_verified": 1}, {"azp": "other"}, {"sub": ""}):
        with pytest.raises((ValueError, jwt.InvalidTokenError)): verify({**claims, **changes})
    with pytest.raises((ValueError, jwt.InvalidTokenError)):
        IdentityProvider(config).validate(provider, jwt.encode(claims, "incorrect" * 8, algorithm="HS256"), "fixture-nonce")
