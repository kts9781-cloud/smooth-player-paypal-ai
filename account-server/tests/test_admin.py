import base64
import json
import uuid
from dataclasses import replace
from datetime import datetime, timezone, timedelta

import pytest
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec

from smooth_accounts.providers import LIFETIME, MONTHLY, YEARLY, VerifiedPurchase
from .test_accounts import env, login, payload


def administrator(env):
    headers, session = login(env, "owner@example.test")
    env[1].c = replace(env[1].c, admin_user_id=session["userId"], admin_email=session["email"])
    return headers, session


def metrics(result):
    return {section["id"]: {m["id"]: m["value"] for m in section["metrics"]} for section in result["sections"]}


def test_admin_role_is_server_owned_and_never_inferred_from_email(env):
    client, service, *_ = env
    admin, _ = administrator(env)
    member, _ = login(env)
    assert client.get("/v1/admin/overview").status_code == 401
    assert client.get("/v1/admin/overview", headers={**member, "X-Admin": "true", "X-Email": service.c.admin_email}).status_code == 403
    response = client.get("/v1/admin/overview", headers=admin)
    assert response.status_code == 200
    assert "no-store" in response.headers["cache-control"]
    assert client.get("/v1/me", headers=member).json()["isAdmin"] is False
    service.c = replace(service.c, admin_user_id=str(uuid.uuid4()))
    assert client.get("/v1/admin/overview", headers=admin).status_code == 403
    assert client.get("/v1/me", headers=admin).json()["isAdmin"] is False


def test_administrator_gets_signed_full_access_without_paid_purchase(env):
    client, service, _, provider, now, key = env
    admin, session = administrator(env)
    response = client.get("/v1/me", headers=admin)
    body = response.json()
    assert body["isAdmin"] is True and body["sources"] == ["administrator"]
    assert payload(response)["products"] == [LIFETIME]
    assert payload(response)["expiresAt"] == now[0] + service.c.offline_seconds
    key.public_key().verify(base64.b64decode(body["license"]["signature"]), base64.b64decode(body["license"]["payload"]), ec.ECDSA(hashes.SHA256()))
    assert client.post("/v1/orders", headers=admin, json={"product": LIFETIME}).status_code == 409
    assert client.post("/v1/billing/confirm", headers=admin, json={"orderId": str(uuid.uuid4()), "authKey": "private-key", "customerKey": session["userId"]}).status_code == 409
    assert not service.db.all("SELECT * FROM purchases")
    values = metrics(client.get("/v1/admin/overview", headers=admin).json())
    assert values["members"]["administrators"] == 1
    assert values["subscriptions"]["paidMembers"] == values["payments"]["amount"] == 0
    assert provider.calls == []


def test_admin_free_access_stops_existing_toss_renewal_before_next_refresh(env):
    client, service, _, provider, now, _ = env
    admin, session = administrator(env)
    with service.db.transaction() as db:
        db.execute("INSERT INTO subscriptions VALUES(?,?,?,?,?,0,?)", ("sub", session["userId"], service.secrets.encrypt("SECRET_BILLING"), 990, now[0], now[0]))
    service.charge_subscription("sub")
    assert service.db.one("SELECT cancelled FROM subscriptions WHERE id='sub'")[0] == 1
    assert provider.calls == [] and not service.db.all("SELECT * FROM orders")
    with service.db.transaction() as db:
        db.execute("UPDATE subscriptions SET cancelled=0,next_due=? WHERE id='sub'", (now[0] + 86400,))
    client.get("/v1/me", headers=admin)
    assert service.db.one("SELECT cancelled FROM subscriptions WHERE id='sub'")[0] == 1


def test_deleted_then_recreated_email_never_inherits_admin(env):
    client, service, _, _, now, _ = env
    admin, old = administrator(env)
    assert client.delete("/v1/account", headers=admin).status_code == 200
    now[0] += 61
    recreated, new = login(env, old["email"])
    assert old["userId"] != new["userId"]
    assert client.get("/v1/admin/overview", headers=recreated).status_code == 403
    assert payload(client.get("/v1/me", headers=recreated))["products"] == []


def test_dashboard_counts_statuses_kst_and_avoids_secrets(env):
    client, service, _, _, now, _ = env
    admin, admin_session = administrator(env)
    member, session = login(env)
    uid = session["userId"]
    today = int(datetime.fromtimestamp(now[0], timezone(timedelta(hours=9))).replace(hour=0, minute=0, second=0, microsecond=0).timestamp())
    with service.db.transaction() as db:
        db.execute("UPDATE users SET created=? WHERE id=?", (today - 1, uid))
        db.execute("INSERT INTO users VALUES(?,?,?,1)", (str(uuid.uuid4()), "deleted@example.test", now[0]))
        for identifier, status, amount in [("paid", "done", 990), ("refund", "cancelled", 9900), ("waiting", "pending", 59400)]:
            db.execute("INSERT INTO orders VALUES(?,?,?,?,?,?,?,NULL,NULL)", (identifier, uid, MONTHLY, amount, status, now[0], "SECRET_PAYMENT_" + identifier))
        db.execute("INSERT INTO complimentary_grants VALUES(?,?,?)", (uid, "SECRET_GRANT_DIGEST", now[0]))
    for provider, reference, product, active, expiry in [
        ("google", "SECRET_PLAY_TOKEN", MONTHLY, True, now[0]+3600),
        ("apple", "SECRET_APPLE_REFERENCE", YEARLY, True, now[0]+86400),
        ("toss", "SECRET_LIFETIME", LIFETIME, True, None),
        ("google", "SECRET_EXPIRED", MONTHLY, True, now[0]-1),
        ("apple", "SECRET_CANCELLED", YEARLY, False, now[0]+1000),
        ("google", "SECRET_STALE", YEARLY, True, now[0]+3600),
    ]:
        service.save_purchase(provider, VerifiedPurchase(reference, product, active, expiry), uid, {"token": "SECRET_PROOF"}, require_active=False)
    with service.db.transaction() as db:
        db.execute("UPDATE purchases SET checked=? WHERE reference='SECRET_STALE'", (now[0]-service.c.offline_seconds,))
    result = client.get("/v1/admin/overview", headers=admin).json()
    values = metrics(result)
    assert values["members"] == {"members":2, "today":1, "week":2, "free":1, "administrators":1}
    assert values["subscriptions"] == {"paidMembers":1, "monthly":1, "yearly":1, "lifetime":1, "unconfirmed":1}
    assert values["payments"] == {"completed":1, "amount":990, "cancelled":1, "pending":1}
    assert any(r["product"] == LIFETIME and r["status"] == "이용 중" for r in result["recentSubscriptions"])
    assert {r["status"] for r in result["recentSubscriptions"]} == {"이용 중", "종료·해제", "기간 만료", "재확인 필요"}
    assert "SECRET_" not in json.dumps(result) and "member@example.test" not in json.dumps(result)
    assert result["timezone"] == "Asia/Seoul"
    login(env, "new@example.test")
    assert metrics(client.get("/v1/admin/overview", headers=admin).json())["members"]["members"] == 3


def test_admin_configuration_requires_existing_uuid_and_normalized_email(env):
    c = env[1].c
    for kwargs in [{"admin_email":"owner@example.test"}, {"admin_user_id":str(uuid.uuid4())},
                   {"admin_user_id":"not-a-uuid", "admin_email":"owner@example.test"},
                   {"admin_user_id":str(uuid.uuid4()), "admin_email":"Owner@Example.Test"}]:
        with pytest.raises(ValueError):
            replace(c, **kwargs).validate()
