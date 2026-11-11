"""Financial boundaries; fake provider responses never count as Sandbox evidence."""
import copy
from dataclasses import replace
from datetime import datetime, timezone

import pytest

from smooth_accounts.paypal import PayPalCheckout, PayPalAPI
from smooth_accounts.providers import LIFETIME, MONTHLY, YEARLY, ProviderUnavailable
from smooth_accounts.service import next_month
from .test_accounts import env, login, payload


class Sandbox:
    base = "https://api-m.sandbox.paypal.com"

    def __init__(self, now):
        self.now, self.calls, self.orders, self.payments = now, [], {}, {}
        self.lose_capture = False
        self.signature = "SUCCESS"

    def request(self, method, path, body=None, request_id=None):
        self.calls.append((method, path, copy.deepcopy(body), request_id))
        if path == "/v1/notifications/verify-webhook-signature":
            return {"verification_status": self.signature}
        if path == "/v2/checkout/orders":
            assert request_id
            existing = next((v for v in self.orders.values() if v["purchase_units"][0]["custom_id"] == request_id), None)
            if existing:
                return copy.deepcopy(existing)
            ident = "ORDER000" + str(len(self.orders))
            self.orders[ident] = {"id": ident, "intent": "CAPTURE", "status": "PAYER_ACTION_REQUIRED",
                                  "purchase_units": copy.deepcopy(body["purchase_units"]),
                                  "links": [{"rel": "payer-action", "href": "https://www.sandbox.paypal.com/checkoutnow?token=" + ident}]}
            return copy.deepcopy(self.orders[ident])
        ident = path.split("/")[-1]
        if method == "GET":
            return copy.deepcopy(self.orders.get(ident) or self.payments[ident])
        if ident == "capture":
            assert request_id
            order = self.orders[path.split("/")[-2]]
            assert order["status"] == "APPROVED"
            unit = order["purchase_units"][0]
            cid = "CAPTURE" + order["id"]
            unit["payments"] = {"captures": [{"id": cid}]}
            self.payments[cid] = {"id": cid, "amount": copy.deepcopy(unit["amount"]), "status": "COMPLETED",
                                  "supplementary_data": {"related_ids": {"order_id": order["id"]}},
                                  "create_time": datetime.fromtimestamp(self.now[0], timezone.utc).isoformat()}
            order["status"] = "COMPLETED"
            if self.lose_capture:
                raise ProviderUnavailable()
            return copy.deepcopy(order)
        if ident == "refund":
            assert request_id
            self.payments[path.split("/")[-2]]["status"] = "REFUNDED"
            return {"id": "REFUND0001", "status": "COMPLETED"}
        raise AssertionError((method, path))


@pytest.fixture
def pp(env):
    client, service, _, _, now, _ = env
    service.c = replace(service.c, paypal_enabled=True, paypal_client="fixture", paypal_secret="fixture",
                        paypal_merchant_id="MERCHANT01", paypal_lifetime_cents=100, paypal_yearly_cents=50,
                        paypal_webhook_id="WH001", terms_version="paypal-1")
    service.paypal = PayPalCheckout(service)
    fake = Sandbox(now)
    service.paypal.api = fake
    headers, member = login(env)
    return client, service, fake, headers, member


def order(pp, product=LIFETIME):
    client, service, fake, headers, _ = pp
    result = client.post("/v1/paypal/orders", headers=headers,
                         json={"product": product, "amount": 50 if product == YEARLY else 100, "termsVersion": "paypal-1"})
    assert result.status_code == 200, result.text
    ident = result.json()["orderId"]
    row = service.paypal.row(ident)
    fake.orders[row["provider_order"]]["status"] = "APPROVED"
    return ident


def capture(pp, ident):
    return pp[0].post(f"/v1/paypal/orders/{ident}/capture", headers=pp[3], json={})


def test_paypal_disabled_is_not_for_sale(env):
    client, service, *_ = env
    headers, _ = login(env)
    assert client.get("/v1/catalog").json()["paypal"]["products"] == []
    assert client.post("/v1/paypal/orders", headers=headers, json={"product": LIFETIME}).status_code == 503
    assert service.db.all("SELECT * FROM paypal_orders") == []


def test_paypal_checkout_captures_once_and_restores_same_signed_license(pp, env):
    client, service, fake, headers, _ = pp
    ident = order(pp)
    assert payload(client.get("/v1/me", headers=headers))["products"] == []
    for _ in range(2):
        response = capture(pp, ident)
        assert response.status_code == 200, response.text
        assert response.json()["status"] == "done"
    assert len([c for c in fake.calls if c[0] == "POST" and c[1].endswith("/capture")]) == 1
    assert len(service.db.all("SELECT * FROM purchases WHERE provider='paypal'")) == 1
    env[4][0] += 61
    restored, _ = login(env)
    result = client.get("/v1/me", headers=restored)
    assert payload(result)["products"] == [LIFETIME]
    assert result.json()["sources"] == ["paypal"]
    body = next(c[2] for c in fake.calls if c[1] == "/v2/checkout/orders")
    assert body["purchase_units"][0]["payee"] == {"merchant_id": "MERCHANT01"}
    assert body["payment_source"]["paypal"]["experience_context"]["shipping_preference"] == "NO_SHIPPING"


@pytest.mark.parametrize("change", ["price", "currency", "merchant", "custom", "intent", "units"])
def test_paypal_rejects_tampered_provider_order_before_charge(pp, change):
    client, service, fake, headers, _ = pp
    ident = order(pp)
    data = fake.orders[service.paypal.row(ident)["provider_order"]]
    unit = data["purchase_units"][0]
    if change == "price": unit["amount"]["value"] = "0.99"
    if change == "currency": unit["amount"]["currency_code"] = "KRW"
    if change == "merchant": unit["payee"]["merchant_id"] = "OTHERSELLER"
    if change == "custom": unit["custom_id"] = "other-order"
    if change == "intent": data["intent"] = "AUTHORIZE"
    if change == "units": data["purchase_units"] = []
    assert capture(pp, ident).status_code == 400
    assert not fake.payments
    assert payload(client.get("/v1/me", headers=headers))["products"] == []


def test_paypal_price_terms_and_ownership_are_server_enforced(pp, env):
    client, service, fake, headers, _ = pp
    for patch in ({"amount": 1}, {"termsVersion": "old"}):
        body = {"product": LIFETIME, "amount": 100, "termsVersion": "paypal-1", **patch}
        assert client.post("/v1/paypal/orders", headers=headers, json=body).status_code == 409
    ident = order(pp)
    other, _ = login(env, "other@example.test")
    assert client.post(f"/v1/paypal/orders/{ident}/capture", headers=other, json={}).status_code == 404
    assert client.post(f"/v1/paypal/orders/{ident}/refund", headers=other, json={}).status_code == 404
    assert client.get("/v1/paypal/orders", headers=other).json()["orders"] == []
    assert not fake.payments


def test_paypal_lost_capture_response_recovers_without_second_charge(pp):
    _, service, fake, _, _ = pp
    ident = order(pp)
    fake.lose_capture = True
    assert capture(pp, ident).status_code == 503
    fake.lose_capture = False
    assert capture(pp, ident).json()["status"] == "done"
    assert len([c for c in fake.calls if c[0] == "POST" and c[1].endswith("/capture")]) == 1


def test_paypal_pending_has_no_access_then_refund_cannot_be_replayed(pp):
    client, service, fake, headers, _ = pp
    ident = order(pp)
    assert capture(pp, ident).status_code == 200
    payment = next(iter(fake.payments.values()))
    payment["status"] = "PENDING"
    service.paypal.reconcile(ident)
    assert payload(client.get("/v1/me", headers=headers))["products"] == []
    payment["status"] = "COMPLETED"
    service.paypal.reconcile(ident)
    assert payload(client.get("/v1/me", headers=headers))["products"] == [LIFETIME]
    response = client.post(f"/v1/paypal/orders/{ident}/refund", headers=headers, json={})
    assert response.json()["status"] == "cancelled"
    payment["status"] = "COMPLETED"  # Delayed/out-of-order provider observation.
    service.paypal.reconcile(ident)
    assert payload(client.get("/v1/me", headers=headers))["products"] == []
    assert service.paypal.row(ident)["status"] == "cancelled"


def test_paypal_yearly_uses_original_capture_date_and_never_renews_automatically(pp, env):
    client, service, fake, headers, _ = pp
    start = env[4][0]
    ident = order(pp, YEARLY)
    assert capture(pp, ident).status_code == 200
    assert service.paypal.row(ident)["expires"] == next_month(start, 12)
    assert payload(client.get("/v1/me", headers=headers))["products"] == [MONTHLY]
    env[4][0] += 400
    service.paypal.reconcile(ident)
    assert service.paypal.row(ident)["expires"] == next_month(start, 12)
    assert service.db.all("SELECT * FROM subscriptions") == []


def test_paypal_webhook_signature_and_refund_up_link(pp):
    client, service, fake, headers, _ = pp
    ident = order(pp)
    assert capture(pp, ident).status_code == 200
    cid = service.paypal.row(ident)["capture_id"]
    event = {"event_type": "PAYMENT.CAPTURE.REFUNDED", "resource": {"id": "REFUND0001", "links": [
        {"rel": "up", "href": fake.base + "/v2/payments/captures/" + cid}]}}
    wh = {"paypal-auth-algo": "SHA256withRSA", "paypal-cert-url": "https://api.paypal.com/cert.pem",
          "paypal-transmission-id": "fixture", "paypal-transmission-sig": "fixture", "paypal-transmission-time": "fixture"}
    assert client.post("/v1/paypal/webhook", json=event).status_code == 400
    fake.signature = "FAILURE"
    assert client.post("/v1/paypal/webhook", json=event, headers=wh).status_code == 400
    assert payload(client.get("/v1/me", headers=headers))["products"] == [LIFETIME]
    fake.signature = "SUCCESS"
    # A signed event alone cannot revoke/grant: the capture API is authoritative.
    assert client.post("/v1/paypal/webhook", json=event, headers=wh).status_code == 200
    assert payload(client.get("/v1/me", headers=headers))["products"] == [LIFETIME]
    fake.payments[cid]["status"] = "REFUNDED"
    for _ in range(2):
        assert client.post("/v1/paypal/webhook", json=event, headers=wh).status_code == 200
    assert payload(client.get("/v1/me", headers=headers))["products"] == []


def test_paypal_sandbox_identity_cannot_mix_merchants_and_live(pp):
    _, service, _, _, _ = pp
    assert PayPalAPI(service.c).base == "https://api-m.sandbox.paypal.com"
    assert PayPalAPI(replace(service.c, environment="production")).base == "https://api-m.paypal.com"
    service.c = replace(service.c, paypal_merchant_id="OTHERSELLER")
    with pytest.raises(ValueError, match="Do not mix"):
        PayPalCheckout(service)


def test_live_refund_requires_administrator(pp):
    client, service, _, headers, _ = pp
    ident = order(pp)
    assert capture(pp, ident).status_code == 200
    service.paypal.c = replace(service.c, environment="production")
    assert client.post(f"/v1/paypal/orders/{ident}/refund", headers=headers, json={}).status_code == 403


def test_disabling_new_sales_keeps_existing_payment_and_refund_reconciliation(pp, env):
    client, service, fake, headers, _ = pp
    ident = order(pp)
    service.paypal.c = replace(service.c, paypal_enabled=False)
    assert capture(pp, ident).status_code == 503
    assert not fake.payments
    service.paypal.c = service.c
    assert capture(pp, ident).status_code == 200
    service.paypal.c = replace(service.c, paypal_enabled=False)
    env[4][0] += 301
    assert payload(client.get("/v1/me", headers=headers))["products"] == [LIFETIME]
    fake.payments[service.paypal.row(ident)["capture_id"]]["status"] = "REFUNDED"
    env[4][0] += 301
    assert payload(client.get("/v1/me", headers=headers))["products"] == []
