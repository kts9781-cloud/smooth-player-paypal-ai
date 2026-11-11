"""PayPal Orders v2 checkout; verified captures feed the existing signed license.

Sandbox/live endpoints are selected only by the deployment environment. No
browser-return parameter or webhook payload is used as proof of payment.
"""
import json
import re
import threading
import time
import uuid
from datetime import datetime
from decimal import Decimal, InvalidOperation
from urllib.parse import urlsplit

import httpx

from .locking import serialized
from .providers import InvalidPurchase, ProviderUnavailable, VerifiedPurchase, LIFETIME, YEARLY


class PayPalAPI:
    def __init__(self, config):
        self.c = config
        self.base = "https://api-m.sandbox.paypal.com" if config.environment == "test" else "https://api-m.paypal.com"
        self.token, self.until = "", 0.0
        self.lock = threading.Lock()

    def access_token(self):
        with self.lock:
            if self.token and time.monotonic() < self.until:
                return self.token
            try:
                response = httpx.post(self.base + "/v1/oauth2/token",
                                      auth=(self.c.paypal_client, self.c.paypal_secret),
                                      data={"grant_type": "client_credentials"}, timeout=20)
                response.raise_for_status()
                result = response.json()
                token, seconds = result["access_token"], int(result["expires_in"])
                if not isinstance(token, str) or not token or seconds <= 0:
                    raise ValueError()
                self.token, self.until = token, time.monotonic() + max(0, seconds - 60)
                return token
            except (httpx.HTTPError, ValueError, KeyError, TypeError) as error:
                raise ProviderUnavailable("PayPal authentication unavailable") from error

    def request(self, method, path, body=None, request_id=None):
        if not self.c.paypal_client or not self.c.paypal_secret:
            raise ProviderUnavailable("PayPal is not configured")
        headers = {"Authorization": "Bearer " + self.access_token(), "Prefer": "return=representation"}
        if request_id:
            headers["PayPal-Request-Id"] = request_id
        try:
            response = httpx.request(method, self.base + path, json=body, headers=headers, timeout=20)
            if response.status_code in (401, 403, 429) or response.status_code >= 500:
                if response.status_code == 401:
                    self.until = 0
                raise ProviderUnavailable("PayPal is temporarily unavailable")
            if response.status_code >= 400:
                raise InvalidPurchase()
            data = response.json()
            if not isinstance(data, dict):
                raise ValueError()
            return data
        except (httpx.HTTPError, ValueError) as error:
            raise ProviderUnavailable("PayPal response unavailable") from error


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Z0-9]{8,40}", value):
        raise InvalidPurchase()
    return value


def matches_amount(value, cents):
    if not isinstance(value, dict) or value.get("currency_code") != "USD":
        return False
    raw = value.get("value")
    if not isinstance(raw, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]{1,2})?", raw):
        return False
    try:
        return Decimal(raw) == Decimal(cents) / 100
    except InvalidOperation:
        return False


class PayPalCheckout:
    def __init__(self, service):
        self.s, self.c, self.db = service, service.c, service.db
        self.financial_lock = service.financial_lock
        self.api = PayPalAPI(self.c)
        if self.c.paypal_client:
            identity = json.dumps([self.c.environment, self.c.paypal_merchant_id])
            with self.db.transaction() as db:
                db.execute("INSERT OR IGNORE INTO metadata VALUES('paypal-deployment',?)", (identity,))
                if db.execute("SELECT value FROM metadata WHERE key='paypal-deployment'").fetchone()[0] != identity:
                    raise ValueError("Do not mix PayPal merchants or environments in one database")

    def catalog(self):
        products = []
        if self.c.paypal_enabled:
            for product, title, price in [(LIFETIME, "Lifetime access", self.c.paypal_lifetime_cents),
                                          (YEARLY, "One year of access", self.c.paypal_yearly_cents)]:
                if price > 0:
                    products.append({"id": product, "title": title, "amount": price, "currency": "USD",
                                     "recurring": False, "period": "P1Y" if product == YEARLY else None})
        return {"products": products, "environment": "sandbox" if self.c.environment == "test" else "live"}

    def row(self, order_id, user=None):
        from .service import Failure
        row = self.db.one("SELECT * FROM paypal_orders WHERE id=?", (order_id,))
        if not row or (user and row["user_id"] != user["id"]):
            raise Failure(404, "Order not found")
        return row

    def purchasable(self, user):
        from .service import Failure
        if self.s.is_admin(user) or self.db.one("SELECT 1 FROM complimentary_grants WHERE user_id=?", (user["id"],)):
            raise Failure(409, "You already have access; another purchase is not needed.")
        self.s.refresh_purchases(user["id"])
        if self.db.one("SELECT 1 FROM purchases WHERE user_id=? AND active=1 AND (expires IS NULL OR expires>?)",
                       (user["id"], self.s.now())):
            raise Failure(409, "You already have an active license.")

    def approval(self, data):
        host = "www.sandbox.paypal.com" if self.c.environment == "test" else "www.paypal.com"
        for link in data.get("links", []):
            if not isinstance(link, dict) or link.get("rel") not in ("payer-action", "approve"):
                continue
            try:
                url = urlsplit(link.get("href", ""))
                if url.scheme == "https" and url.hostname == host and not url.username and not url.password and url.port in (None, 443):
                    return link["href"]
            except (ValueError, TypeError):
                continue
        raise ProviderUnavailable("PayPal did not provide an approval link")

    @serialized
    def create(self, user, product, amount, terms_version, language="ko"):
        from .service import Failure
        self.s.rate("paypal-order:" + user["id"], 10, 600)
        item = next((p for p in self.catalog()["products"] if p["id"] == product), None)
        if not item:
            raise Failure(503, "This PayPal offer is not available.")
        if amount != item["amount"] or terms_version != self.c.terms_version:
            raise Failure(409, "The price or terms changed. Please refresh checkout.")
        self.purchasable(user)
        row = self.db.one("SELECT * FROM paypal_orders WHERE user_id=? AND product=? AND amount=? AND terms_version=? AND status IN ('created','pending') AND created>? ORDER BY created DESC LIMIT 1",
                          (user["id"], product, amount, terms_version, self.s.now() - 1800))
        if row is None:
            order_id = str(uuid.uuid4())
            with self.db.transaction() as db:
                db.execute("INSERT INTO paypal_orders(id,user_id,product,amount,currency,created,status,terms_version) VALUES(?,?,?,?,?,?,?,?)",
                           (order_id, user["id"], product, amount, "USD", self.s.now(), "created", terms_version))
                db.execute("INSERT INTO checkout_consents VALUES(?,?,?,?,?)", (order_id, user["id"], terms_version, amount, self.s.now()))
            row = self.row(order_id)
        order_id = row["id"]
        return_base = self.c.origin + ("/en/" if language == "en" else "/")
        if row["provider_order"]:
            data = self.api.request("GET", "/v2/checkout/orders/" + identifier(row["provider_order"]))
        else:
            data = self.api.request("POST", "/v2/checkout/orders", {
                "intent": "CAPTURE",
                "purchase_units": [{"reference_id": order_id, "custom_id": order_id, "invoice_id": order_id,
                                    "description": "Smooth Player — " + item["title"],
                                    "payee": {"merchant_id": self.c.paypal_merchant_id},
                                    "amount": {"currency_code": "USD", "value": f"{amount // 100}.{amount % 100:02d}"}}],
                "payment_source": {"paypal": {"experience_context": {
                    "brand_name": "Smooth Player", "shipping_preference": "NO_SHIPPING", "user_action": "PAY_NOW",
                    "locale": "en-US" if language == "en" else "ko-KR",
                    "return_url": return_base + "?flow=paypal&order=" + order_id,
                    "cancel_url": return_base + "?flow=paypal-cancel&order=" + order_id}}}}, order_id)
            paypal_id = identifier(data.get("id"))
            with self.db.transaction() as db:
                db.execute("UPDATE paypal_orders SET provider_order=? WHERE id=?", (paypal_id, order_id))
        if data.get("status") == "COMPLETED":
            self.reconcile(order_id)
            return {"orderId": order_id, "completed": True}
        if data.get("status") == "APPROVED":
            return {"orderId": order_id, "approved": True}
        return {"orderId": order_id, "approvalURL": self.approval(data), "amount": amount, "currency": "USD"}

    def validate_order(self, row, data):
        units = data.get("purchase_units", [])
        if (data.get("id") != row["provider_order"] or data.get("intent") != "CAPTURE"
                or not isinstance(units, list) or len(units) != 1 or not isinstance(units[0], dict)):
            raise InvalidPurchase()
        unit = units[0]
        if (unit.get("custom_id") != row["id"] or not matches_amount(unit.get("amount"), row["amount"])
                or unit.get("payee", {}).get("merchant_id") != self.c.paypal_merchant_id):
            raise InvalidPurchase()
        return unit

    @serialized
    def capture(self, user, order_id):
        from .service import Failure
        self.s.rate("paypal-capture:" + user["id"], 20, 600)
        row = self.row(order_id, user)
        if not row["provider_order"]:
            raise Failure(409, "The order has not been created at PayPal.")
        data = self.api.request("GET", "/v2/checkout/orders/" + identifier(row["provider_order"]))
        unit = self.validate_order(row, data)
        if not unit.get("payments", {}).get("captures"):
            if not self.c.paypal_enabled:
                raise Failure(503, "New PayPal payments are temporarily disabled.")
            if row["status"] == "cancelled" or row["created"] < self.s.now() - 1800:
                raise Failure(410, "This order is no longer available for payment.")
            if data.get("status") != "APPROVED":
                raise Failure(409, "Approve the payment at PayPal first.")
            self.purchasable(user)
            with self.db.transaction() as db:
                db.execute("UPDATE paypal_orders SET status='pending' WHERE id=?", (order_id,))
            self.api.request("POST", "/v2/checkout/orders/" + identifier(row["provider_order"]) + "/capture", {},
                             str(uuid.uuid5(uuid.NAMESPACE_URL, "paypal-capture:" + order_id)))
        self.reconcile(order_id)
        current = self.row(order_id)
        return {"status": current["status"], "account": self.s.entitlement(user, refresh=False)}

    @serialized
    def reconcile(self, order_id):
        from .service import next_month
        row = self.row(order_id)
        if not row["provider_order"]:
            return
        data = self.api.request("GET", "/v2/checkout/orders/" + identifier(row["provider_order"]))
        unit = self.validate_order(row, data)
        captures = unit.get("payments", {}).get("captures", [])
        if not captures:
            with self.db.transaction() as db:
                db.execute("UPDATE paypal_orders SET checked=? WHERE id=?", (self.s.now(), order_id))
            return
        if len(captures) != 1:
            raise InvalidPurchase()
        capture_id = identifier(captures[0].get("id"))
        if row["capture_id"] and row["capture_id"] != capture_id:
            raise InvalidPurchase()
        payment = self.api.request("GET", "/v2/payments/captures/" + capture_id)
        if payment.get("id") != capture_id or not matches_amount(payment.get("amount"), row["amount"]):
            raise InvalidPurchase()
        related = payment.get("supplementary_data", {}).get("related_ids", {}).get("order_id")
        if related and related != row["provider_order"]:
            raise InvalidPurchase()
        status = payment.get("status")
        if status not in ("COMPLETED", "REFUNDED", "PARTIALLY_REFUNDED", "DECLINED", "FAILED", "PENDING"):
            raise InvalidPurchase()
        active = status == "COMPLETED" and row["status"] != "cancelled"
        expires = row["expires"]
        if row["product"] == YEARLY and expires is None:
            try:
                created = datetime.fromisoformat(payment["create_time"].replace("Z", "+00:00"))
                if created.tzinfo is None or created.timestamp() > self.s.now() + 300:
                    raise ValueError()
                expires = next_month(int(created.timestamp()), 12)
            except (KeyError, ValueError, TypeError) as error:
                raise InvalidPurchase() from error
        terminal = row["status"] == "cancelled" or status in ("REFUNDED", "PARTIALLY_REFUNDED", "DECLINED", "FAILED")
        with self.db.transaction() as db:
            # License and terminal refund state commit together. A crash must
            # never leave a refunded license eligible for stale reactivation.
            self.s.save_purchase("paypal", VerifiedPurchase(capture_id, row["product"], active, expires, row["user_id"]),
                                 row["user_id"], {"orderId": order_id}, require_active=False, connection=db)
            db.execute("UPDATE paypal_orders SET capture_id=?,status=?,expires=?,checked=? WHERE id=?",
                       (capture_id, "cancelled" if terminal else "done" if active else "pending", expires, self.s.now(), order_id))

    def reconcile_pending(self, limit, deadline):
        failures = 0
        if not self.c.paypal_client:
            return failures
        rows = self.db.all("SELECT id FROM paypal_orders WHERE status IN ('created','pending') AND provider_order IS NOT NULL ORDER BY checked,created LIMIT ?", (limit,))
        for row in rows:
            if time.monotonic() >= deadline:
                break
            try:
                self.reconcile(row[0])
            except (ProviderUnavailable, InvalidPurchase):
                failures += 1
                with self.db.transaction() as db:
                    db.execute("UPDATE paypal_orders SET checked=? WHERE id=?", (self.s.now(), row[0]))
        return failures

    @serialized
    def refund(self, user, order_id):
        from .service import Failure
        # Self-service refunds exist only in the non-monetary sandbox demo.
        if self.c.environment != "test" and not self.s.is_admin(user):
            raise Failure(403, "Contact support to request a refund.")
        row = self.row(order_id, None if self.s.is_admin(user) else user)
        if not row["capture_id"]:
            raise Failure(409, "There is no captured payment to refund.")
        self.s.rate("paypal-refund:" + user["id"], 10, 600)
        if row["status"] != "cancelled":
            self.api.request("POST", "/v2/payments/captures/" + identifier(row["capture_id"]) + "/refund", {},
                             str(uuid.uuid5(uuid.NAMESPACE_URL, "paypal-refund:" + order_id)))
        self.reconcile(order_id)
        return {"status": self.row(order_id)["status"]}

    def webhook(self, headers, event):
        from .service import Failure
        if not self.c.paypal_client or not self.c.paypal_webhook_id:
            raise Failure(404, "Webhook not configured")
        self.s.rate("paypal-webhook", 120, 60)
        fields = {"auth_algo": "paypal-auth-algo", "cert_url": "paypal-cert-url", "transmission_id": "paypal-transmission-id",
                  "transmission_sig": "paypal-transmission-sig", "transmission_time": "paypal-transmission-time"}
        payload = {key: headers.get(header, "") for key, header in fields.items()}
        if not all(isinstance(v, str) and 0 < len(v) <= 4096 for v in payload.values()) or not isinstance(event, dict):
            raise Failure(400, "Invalid webhook")
        payload.update(webhook_id=self.c.paypal_webhook_id, webhook_event=event)
        result = self.api.request("POST", "/v1/notifications/verify-webhook-signature", payload)
        if result.get("verification_status") != "SUCCESS":
            raise Failure(400, "Invalid webhook signature")
        # The authenticated event only requests an authoritative API refresh.
        resource = event.get("resource", {})
        if not isinstance(resource, dict):
            raise Failure(400, "Invalid webhook resource")
        related = resource.get("supplementary_data", {}).get("related_ids", {})
        capture = related.get("capture_id", "")
        # Refund resources reference the original capture through their up link.
        for link in resource.get("links", []):
            if not isinstance(link, dict) or link.get("rel") != "up":
                continue
            url = link.get("href", "")
            prefix = self.api.base + "/v2/payments/captures/"
            if isinstance(url, str) and url.startswith(prefix) and re.fullmatch(r"[A-Z0-9]{8,40}", url[len(prefix):]):
                capture = url[len(prefix):]
        rows = self.db.all("SELECT id FROM paypal_orders WHERE provider_order=? OR capture_id=? OR capture_id=?",
                           (related.get("order_id", ""), capture, resource.get("id", "")))
        for row in rows:
            self.reconcile(row[0])
        return {"ok": True}
