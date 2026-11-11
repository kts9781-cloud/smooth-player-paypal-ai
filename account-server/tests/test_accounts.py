import base64
import json
import os
import uuid
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from dataclasses import replace

import pytest
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

from smooth_accounts.app import create_app
from smooth_accounts.config import Config
from smooth_accounts.providers import InvalidPurchase, LIFETIME, MONTHLY, ProviderUnavailable, VerifiedPurchase
from smooth_accounts.service import next_month


class Mail:
    def __init__(self): self.codes = {}
    def send(self, email, code): self.codes[email] = code


class Provider:
    def __init__(self):
        self.receipts = {}
        self.payments = {}
        self.calls = []
        self.billing_calls = []
        self.offline = False

    def apple(self, proof):
        if self.offline: raise ProviderUnavailable()
        if proof["signedTransaction"] not in self.receipts: raise InvalidPurchase()
        return self.receipts[proof["signedTransaction"]]

    def google(self, proof):
        return self.apple({"signedTransaction": proof["token"]})

    def toss(self, method, path, body=None, idempotency=None, *, billing=False):
        if self.offline: raise ProviderUnavailable()
        self.calls.append((method, path, body, idempotency))
        self.billing_calls.append((method, path, billing))
        if path == "billing/authorizations/issue":
            return {"customerKey": body["customerKey"], "billingKey": "billing-secret"}
        if method == "POST":
            identifier = body["orderId"]
            if identifier not in self.payments:
                self.payments[identifier] = {"orderId": identifier, "paymentKey": body.get("paymentKey", "payment-" + identifier), "totalAmount": body["amount"], "balanceAmount": body["amount"], "currency": "KRW", "status": "DONE"}
            return self.payments[identifier]
        if path.split("/")[-1] not in self.payments: raise InvalidPurchase()
        return self.payments[path.split("/")[-1]]


@pytest.fixture(params=["sqlite", "postgres"] if os.environ.get("SMOOTH_TEST_DATABASE_URL") else ["sqlite"])
def env(tmp_path, request):
    key = ec.generate_private_key(ec.SECP256R1())
    path = tmp_path / "signing.pem"
    path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    database = str(tmp_path / "db.sqlite3")
    schema = None
    if request.param == "postgres":
        import psycopg
        from psycopg import sql
        schema = "smooth_test_" + uuid.uuid4().hex
        url = os.environ["SMOOTH_TEST_DATABASE_URL"]
        with psycopg.connect(url, autocommit=True, connect_timeout=10) as db:
            db.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(schema)))
        parts = urlsplit(url)
        query = dict(parse_qsl(parts.query)); query["options"] = "-csearch_path=" + schema
        database = urlunsplit(parts._replace(query=urlencode(query)))
    c = Config(database=database, signing_key_file=str(path), encryption_key=Fernet.generate_key().decode(),
               toss_secret="test_sk_fixture", toss_client="test_ck_fixture", lifetime_price=1000, monthly_price=100, lifetime_enabled=True, billing_enabled=True,
               toss_billing_secret="test_sk_billing_fixture", toss_billing_client="test_ck_billing_fixture", webhook_token="x" * 48, cron_secret="c" * 48)
    mail, provider, now = Mail(), Provider(), [1_790_000_000]
    try:
        app = create_app(c, mailer=mail, providers=provider, clock=lambda: now[0])
        with TestClient(app) as client:
            yield client, app.state.service, mail, provider, now, key
    finally:
        if schema:
            with psycopg.connect(url, autocommit=True, connect_timeout=10) as db:
                db.execute(sql.SQL("DROP SCHEMA {} CASCADE").format(sql.Identifier(schema)))


def login(env, email="member@example.test"):
    client, _, mail, *_ = env
    response = client.post("/v1/auth/code", json={"email": email})
    assert response.status_code == 200, response.text
    response = client.post("/v1/auth/verify", json={"challengeId": response.json()["challengeId"], "code": mail.codes[email]})
    assert response.status_code == 200, response.text
    session = response.json()
    return {"Authorization": "Bearer " + session["token"]}, session


def payload(response):
    assert response.status_code == 200, response.text
    return json.loads(base64.b64decode(response.json()["license"]["payload"]))


def test_login_otp_single_use_and_signature(env):
    client, service, mail, _, now, key = env
    challenge = client.post("/v1/auth/code", json={"email": "member@example.test"}).json()["challengeId"]
    body = {"challengeId": challenge, "code": mail.codes["member@example.test"]}
    session = client.post("/v1/auth/verify", json=body).json()
    assert client.post("/v1/auth/verify", json=body).status_code == 401
    response = client.get("/v1/me", headers={"Authorization": "Bearer " + session["token"]})
    value = response.json()["license"]
    key.public_key().verify(base64.b64decode(value["signature"]), base64.b64decode(value["payload"]), ec.ECDSA(hashes.SHA256()))
    assert payload(response)["products"] == []
    assert session["token"] not in str(service.db.all("SELECT * FROM sessions"))


def test_wrong_codes_consume_attempts(env):
    client, _, mail, *_ = env
    challenge = client.post("/v1/auth/code", json={"email": "member@example.test"}).json()["challengeId"]
    for _ in range(5):
        assert client.post("/v1/auth/verify", json={"challengeId": challenge, "code": "00000000"}).status_code == 401
    assert client.post("/v1/auth/verify", json={"challengeId": challenge, "code": mail.codes["member@example.test"]}).status_code == 401


def test_expired_code_and_send_throttle(env):
    client, _, mail, _, now, _ = env
    challenge = client.post("/v1/auth/code", json={"email": "member@example.test"}).json()["challengeId"]
    assert client.post("/v1/auth/code", json={"email": "member@example.test"}).status_code == 429
    now[0] += 601
    assert client.post("/v1/auth/verify", json={"challengeId": challenge, "code": mail.codes["member@example.test"]}).status_code == 401


def test_other_origin_denied(env):
    assert env[0].get("/v1/catalog", headers={"Origin": "https://evil.invalid"}).status_code == 403


def test_purchase_claim_conflict_and_identity(env):
    client, _, _, provider, *_ = env
    a, member = login(env)
    b, _ = login(env, "other@example.test")
    provider.receipts["receipt"] = VerifiedPurchase("original", LIFETIME, True)
    assert payload(client.post("/v1/purchases/apple", headers=a, json={"signedTransaction": "receipt"}))["products"] == [LIFETIME]
    assert client.post("/v1/purchases/apple", headers=b, json={"signedTransaction": "receipt"}).status_code == 409
    provider.receipts["bound"] = VerifiedPurchase("original2", LIFETIME, True, account=member["userId"])
    assert client.post("/v1/purchases/apple", headers=b, json={"signedTransaction": "bound"}).status_code == 409


def test_google_replacement_preserves_owner(env):
    client, _, _, provider, *_ = env
    a, _ = login(env); b, _ = login(env, "other@example.test")
    provider.receipts["old"] = VerifiedPurchase("old", LIFETIME, True)
    provider.receipts["new"] = VerifiedPurchase("new", LIFETIME, True, linked_reference="old")
    assert client.post("/v1/purchases/google", headers=a, json={"token": "old", "product": LIFETIME}).status_code == 200
    assert client.post("/v1/purchases/google", headers=b, json={"token": "new", "product": LIFETIME}).status_code == 409


def test_google_guest_lifetime_links_once_and_is_visible_after_login_refresh(env):
    client, service, _, provider, *_ = env
    first, member = login(env)
    second, _ = login(env, "second@example.test")
    provider.receipts["guest"] = VerifiedPurchase("guest", LIFETIME, True)
    proof = {"token": "guest", "product": LIFETIME}
    for _ in range(2):
        assert payload(client.post("/v1/purchases/google", headers=first, json=proof))["products"] == [LIFETIME]
    assert payload(client.get("/v1/me", headers=first))["products"] == [LIFETIME]
    assert client.post("/v1/purchases/google", headers=second, json=proof).status_code == 409
    assert payload(client.get("/v1/me", headers=second))["products"] == []
    rows = service.db.all("SELECT * FROM purchases WHERE provider='google' AND reference='guest'")
    assert len(rows) == 1 and rows[0]["user_id"] == member["userId"]


def test_refund_does_not_remove_other_channel(env):
    client, _, _, p, now, _ = env
    headers, _ = login(env)
    p.receipts["a"] = VerifiedPurchase("a", LIFETIME, True)
    p.receipts["g"] = VerifiedPurchase("g", MONTHLY, True, now[0] + 3600)
    client.post("/v1/purchases/apple", headers=headers, json={"signedTransaction": "a"})
    client.post("/v1/purchases/google", headers=headers, json={"token": "g", "product": MONTHLY})
    p.receipts["a"].active = False; now[0] += 301
    assert payload(client.get("/v1/me", headers=headers))["products"] == [MONTHLY]
    now[0] += 3600
    assert payload(client.get("/v1/me", headers=headers))["products"] == []


def test_outage_cannot_extend_offline_lease(env):
    client, _, _, p, now, _ = env
    headers, _ = login(env); p.receipts["a"] = VerifiedPurchase("a", LIFETIME, True)
    initial = payload(client.post("/v1/purchases/apple", headers=headers, json={"signedTransaction": "a"}))
    p.offline = True; now[0] += 600
    later = payload(client.get("/v1/me", headers=headers))
    assert later["expiresAt"] == initial["expiresAt"]
    now[0] += 86401
    assert payload(client.get("/v1/me", headers=headers))["products"] == []


def test_order_ownership_amount_and_idempotency(env):
    client, service, _, p, *_ = env
    a, _ = login(env); b, _ = login(env, "other@example.test")
    order = client.post("/v1/orders", headers=a, json={"product": LIFETIME}).json()
    body = {"orderId": order["orderId"], "paymentKey": "unique-payment", "amount": order["amount"]}
    assert client.post("/v1/payments/confirm", headers=b, json=body).status_code == 404
    assert client.post("/v1/payments/confirm", headers=a, json={**body, "amount": 1}).status_code == 400
    for _ in range(2): assert payload(client.post("/v1/payments/confirm", headers=a, json=body))["products"] == [LIFETIME]
    assert len([x for x in p.calls if x[0] == "POST"]) == 1
    assert len(service.db.all("SELECT * FROM purchases")) == 1
    assert client.post("/v1/orders", headers=a, json={"product": LIFETIME}).status_code == 409


def test_toss_refund_requery(env):
    client, _, _, p, now, _ = env
    h, _ = login(env)
    order = client.post("/v1/orders", headers=h, json={"product": LIFETIME}).json()
    body = {"orderId": order["orderId"], "paymentKey": "p", "amount": order["amount"]}
    client.post("/v1/payments/confirm", headers=h, json=body)
    p.payments[order["orderId"]]["status"] = "CANCELED"
    now[0] += 301
    assert payload(client.get("/v1/me", headers=h))["products"] == []


def test_monthly_cancel_keeps_paid_period(env):
    client, service, _, provider, now, _ = env
    h, _ = login(env)
    order = client.post("/v1/orders", headers=h, json={"product": MONTHLY}).json()
    result = client.post("/v1/billing/confirm", headers=h, json={"orderId": order["orderId"], "authKey": "auth", "customerKey": order["customerKey"]})
    assert payload(result)["products"] == [MONTHLY]
    assert "billing-secret" not in str([dict(x) for x in service.db.all("SELECT * FROM subscriptions")])
    client.post("/v1/subscriptions/" + order["orderId"] + "/cancel", headers=h)
    assert payload(client.get("/v1/me", headers=h))["products"] == [MONTHLY]
    calls = len(provider.calls); now[0] = next_month(now[0]) + 1
    service.charge_subscription(order["orderId"])
    assert len(provider.calls) == calls
    h, _ = login(env)
    assert payload(client.get("/v1/me", headers=h))["products"] == []


def test_logout_and_deletion_preserve_purchase_tombstone(env):
    client, _, _, p, *_ = env
    h, _ = login(env); p.receipts["a"] = VerifiedPurchase("a", LIFETIME, True)
    client.post("/v1/purchases/apple", headers=h, json={"signedTransaction": "a"})
    assert client.delete("/v1/account", headers=h).status_code == 200
    assert client.get("/v1/me", headers=h).status_code == 401
    other, _ = login(env, "other@example.test")
    assert client.post("/v1/purchases/apple", headers=other, json={"signedTransaction": "a"}).status_code == 409
    client.post("/v1/auth/logout", headers=other)
    assert client.get("/v1/me", headers=other).status_code == 401


def test_webhook_is_only_authenticated_wakeup(env):
    client, *_ = env
    assert client.post("/v1/hooks/toss/wrong", json={"paid": True}).status_code == 404
    assert client.post("/v1/hooks/toss/" + "x" * 48, json={"paid": True}).status_code == 200


def test_disabled_catalog_never_invents_prices(env):
    _, service, *_ = env
    service.c = replace(service.c, lifetime_price=0, billing_enabled=False)
    assert service.catalog()["products"] == []


def test_production_rejects_test_keys(env):
    with pytest.raises(ValueError): replace(env[1].c, environment="production", origin="https://accounts.example.test").validate()


def test_duplicate_open_order_is_reused(env):
    client, *_ = env
    h, _ = login(env)
    first = client.post("/v1/orders", headers=h, json={"product": LIFETIME}).json()
    second = client.post("/v1/orders", headers=h, json={"product": LIFETIME}).json()
    assert first["orderId"] == second["orderId"]


def test_billing_confirmation_replay_does_not_charge_again(env):
    client, service, _, provider, *_ = env
    h, _ = login(env)
    order = client.post("/v1/orders", headers=h, json={"product": MONTHLY}).json()
    body = {"orderId": order["orderId"], "authKey": "authorization", "customerKey": order["customerKey"]}
    for _ in range(2): assert client.post("/v1/billing/confirm", headers=h, json=body).status_code == 200
    assert len(service.db.all("SELECT * FROM subscriptions")) == 1
    assert len([call for call in provider.calls if call[0] == "POST" and call[1] == "billing/billing-secret"]) == 1
    assert client.post("/v1/billing/confirm", headers=h, json={**body, "authKey": "other"}).status_code == 409


def test_billing_keeps_quoted_price(env):
    client, service, _, provider, *_ = env
    h, _ = login(env)
    order = client.post("/v1/orders", headers=h, json={"product": MONTHLY}).json()
    service.c = replace(service.c, monthly_price=9999)
    response = client.post("/v1/billing/confirm", headers=h, json={"orderId": order["orderId"], "authKey": "auth", "customerKey": order["customerKey"]})
    assert response.status_code == 200
    assert [call[2]["amount"] for call in provider.calls if call[1] == "billing/billing-secret"] == [order["amount"]]


def test_refunded_order_cannot_be_reactivated_by_old_response(env):
    client, service, _, provider, now, _ = env
    h, _ = login(env)
    order = client.post("/v1/orders", headers=h, json={"product": LIFETIME}).json()
    client.post("/v1/payments/confirm", headers=h, json={"orderId": order["orderId"], "paymentKey": "payment", "amount": order["amount"]})
    old = dict(provider.payments[order["orderId"]])
    provider.payments[order["orderId"]]["status"] = "CANCELED"
    service.reconcile_order(order["orderId"])
    service.apply_payment(service.db.one("SELECT * FROM orders WHERE id=?", (order["orderId"],)), old)
    assert payload(client.get("/v1/me", headers=h))["products"] == []


def test_chunked_body_bound(env):
    response = env[0].post("/v1/auth/code", content=iter([b"a" * 40000, b"a" * 40000]), headers={"Content-Type": "application/json"})
    assert response.status_code == 413


def test_environment_database_isolation(env):
    from smooth_accounts.service import Service
    with pytest.raises(ValueError, match="separate databases"):
        Service(replace(env[1].c, origin="http://127.0.0.1:9999"))


def test_monthly_worker_does_not_collect_old_backlog(env):
    client, service, _, provider, now, _ = env
    h, _ = login(env)
    order = client.post("/v1/orders", headers=h, json={"product": MONTHLY}).json()
    client.post("/v1/billing/confirm", headers=h, json={"orderId": order["orderId"], "authKey": "auth", "customerKey": order["customerKey"]})
    now[0] += 120 * 86400
    calls = len(provider.calls)
    service.charge_subscription(order["orderId"])
    assert len(provider.calls) == calls
    assert service.db.one("SELECT cancelled FROM subscriptions WHERE id=?", (order["orderId"],))[0] == 1


def test_cron_authentication_and_provider_failures(env):
    client, service, _, provider, now, _ = env
    assert client.get("/v1/internal/reconcile").status_code == 401
    assert client.get("/v1/internal/reconcile", headers={"Authorization": "Bearer incorrect"}).status_code == 401
    authorization = {"Authorization": "Bearer " + service.c.cron_secret}
    assert client.get("/v1/internal/reconcile", headers=authorization).status_code == 200
    headers, _ = login(env)
    provider.receipts["cron-receipt"] = VerifiedPurchase("cron-receipt", LIFETIME, True)
    assert client.post("/v1/purchases/apple", headers=headers, json={"signedTransaction": "cron-receipt"}).status_code == 200
    now[0] += 301
    provider.offline = True
    response = client.get("/v1/internal/reconcile", headers=authorization)
    assert response.status_code == 503
    assert response.json()["providerFailures"] == 1


def test_cron_stops_at_deadline_without_provider_calls(env):
    client, service, _, provider, now, _ = env
    headers, _ = login(env)
    provider.receipts["deadline"] = VerifiedPurchase("deadline", LIFETIME, True)
    client.post("/v1/purchases/apple", headers=headers, json={"signedTransaction": "deadline"})
    now[0] += 301
    checked = service.db.one("SELECT checked FROM purchases")[0]
    assert service.reconcile(max_seconds=0) == 0
    assert service.db.one("SELECT checked FROM purchases")[0] == checked


def test_environment_pem_and_vercel_requires_postgres(tmp_path, monkeypatch):
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode()
    monkeypatch.setenv("SMOOTH_SIGNING_KEY_PEM", pem)
    monkeypatch.setenv("SMOOTH_ENCRYPTION_KEY", Fernet.generate_key().decode())
    monkeypatch.setenv("SMOOTH_DATABASE", str(tmp_path / "config.sqlite3"))
    monkeypatch.setenv("CRON_SECRET", "c" * 48)
    config = Config.from_env()
    assert config.signing_key_pem == pem
    assert config.cron_secret == "c" * 48
    monkeypatch.setenv("VERCEL", "1")
    with pytest.raises(ValueError, match="persistent PostgreSQL"):
        Config.from_env()
