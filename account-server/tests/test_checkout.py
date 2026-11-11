"""Payment routing and complimentary access use synthetic providers only."""
import base64
from dataclasses import replace

import httpx
import pytest
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec

from smooth_accounts.providers import LIFETIME, MONTHLY, Providers, ProviderUnavailable
from smooth_accounts.security import digest
from .test_accounts import env, login, payload


def enable_code(env):
    env[1].c = replace(env[1].c, complimentary_code_digest=digest("fixture-free-code"))


def test_disabled_lifetime_with_keys_preserves_prices_monthly_and_free_access(env):
    client, service, _, provider, *_ = env
    enable_code(env)
    service.c = replace(service.c, lifetime_enabled=False, lifetime_price=19900, monthly_price=990)
    catalog = client.get("/v1/catalog").json()
    assert [p["id"] for p in catalog["products"]] == [MONTHLY]
    lifetime = next(p for p in catalog["offers"] if p["id"] == LIFETIME)
    assert lifetime["amount"] == 19900 and lifetime["available"] is False
    headers, _ = login(env)
    assert client.post("/v1/orders", headers=headers, json={"product": LIFETIME}).status_code == 503
    result = client.post("/v1/complimentary/redeem", headers=headers, json={"code": "fixture-free-code"})
    assert payload(result)["products"] == [LIFETIME]
    assert provider.calls == []


def test_disabling_lifetime_blocks_an_open_checkout_without_charging(env):
    client, service, _, provider, *_ = env
    headers, _ = login(env)
    order = client.post("/v1/orders", headers=headers, json={"product": LIFETIME}).json()
    service.c = replace(service.c, lifetime_enabled=False)
    result = client.post("/v1/payments/confirm", headers=headers, json={"orderId": order["orderId"], "paymentKey": "never-charge", "amount": order["amount"]})
    assert result.status_code == 503
    assert provider.calls == []
    assert service.db.one("SELECT status FROM orders")[0] == "created"


def test_disabled_lifetime_recovers_existing_approval_and_tracks_refund(env, monkeypatch):
    client, service, _, provider, *_ = env
    headers, _ = login(env)
    order = client.post("/v1/orders", headers=headers, json={"product": LIFETIME}).json()
    body = {"orderId": order["orderId"], "paymentKey": "approved-before-stop", "amount": order["amount"]}
    original = provider.toss
    def lost_response(method, path, *args, **kwargs):
        result = original(method, path, *args, **kwargs)
        if method == "POST":
            raise ProviderUnavailable()
        return result
    monkeypatch.setattr(provider, "toss", lost_response)
    assert client.post("/v1/payments/confirm", headers=headers, json=body).status_code == 503
    service.c = replace(service.c, lifetime_enabled=False)
    assert payload(client.post("/v1/payments/confirm", headers=headers, json=body))["products"] == [LIFETIME]
    provider.payments[order["orderId"]].update(status="CANCELED", balanceAmount=0)
    assert payload(client.post("/v1/payments/confirm", headers=headers, json=body))["products"] == []
    assert [call[0] for call in provider.calls] == ["POST", "GET", "GET"]


def test_complimentary_signed_restored_reusable_and_no_payment(env):
    client, service, _, provider, now, key = env
    enable_code(env)
    a, first = login(env)
    b, _ = login(env, "second@example.test")
    for headers in (a, a, b):
        response = client.post("/v1/complimentary/redeem", headers=headers, json={"code": " fixture-free-code "})
        assert payload(response)["products"] == [LIFETIME]
        signed = response.json()["license"]
        key.public_key().verify(base64.b64decode(signed["signature"]), base64.b64decode(signed["payload"]), ec.ECDSA(hashes.SHA256()))
        assert response.json()["sources"] == ["complimentary"]
    assert len(service.db.all("SELECT * FROM complimentary_grants")) == 2
    assert service.db.all("SELECT * FROM purchases") == []
    assert service.db.all("SELECT * FROM orders") == []
    assert provider.calls == []
    assert client.post("/v1/orders", headers=a, json={"product": LIFETIME}).status_code == 409
    client.post("/v1/auth/logout", headers=a)
    now[0] += 86401
    # Changing/withdrawing the reusable code does not revoke an issued grant.
    service.c = replace(service.c, complimentary_code_digest="")
    restored, session = login(env)
    assert session["userId"] == first["userId"]
    assert payload(client.get("/v1/me", headers=restored))["products"] == [LIFETIME]
    assert payload(client.get("/v1/me", headers=restored))["expiresAt"] == now[0] + service.c.offline_seconds


def test_complimentary_authentication_rate_limit_and_secret_not_exposed(env):
    client, service, *_ = env
    enable_code(env)
    assert client.post("/v1/complimentary/redeem", json={"code": "fixture-free-code"}).status_code == 401
    headers, _ = login(env)
    for code in ["wrong"] * 6:
        assert client.post("/v1/complimentary/redeem", headers=headers, json={"code": code}).status_code == 400
    assert client.post("/v1/complimentary/redeem", headers=headers, json={"code": "fixture-free-code"}).status_code == 429
    assert payload(client.get("/v1/me", headers=headers))["products"] == []
    text = client.get("/v1/catalog").text
    assert "fixture-free-code" not in text and service.c.complimentary_code_digest not in text
    assert client.post("/v1/complimentary/redeem", headers=headers, json={"code": "x" * 129}).status_code == 422


def test_complimentary_stops_future_toss_charges_and_survives_refund(env):
    client, service, _, provider, now, _ = env
    enable_code(env)
    headers, _ = login(env)
    order = client.post("/v1/orders", headers=headers, json={"product": MONTHLY}).json()
    assert client.post("/v1/billing/confirm", headers=headers, json={"orderId": order["orderId"], "authKey": "auth", "customerKey": order["customerKey"]}).status_code == 200
    assert client.post("/v1/complimentary/redeem", headers=headers, json={"code": "fixture-free-code"}).status_code == 200
    assert service.db.one("SELECT cancelled FROM subscriptions")[0] == 1
    payment = next(iter(provider.payments.values()))
    payment["status"] = "CANCELED"
    payment["balanceAmount"] = 0
    service.reconcile_order(payment["orderId"])
    assert payload(client.get("/v1/me", headers=headers))["products"] == [LIFETIME]
    charges = len([call for call in provider.calls if call[0] == "POST"])
    now[0] += 32 * 86400
    service.reconcile()
    assert len([call for call in provider.calls if call[0] == "POST"]) == charges
    headers, _ = login(env)
    assert client.delete("/v1/account", headers=headers).status_code == 200
    assert service.db.all("SELECT * FROM complimentary_grants") == []


def test_monthly_uses_billing_mid_for_registration_renewal_and_refund(env):
    client, service, _, provider, now, _ = env
    service.c = replace(service.c, monthly_price=990, lifetime_price=19900)
    headers, _ = login(env)
    products = {p["id"]: p["amount"] for p in client.get("/v1/catalog").json()["products"]}
    assert products == {MONTHLY: 990, LIFETIME: 19900}
    order = client.post("/v1/orders", headers=headers, json={"product": MONTHLY}).json()
    assert order["clientKey"] == service.c.toss_billing_client
    assert order["amount"] == 990
    response = client.post("/v1/billing/confirm", headers=headers, json={"orderId": order["orderId"], "authKey": "auth", "customerKey": order["customerKey"]})
    assert payload(response)["products"] == [MONTHLY]
    now[0] = service.db.one("SELECT next_due FROM subscriptions")[0]
    service.charge_subscription(order["orderId"])
    service.reconcile_order(next(iter(provider.payments)))
    assert len([call for call in provider.calls if call[0] == "POST" and call[1] == "billing/billing-secret"]) == 2
    assert all(billing for _, _, billing in provider.billing_calls)


def test_distinct_mid_credentials_do_not_cross_in_requests(monkeypatch, env):
    config = env[1].c
    seen = []
    def request(method, url, **kwargs):
        seen.append(base64.b64decode(kwargs["headers"]["Authorization"][6:]).decode())
        return httpx.Response(200, json={"status": "DONE"})
    monkeypatch.setattr(httpx, "request", request)
    provider = Providers(config)
    provider.toss("GET", "payments/orders/ordinary")
    provider.toss("GET", "payments/orders/monthly", billing=True)
    assert seen == [config.toss_secret + ":", config.toss_billing_secret + ":"]
    with pytest.raises(ValueError, match="own approved MID"):
        replace(config, toss_billing_secret="", toss_billing_client="").validate()
    with pytest.raises(ValueError, match="key pair"):
        replace(config, toss_billing_secret="live_sk_wrong").validate()


def test_checkout_records_current_terms_and_quoted_amount(env):
    client, service, *_ = env
    headers, session = login(env)
    service.c = replace(service.c, terms_version="2026-10-29", lifetime_price=19900)
    assert client.post("/v1/orders", headers=headers, json={"product": LIFETIME, "amount": 1000, "termsVersion": "2026-10-29"}).status_code == 409
    assert client.post("/v1/orders", headers=headers, json={"product": LIFETIME, "amount": 19900, "termsVersion": "old"}).status_code == 409
    order = client.post("/v1/orders", headers=headers, json={"product": LIFETIME, "amount": 19900, "termsVersion": "2026-10-29"}).json()
    consent = service.db.one("SELECT * FROM checkout_consents WHERE order_id=?", (order["orderId"],))
    assert consent["user_id"] == session["userId"] and consent["amount"] == 19900
    assert consent["terms_version"] == "2026-10-29"
    assert order["clientKey"] == service.c.toss_client


def test_lifetime_price_change_preserves_paid_ownership_and_quoted_orders(env):
    client, service, _, provider, *_ = env
    service.c = replace(service.c, terms_version="2026-10-29", lifetime_price=19900)
    owner, _ = login(env, "existing@example.test")
    pending, _ = login(env, "quoted@example.test")
    def order(headers, amount, terms):
        return client.post("/v1/orders", headers=headers, json={
            "product": LIFETIME, "amount": amount, "termsVersion": terms})
    def confirm(headers, value):
        return client.post("/v1/payments/confirm", headers=headers, json={
            "orderId": value["orderId"], "amount": value["amount"], "paymentKey": "pay-" + value["orderId"]})
    paid = order(owner, 19900, "2026-10-29").json()
    quoted = order(pending, 19900, "2026-10-29").json()
    assert payload(confirm(owner, paid))["products"] == [LIFETIME]

    service.c = replace(service.c, lifetime_price=59400, terms_version="2026-10-30")
    assert payload(client.get("/v1/me", headers=owner))["products"] == [LIFETIME]
    assert payload(confirm(pending, quoted))["products"] == [LIFETIME]
    assert provider.payments[quoted["orderId"]]["totalAmount"] == 19900
    fresh, _ = login(env, "new@example.test")
    assert order(fresh, 19900, "2026-10-29").status_code == 409
    newest = order(fresh, 59400, "2026-10-30").json()
    assert newest["amount"] == 59400
    assert payload(confirm(fresh, newest))["products"] == [LIFETIME]


def test_stale_checkout_after_free_code_does_not_charge(env):
    client, _, _, provider, *_ = env
    enable_code(env)
    headers, _ = login(env)
    order = client.post("/v1/orders", headers=headers, json={"product": LIFETIME}).json()
    assert client.post("/v1/complimentary/redeem", headers=headers, json={"code": "fixture-free-code"}).status_code == 200
    result = client.post("/v1/payments/confirm", headers=headers, json={"orderId": order["orderId"], "paymentKey": "never-charge", "amount": order["amount"]})
    assert result.status_code == 409
    assert provider.calls == []


def test_public_notices_escape_seller_and_show_actual_prices(env):
    client, service, *_ = env
    service.c = replace(service.c, seller_name="<script>unsafe</script>", seller_email="support@example.test", terms_version="2026-10-29", monthly_price=990, lifetime_price=19900)
    for path in ("/privacy", "/terms", "/support"):
        response = client.get(path)
        assert response.status_code == 200 and "text/html" in response.headers["content-type"]
        assert "<script>unsafe</script>" not in response.text
        assert "&lt;script&gt;unsafe&lt;/script&gt;" in response.text
    assert "19,900원" in client.get("/terms").text
    assert "월 990원" in client.get("/terms").text


def test_expired_auth_and_deleted_account_retention(env):
    client, service, _, _, now, _ = env
    enable_code(env)
    deleted, session = login(env)
    client.post("/v1/complimentary/redeem", headers=deleted, json={"code": "fixture-free-code"})
    assert client.delete("/v1/account", headers=deleted).status_code == 200
    retained, current = login(env, "retained@example.test")
    client.post("/v1/complimentary/redeem", headers=retained, json={"code": "fixture-free-code"})
    now[0] += 366 * 86400
    service.purge_expired_records()
    assert service.db.one("SELECT 1 FROM users WHERE id=?", (session["userId"],))
    assert service.db.all("SELECT * FROM sessions") == []
    assert service.db.all("SELECT * FROM challenges") == []
    now[0] += 5 * 366 * 86400
    service.purge_expired_records()
    assert not service.db.one("SELECT 1 FROM users WHERE id=?", (session["userId"],))
    assert service.db.one("SELECT 1 FROM complimentary_grants WHERE user_id=?", (current["userId"],))


def test_lost_approval_response_is_recovered_without_second_charge(env, monkeypatch):
    client, service, _, provider, *_ = env
    headers, _ = login(env)
    order = client.post("/v1/orders", headers=headers, json={"product": LIFETIME}).json()
    original = provider.toss
    def lost_response(method, path, body=None, idempotency=None, **kwargs):
        result = original(method, path, body, idempotency, **kwargs)
        if method == "POST":
            raise ProviderUnavailable()
        return result
    monkeypatch.setattr(provider, "toss", lost_response)
    result = client.post("/v1/payments/confirm", headers=headers, json={"orderId": order["orderId"], "paymentKey": "lost-response", "amount": order["amount"]})
    assert result.status_code == 503
    assert service.db.all("SELECT * FROM purchases") == []
    assert service.reconcile() == 0
    assert payload(client.get("/v1/me", headers=headers))["products"] == [LIFETIME]
    assert len([call for call in provider.calls if call[0] == "POST"]) == 1
