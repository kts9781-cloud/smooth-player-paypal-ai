from dataclasses import replace
from datetime import datetime, timezone

from smooth_accounts.providers import LIFETIME, MONTHLY, YEARLY
from smooth_accounts.service import next_month
from .test_accounts import env, login, payload


def subscribe(env, product=YEARLY, email="annual@example.test"):
    client, service, *_ = env
    service.c = replace(service.c, yearly_price=9900, monthly_price=990, lifetime_price=59400)
    headers, _ = login(env, email)
    response = client.post("/v1/orders", headers=headers, json={"product": product})
    assert response.status_code == 200, response.text
    order = response.json()
    result = client.post("/v1/billing/confirm", headers=headers, json={
        "orderId": order["orderId"], "customerKey": order["customerKey"], "authKey": "fixture-auth"})
    assert payload(result)["products"] == [MONTHLY]  # v1 time-limited capability, not a monthly charge.
    return headers, order


def test_yearly_renews_once_a_year_at_agreed_amount_and_cancellation_keeps_access(env):
    client, service, _, provider, now, _ = env
    start = now[0]
    headers, order = subscribe(env)
    identifier = order["orderId"]
    sub = service.db.one("SELECT * FROM subscriptions WHERE id=?", (identifier,))
    assert sub["next_due"] == next_month(start, 12)
    assert sub["amount"] == 9900
    assert service.db.one("SELECT product FROM orders WHERE subscription_id=?", (identifier,))[0] == YEARLY
    assert len(provider.payments) == 1
    now[0] = next_month(start)
    service.charge_subscription(identifier)
    assert len(provider.payments) == 1
    now[0] = next_month(start, 12)
    service.c = replace(service.c, yearly_price=12000)
    service.charge_subscription(identifier)
    service.charge_subscription(identifier)
    assert len(provider.payments) == 2
    assert {p["totalAmount"] for p in provider.payments.values()} == {9900}
    assert all(billing for _, _, billing in provider.billing_calls)
    headers, _ = login(env, "annual@example.test")
    assert client.get("/v1/subscriptions", headers=headers).json()["subscriptions"][0]["product"] == YEARLY
    client.post(f"/v1/subscriptions/{identifier}/cancel", headers=headers, json={})
    assert payload(client.get("/v1/me", headers=headers))["products"] == [MONTHLY]
    now[0] = next_month(now[0], 12)
    service.charge_subscription(identifier)
    assert len(provider.payments) == 2
    headers, _ = login(env, "annual@example.test")
    assert payload(client.get("/v1/me", headers=headers))["products"] == []


def test_yearly_refund_and_contract_gate(env):
    client, service, _, provider, *_ = env
    headers, order = subscribe(env)
    payment = next(iter(provider.payments.values()))
    payment["status"] = "CANCELED"; payment["balanceAmount"] = 0
    service.reconcile_order(payment["orderId"])
    assert payload(client.get("/v1/me", headers=headers))["products"] == []
    assert service.db.one("SELECT cancelled FROM subscriptions WHERE id=?", (order["orderId"],))[0] == 1
    service.c = replace(service.c, billing_enabled=False)
    fresh, _ = login(env, "fresh@example.test")
    assert client.post("/v1/orders", headers=fresh, json={"product": YEARLY}).status_code == 503


def test_monthly_and_yearly_quotes_do_not_alias_when_amounts_match(env):
    client, service, *_ = env
    service.c = replace(service.c, monthly_price=990, yearly_price=990)
    headers, _ = login(env)
    monthly = client.post("/v1/orders", headers=headers, json={"product": MONTHLY}).json()
    yearly = client.post("/v1/orders", headers=headers, json={"product": YEARLY}).json()
    assert monthly["orderId"] != yearly["orderId"]
    assert yearly["orderId"] == client.post("/v1/orders", headers=headers, json={"product": YEARLY}).json()["orderId"]


def test_legacy_monthly_without_product_mapping_keeps_monthly_cycle(env):
    client, service, _, provider, now, _ = env
    _, order = subscribe(env, MONTHLY)
    identifier = order["orderId"]
    with service.db.transaction() as db:
        db.execute("DELETE FROM billing_products WHERE id=?", (identifier,))
    now[0] = service.db.one("SELECT next_due FROM subscriptions WHERE id=?", (identifier,))[0]
    service.charge_subscription(identifier)
    assert service.db.one("SELECT next_due FROM subscriptions WHERE id=?", (identifier,))[0] == next_month(now[0])
    assert len(provider.payments) == 2


def test_yearly_calendar_leap_day_and_price_disclosure(env):
    stamp = int(datetime(2028, 2, 29, 10, tzinfo=timezone.utc).timestamp())
    assert datetime.fromtimestamp(next_month(stamp, 12), timezone.utc) == datetime(2029, 2, 28, 10, tzinfo=timezone.utc)
    client, service, *_ = env
    service.c = replace(service.c, yearly_price=9900, monthly_price=990, lifetime_price=59400)
    offers = {p["id"]: p for p in client.get("/v1/catalog").json()["offers"]}
    assert offers[YEARLY]["period"] == "P1Y" and offers[YEARLY]["recurring"]
    assert {k:v["amount"] for k,v in offers.items()} == {MONTHLY:990, YEARLY:9900, LIFETIME:59400}
    assert "연 9,900원" in client.get("/terms").text
