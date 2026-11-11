import calendar
import hmac
import hashlib
import json
import re
import secrets
import time
import uuid
from datetime import datetime, timezone
from urllib.parse import quote

from .providers import InvalidPurchase, LIFETIME, MONTHLY, YEARLY, SUBSCRIPTIONS, ProviderUnavailable, Providers
from .security import SMTPMailer, Secrets, digest
from .storage import Database
from .locking import FinancialLock, serialized


class Failure(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


def next_month(stamp, months=1):
    date = datetime.fromtimestamp(stamp, timezone.utc)
    year, month0 = divmod(date.year * 12 + date.month - 1 + months, 12)
    month = month0 + 1
    return int(date.replace(year=year, month=month, day=min(date.day, calendar.monthrange(year, month)[1])).timestamp())


class Service:
    def __init__(self, config, mailer=None, providers=None, clock=time.time):
        config.validate()
        self.c, self.clock = config, clock
        self.financial_lock = FinancialLock(config.database)
        self.db, self.secrets = Database(config.database), Secrets(config)
        with self.db.transaction() as db:
            identity = json.dumps([config.environment, config.origin])
            db.execute("INSERT OR IGNORE INTO metadata VALUES('deployment',?)", (identity,))
            if db.execute("SELECT value FROM metadata WHERE key='deployment'").fetchone()[0] != identity:
                raise ValueError("Use separate databases for each environment and origin")
        self.mailer, self.providers = mailer or SMTPMailer(config), providers or Providers(config)
        from .social import SocialAuth
        self.social = SocialAuth(self)
        from .paypal import PayPalCheckout
        self.paypal = PayPalCheckout(self)

    def now(self):
        return int(self.clock())

    def is_admin(self, user):
        # Only the authenticated, existing database identity can receive this role.
        # Recreating an account with the same email never inherits administration.
        return bool(self.c.admin_user_id and not user["deleted"] and user["id"] == self.c.admin_user_id
                    and user["email"].lower() == self.c.admin_email)

    def is_review_email(self, email):
        return bool(self.c.review_email and email == self.c.review_email)

    def code_digest(self, identifier, code):
        return hmac.new(self.c.encryption_key.encode(), (identifier + code).encode(), hashlib.sha256).hexdigest()

    def rate(self, bucket, maximum, seconds):
        now = self.now()
        with self.db.transaction() as db:
            db.execute("DELETE FROM rate_limits WHERE expires<=?", (now,))
            row = db.execute("SELECT count FROM rate_limits WHERE bucket=?", (bucket,)).fetchone()
            if row and row[0] >= maximum:
                raise Failure(429, "요청이 많습니다. 잠시 후 다시 시도해 주세요.")
            db.execute("INSERT INTO rate_limits VALUES(?,1,?) ON CONFLICT(bucket) DO UPDATE SET count=rate_limits.count+1", (bucket, now + seconds))

    def request_code(self, email, ip):
        email = email.strip().lower()
        if len(email) > 254 or not re.fullmatch(r"[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+", email):
            raise Failure(400, "이메일 주소를 확인해 주세요.")
        self.rate("mail-ip:" + digest(ip), 20, 3600)
        self.rate("mail:" + digest(email), 1, 60)
        self.rate("mail-hour:" + digest(email), 6, 3600)
        reserved = email.endswith("@review.smoothplayer.invalid")
        if reserved and not self.is_review_email(email):
            raise Failure(400, "이 계정의 심사 접근이 활성화되지 않았습니다.")
        identifier, code = str(uuid.uuid4()), f"{secrets.randbelow(100000000):08d}"
        with self.db.transaction() as db:
            db.execute("UPDATE challenges SET used=1 WHERE email=?", (email,))
            db.execute("INSERT INTO challenges(id,email,digest,expires) VALUES(?,?,?,?)", (identifier, email, self.code_digest(identifier, code), self.now() + 600))
        if reserved:
            return {"challengeId": identifier, "message": "스토어 심사 안내에 제공된 전용 인증 코드를 입력해 주세요."}
        try:
            self.mailer.send(email, code)
        except Exception as error:
            with self.db.transaction() as db:
                db.execute("UPDATE challenges SET used=1 WHERE id=?", (identifier,))
            raise Failure(503, "인증 메일을 보내지 못했습니다. 잠시 후 다시 시도해 주세요.") from error
        return {"challengeId": identifier, "message": "이메일로 인증 코드를 보냈습니다."}

    def verify_code(self, identifier, code, ip):
        self.rate("verify:" + digest(ip), 40, 600)
        token, now = secrets.token_urlsafe(48), self.now()
        invalid = False
        with self.db.transaction() as db:
            row = db.execute("SELECT * FROM challenges WHERE id=?", (identifier,)).fetchone()
            if not row or row["used"] or row["expires"] <= now or row["attempts"] >= 5:
                invalid = True
            else:
                db.execute("UPDATE challenges SET attempts=attempts+1 WHERE id=?", (identifier,))
                if row["email"].endswith("@review.smoothplayer.invalid"):
                    valid = self.is_review_email(row["email"]) and bool(re.fullmatch(r"[0-9]{8}", code)) and hmac.compare_digest(self.c.review_code_digest, digest(code))
                else:
                    valid = hmac.compare_digest(row["digest"], self.code_digest(identifier, code))
                if not valid:
                    invalid = True
                else:
                    db.execute("UPDATE challenges SET used=1 WHERE id=?", (identifier,))
                    db.execute("INSERT OR IGNORE INTO users VALUES(?,?,?,0)", (str(uuid.uuid4()), row["email"], now))
                    user = db.execute("SELECT * FROM users WHERE email=?", (row["email"],)).fetchone()
                    db.execute("INSERT INTO sessions VALUES(?,?,?)", (digest(token), user["id"], now + 30 * 86400))
        if invalid:
            raise Failure(401, "인증 코드가 올바르지 않거나 만료되었습니다.")
        return {"token": token, "userId": user["id"], "email": user["email"], "expiresAt": now + 30 * 86400}

    def user(self, token):
        user = self.db.one("SELECT u.* FROM users u JOIN sessions s ON s.user_id=u.id WHERE s.digest=? AND s.expires>? AND u.deleted=0", (digest(token), self.now()))
        if not user or (user["email"].endswith("@review.smoothplayer.invalid") and not self.is_review_email(user["email"])):
            raise Failure(401, "다시 로그인해 주세요.")
        return user

    def logout(self, token):
        with self.db.transaction() as db:
            db.execute("DELETE FROM sessions WHERE digest=?", (digest(token),))

    @serialized
    def delete_user(self, user):
        with self.db.transaction() as db:
            self.social.queue_deletion(db, user["id"])
            db.execute("UPDATE subscriptions SET cancelled=1 WHERE user_id=?", (user["id"],))
            db.execute("DELETE FROM sessions WHERE user_id=?", (user["id"],))
            db.execute("DELETE FROM challenges WHERE email=?", (user["email"],))
            db.execute("DELETE FROM complimentary_grants WHERE user_id=?", (user["id"],))
            db.execute("DELETE FROM nas_sync WHERE user_id=?", (user["id"],))
            # Preserve purchase ownership/accounting tombstones; never free a receipt for another account.
            db.execute("UPDATE users SET deleted=1,email=? WHERE id=?", ("deleted:" + user["id"], user["id"]))
            db.execute("INSERT OR IGNORE INTO account_deletions VALUES(?,?)", (user["id"], self.now()))

    def save_purchase(self, provider, purchase, user_id, proof, require_active=True, *, connection=None):
        from contextlib import nullcontext
        if purchase.account and purchase.account.lower() != user_id.lower():
            raise Failure(409, "다른 계정에 연결된 구매입니다.")
        if require_active and (not purchase.active or (purchase.expires is not None and purchase.expires <= self.now())):
            raise Failure(400, "현재 사용할 수 있는 구매가 아닙니다.")
        with (nullcontext(connection) if connection is not None else self.db.transaction()) as db:
            for reference in [purchase.reference, purchase.linked_reference]:
                if reference:
                    owner = db.execute("SELECT user_id FROM purchases WHERE provider=? AND reference=?", (provider, reference)).fetchone()
                    if owner and owner[0] != user_id:
                        raise Failure(409, "이미 다른 계정에 연결된 구매입니다.")
            db.execute("""INSERT INTO purchases VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(provider,reference) DO UPDATE SET
                product=excluded.product,active=excluded.active,expires=excluded.expires,proof=excluded.proof,checked=excluded.checked""",
                       (provider, purchase.reference, user_id, purchase.product, int(purchase.active), purchase.expires, self.secrets.encrypt(json.dumps(proof)), self.now()))
            if purchase.linked_reference and purchase.linked_reference != purchase.reference:
                db.execute("UPDATE purchases SET active=0 WHERE provider=? AND reference=? AND user_id=?", (provider, purchase.linked_reference, user_id))

    @serialized
    def claim(self, user, provider, proof):
        if provider not in ("apple", "google"):
            raise Failure(400, "지원하지 않는 구매 경로입니다.")
        self.rate("claim:" + user["id"], 20, 3600)
        verified = getattr(self.providers, provider)(proof)
        self.save_purchase(provider, verified, user["id"], proof)
        return self.entitlement(user, refresh=False)

    @serialized
    def refresh_purchases(self, user_id, *, deadline=None, limit=20):
        # Provider network errors keep the last verified state, but cannot extend its offline lease.
        failures = 0
        for row in self.db.all("SELECT * FROM purchases WHERE user_id=? AND checked<? ORDER BY checked LIMIT ?", (user_id, self.now() - 300, limit)):
            if deadline is not None and time.monotonic() >= deadline:
                break
            try:
                proof = json.loads(self.secrets.decrypt(row["proof"]))
                if row["provider"] == "toss":
                    self.reconcile_order(proof["orderId"])
                elif row["provider"] == "paypal":
                    self.paypal.reconcile(proof["orderId"])
                else:
                    purchase = getattr(self.providers, row["provider"])(proof)
                    self.save_purchase(row["provider"], purchase, user_id, proof, require_active=False)
            except ProviderUnavailable:
                failures += 1
                continue
            except InvalidPurchase:
                with self.db.transaction() as db:
                    db.execute("UPDATE purchases SET active=0,checked=? WHERE provider=? AND reference=?", (self.now(), row["provider"], row["reference"]))
        return failures

    def entitlement(self, user, refresh=True):
        if refresh:
            self.refresh_purchases(user["id"])
        now = self.now()
        rows = self.db.all("SELECT * FROM purchases WHERE user_id=? AND active=1 AND (expires IS NULL OR expires>?) AND checked>?", (user["id"], now, now - self.c.offline_seconds))
        expires = max([min(row["checked"] + self.c.offline_seconds, row["expires"] or now + self.c.offline_seconds) for row in rows], default=now + 300)
        # v1 clients only recognize monthly/lifetime capability IDs. A yearly
        # purchase grants the same time-limited capability, bounded by its actual
        # verified expiry. Orders/receipts retain YEARLY; never issue lifetime.
        products = {MONTHLY if row["product"] == YEARLY else row["product"] for row in rows}
        sources = {row["provider"] for row in rows}
        administrator = self.is_admin(user)
        if administrator:
            products.add(LIFETIME)
            sources.add("administrator")
            expires = max(expires, now + self.c.offline_seconds)
            with self.db.transaction() as db:
                db.execute("UPDATE subscriptions SET cancelled=1 WHERE user_id=? AND cancelled=0", (user["id"],))
        if self.db.one("SELECT 1 FROM complimentary_grants WHERE user_id=?", (user["id"],)):
            products.add(LIFETIME)
            sources.add("complimentary")
            expires = max(expires, now + self.c.offline_seconds)
        payload = {"version": 1, "issuer": self.c.origin, "environment": self.c.environment, "subject": user["id"], "issuedAt": now,
                   "expiresAt": expires, "products": sorted(products)}
        return {"license": self.secrets.sign(payload), "email": user["email"], "userId": user["id"], "sources": sorted(sources), "isAdmin": administrator}

    @serialized
    def redeem_complimentary(self, user, code, ip):
        self.rate("redeem-user:" + user["id"], 6, 600)
        self.rate("redeem-ip:" + digest(ip), 30, 3600)
        candidate = digest(code.strip())
        if not self.c.complimentary_code_digest or not hmac.compare_digest(candidate, self.c.complimentary_code_digest):
            raise Failure(400, "유효한 무료 이용 코드가 아닙니다. 전달받은 코드를 확인해 주세요.")
        with self.db.transaction() as db:
            db.execute("INSERT OR IGNORE INTO complimentary_grants VALUES(?,?,?)", (user["id"], candidate, self.now()))
            # Free access must not silently continue charging a Toss subscription.
            db.execute("UPDATE subscriptions SET cancelled=1 WHERE user_id=?", (user["id"],))
        return self.entitlement(user, refresh=False)

    def catalog(self):
        products = []
        if self.c.lifetime_enabled and self.c.toss_secret and self.c.toss_client:
            if self.c.lifetime_price > 0:
                products.append({"id": LIFETIME, "title": "평생 이용권", "amount": self.c.lifetime_price, "currency": "KRW", "recurring": False})
        if self.c.billing_enabled and self.c.toss_billing_secret and self.c.toss_billing_client:
            for product, title, price, period in ((MONTHLY, "월 구독", self.c.monthly_price, "P1M"),
                                                  (YEARLY, "연간 구독", self.c.yearly_price, "P1Y")):
                if price > 0:
                    products.append({"id": product, "title": title, "amount": price, "currency": "KRW", "recurring": True, "period": period})
        return {"products": products, "clientKey": self.c.toss_client, "environment": self.c.environment,
                "paypal": self.paypal.catalog(),
                "complimentaryEnabled": bool(self.c.complimentary_code_digest),
                "termsVersion": self.c.terms_version,
                "offers": [{"id": product, "title": title, "amount": price, "currency": "KRW", "recurring": recurring,
                            "period": "P1Y" if product == YEARLY else "P1M" if recurring else None,
                            "available": any(p["id"] == product for p in products)}
                           for product, title, price, recurring in ((LIFETIME, "평생 이용권", self.c.lifetime_price, False),
                                                                    (MONTHLY, "월 구독", self.c.monthly_price, True),
                                                                    (YEARLY, "연간 구독", self.c.yearly_price, True)) if price > 0],
                "seller": {"상호": self.c.seller_name, "대표자": self.c.seller_representative,
                           "사업자등록번호": self.c.seller_registration, "통신판매업 신고번호": self.c.seller_sales_registration,
                           "주소": self.c.seller_address, "전화": self.c.seller_phone, "이메일": self.c.seller_email},
                "links": {"개인정보 처리방침": self.c.privacy_url, "이용약관": self.c.terms_url, "고객 지원": self.c.support_url}}

    @serialized
    def create_order(self, user, product, amount=None, terms_version=""):
        self.rate("order:" + user["id"], 10, 600)
        if self.is_admin(user):
            raise Failure(409, "관리자 계정은 모든 기능을 무료로 사용할 수 있습니다. 결제가 필요하지 않습니다.")
        if self.db.one("SELECT 1 FROM complimentary_grants WHERE user_id=?", (user["id"],)):
            raise Failure(409, "무료 이용권을 사용 중입니다. 추가 구매가 필요하지 않습니다.")
        self.refresh_purchases(user["id"])
        if self.db.one("SELECT 1 FROM purchases WHERE user_id=? AND active=1 AND (expires IS NULL OR expires>?)", (user["id"], self.now())):
            raise Failure(409, "이미 이용권이 있습니다. 현재 이용권을 확인해 주세요.")
        item = next((x for x in self.catalog()["products"] if x["id"] == product), None)
        if not item:
            raise Failure(503, "아직 판매하지 않는 이용권입니다.")
        if self.c.environment == "production" or amount is not None or terms_version:
            if amount != item["amount"] or not self.c.terms_version or terms_version != self.c.terms_version:
                raise Failure(409, "가격 또는 이용약관이 변경되었습니다. 페이지를 새로고침하고 다시 확인해 주세요.")
        identifier = str(uuid.uuid4())
        with self.db.transaction() as db:
            if product in SUBSCRIPTIONS:
                existing = db.execute("SELECT a.id FROM billing_auth a LEFT JOIN billing_products p ON p.id=a.id WHERE a.user_id=? AND a.used=0 AND a.created>? AND a.amount=? AND COALESCE(p.product,?)=?", (user["id"], self.now() - 1800, item["amount"], MONTHLY, product)).fetchone()
                if existing:
                    identifier = existing[0]
                else:
                    db.execute("INSERT INTO billing_auth VALUES(?,?,?,0,?,NULL)", (identifier, user["id"], self.now(), item["amount"]))
                    db.execute("INSERT INTO billing_products VALUES(?,?,?)", (identifier, user["id"], product))
            else:
                existing = db.execute("SELECT id FROM orders WHERE user_id=? AND product=? AND status IN ('created','pending') AND created>? AND amount=?", (user["id"], product, self.now() - 1800, item["amount"])).fetchone()
                if existing:
                    identifier = existing[0]
                else:
                    db.execute("INSERT INTO orders(id,user_id,product,amount,status,created) VALUES(?,?,?,?,?,?)", (identifier, user["id"], product, item["amount"], "created", self.now()))
            if terms_version:
                db.execute("INSERT INTO checkout_consents VALUES(?,?,?,?,?) ON CONFLICT(order_id) DO UPDATE SET terms_version=excluded.terms_version,amount=excluded.amount,accepted_at=excluded.accepted_at",
                           (identifier, user["id"], terms_version, item["amount"], self.now()))
        return {"orderId": identifier, "customerKey": user["id"], "amount": item["amount"], "product": product,
                "clientKey": self.c.toss_billing_client if product in SUBSCRIPTIONS else self.c.toss_client}

    def owned_order(self, user, identifier):
        order = self.db.one("SELECT * FROM orders WHERE id=? AND user_id=?", (identifier, user["id"]))
        if not order:
            raise Failure(404, "주문을 찾지 못했습니다.")
        return order

    @serialized
    def confirm(self, user, identifier, payment_key, amount):
        if self.is_admin(user):
            raise Failure(409, "관리자 계정은 결제가 필요하지 않습니다.")
        order = self.owned_order(user, identifier)
        if order["product"] != LIFETIME or order["amount"] != amount:
            raise Failure(400, "주문 금액이 일치하지 않습니다.")
        if not self.c.lifetime_enabled and order["status"] not in ("done", "cancelled"):
            # Disabling sales also stops approval from an already-open checkout.
            # An earlier approval may have succeeded despite a lost HTTP response;
            # recover that outcome by querying only, never by charging again.
            if order["payment_key"]:
                try:
                    self.reconcile_order(identifier)
                except InvalidPurchase:
                    pass
                if self.owned_order(user, identifier)["status"] in ("done", "cancelled"):
                    return self.entitlement(user, refresh=False)
            raise Failure(503, "현재 이용권 판매가 중단되어 결제를 진행하지 않았습니다.")
        if order["status"] in ("created", "pending") and self.db.one("SELECT 1 FROM complimentary_grants WHERE user_id=?", (user["id"],)):
            # A checkout opened before free-code redemption must not create a new charge.
            # If an earlier approval timed out, only query it; never retry approval here.
            if order["payment_key"]:
                try:
                    self.reconcile_order(identifier)
                except InvalidPurchase:
                    pass
            raise Failure(409, "무료 이용권이 등록되어 추가 결제를 진행하지 않았습니다. 이전 결제 내역은 고객 지원에서 확인할 수 있습니다.")
        with self.db.transaction() as db:
            current = db.execute("SELECT * FROM orders WHERE id=?", (identifier,)).fetchone()
            if current["payment_key"] and current["payment_key"] != payment_key:
                raise Failure(409, "이미 처리 중인 주문입니다.")
            if current["status"] == "created" and current["created"] < self.now() - 1800:
                raise Failure(410, "주문이 만료되었습니다.")
            db.execute("UPDATE orders SET payment_key=?,status=CASE WHEN status='created' THEN 'pending' ELSE status END WHERE id=?", (payment_key, identifier))
        if current["status"] not in ("done", "cancelled"):
            result = self.providers.toss("POST", "payments/confirm", {"orderId": identifier, "paymentKey": payment_key, "amount": amount}, identifier)
            self.apply_payment(order, result)
        else:
            self.reconcile_order(identifier)
        return self.entitlement(user, refresh=False)

    def apply_payment(self, order, payment):
        from .providers import VerifiedPurchase
        if payment.get("orderId") != order["id"] or payment.get("totalAmount") != order["amount"] or payment.get("currency") != "KRW" or not payment.get("paymentKey"):
            raise InvalidPurchase()
        current = self.db.one("SELECT payment_key,status FROM orders WHERE id=?", (order["id"],))
        if current[0] and current[0] != payment["paymentKey"]:
            raise InvalidPurchase()
        active = payment.get("status") == "DONE" and payment.get("balanceAmount", order["amount"]) == order["amount"]
        if payment.get("status") not in ("DONE", "CANCELED", "PARTIAL_CANCELED", "EXPIRED", "ABORTED"):
            return  # Pending approval/deposit is not paid and is not terminal cancellation.
        if current["status"] == "cancelled":
            active = False  # An old success response cannot undo an already verified refund.
        expiry = next_month(order["cycle"], 12 if order["product"] == YEARLY else 1) if order["subscription_id"] else None
        verified = VerifiedPurchase(payment["paymentKey"], order["product"], active, expiry)
        self.save_purchase("toss", verified, order["user_id"], {"orderId": order["id"]}, require_active=False)
        with self.db.transaction() as db:
            db.execute("UPDATE orders SET payment_key=?,status=? WHERE id=?", (payment["paymentKey"], "done" if active else "cancelled", order["id"]))
            if active and order["subscription_id"]:
                db.execute("UPDATE subscriptions SET next_due=MAX(next_due,?) WHERE id=?", (expiry, order["subscription_id"]))
            elif order["subscription_id"]:
                db.execute("UPDATE subscriptions SET cancelled=1 WHERE id=?", (order["subscription_id"],))

    @serialized
    def reconcile_order(self, identifier):
        order = self.db.one("SELECT * FROM orders WHERE id=?", (identifier,))
        if order:
            result = self.providers.toss("GET", "payments/orders/" + quote(identifier, safe=""), billing=order["product"] in SUBSCRIPTIONS)
            self.apply_payment(order, result)

    @serialized
    def confirm_billing(self, user, identifier, auth_key, customer_key):
        if self.is_admin(user):
            raise Failure(409, "관리자 계정에는 자동결제를 등록하지 않습니다.")
        if not self.c.billing_enabled or customer_key != user["id"]:
            raise Failure(400, "자동결제 정보를 확인해 주세요.")
        if self.db.one("SELECT 1 FROM complimentary_grants WHERE user_id=?", (user["id"],)):
            raise Failure(409, "무료 이용권을 사용 중입니다. 자동결제를 등록하지 않았습니다.")
        with self.db.transaction() as db:
            row = db.execute("SELECT * FROM billing_auth WHERE id=? AND user_id=?", (identifier, user["id"])).fetchone()
            if not row or row["created"] < self.now() - 1800:
                raise Failure(409, "자동결제 등록이 만료되었거나 이미 처리되었습니다.")
            if row["auth_digest"] and not hmac.compare_digest(row["auth_digest"], digest(auth_key)):
                raise Failure(409, "처리 중인 자동결제 등록과 일치하지 않습니다.")
            db.execute("UPDATE billing_auth SET auth_digest=? WHERE id=?", (digest(auth_key), identifier))
        if row["used"]:
            self.charge_subscription(identifier)
            return self.entitlement(user, refresh=False)
        if self.db.one("SELECT 1 FROM subscriptions WHERE user_id=? AND cancelled=0", (user["id"],)):
            raise Failure(409, "이미 자동결제를 이용 중입니다.")
        result = self.providers.toss("POST", "billing/authorizations/issue", {"authKey": auth_key, "customerKey": customer_key}, identifier, billing=True)
        if result.get("customerKey") != customer_key or not result.get("billingKey"):
            raise InvalidPurchase()
        with self.db.transaction() as db:
            if db.execute("SELECT 1 FROM subscriptions WHERE user_id=? AND cancelled=0", (user["id"],)).fetchone():
                raise Failure(409, "이미 자동결제를 이용 중입니다.")
            db.execute("INSERT INTO subscriptions VALUES(?,?,?,?,?,0,?)", (identifier, user["id"], self.secrets.encrypt(result["billingKey"]), row["amount"], self.now(), self.now()))
            db.execute("UPDATE billing_auth SET used=1 WHERE id=?", (identifier,))
        self.charge_subscription(identifier)
        return self.entitlement(user, refresh=False)

    @serialized
    def charge_subscription(self, identifier):
        with self.db.transaction() as db:
            sub = db.execute("SELECT * FROM subscriptions WHERE id=?", (identifier,)).fetchone()
            if sub:
                owner = db.execute("SELECT * FROM users WHERE id=?", (sub["user_id"],)).fetchone()
                if owner and self.is_admin(owner):
                    db.execute("UPDATE subscriptions SET cancelled=1 WHERE id=?", (identifier,))
                    return
            if not sub or sub["cancelled"] or sub["next_due"] > self.now():
                return
            cycle = sub["next_due"]
            plan = db.execute("SELECT product FROM billing_products WHERE id=?", (identifier,)).fetchone()
            product = plan[0] if plan else MONTHLY  # Preserve existing monthly subscriptions.
            if product not in SUBSCRIPTIONS:
                raise Failure(400, "구독 상품을 확인할 수 없습니다.")
            if cycle < self.now() - 3 * 86400:
                db.execute("UPDATE subscriptions SET cancelled=1 WHERE id=?", (identifier,))
                return  # Never collect a backlog of missed subscription months.
            order_id = str(uuid.uuid5(uuid.NAMESPACE_URL, identifier + ":" + str(cycle)))
            db.execute("INSERT OR IGNORE INTO orders VALUES(?,?,?,?,?,?,NULL,?,?)", (order_id, sub["user_id"], product, sub["amount"], "pending", self.now(), identifier, cycle))
            order = db.execute("SELECT * FROM orders WHERE id=?", (order_id,)).fetchone()
        # A stable order and idempotency key survive retries and worker restarts.
        # Query first after a prior ambiguous timeout; the stable idempotency key
        # still protects the initial attempt and the network boundary.
        try:
            prior = self.providers.toss("GET", "payments/orders/" + quote(order_id, safe=""), billing=True)
        except InvalidPurchase:
            prior = None
        if prior is not None:
            self.apply_payment(order, prior)
            return
        result = self.providers.toss("POST", "billing/" + quote(self.secrets.decrypt(sub["billing_key"]), safe=""),
                                     {"customerKey": sub["user_id"], "amount": sub["amount"], "orderId": order_id, "orderName": "Smooth Player " + ("연간 구독" if product == YEARLY else "월 구독")}, order_id, billing=True)
        self.apply_payment(order, result)

    @serialized
    def cancel_subscription(self, user, identifier):
        with self.db.transaction() as db:
            db.execute("UPDATE subscriptions SET cancelled=1 WHERE id=? AND user_id=?", (identifier, user["id"]))

    def reconcile(self, *, max_items=20, max_seconds=180):
        # Leave headroom below the function timeout; later runs take the next
        # oldest items. Provider failures must not produce a successful cron.
        deadline = time.monotonic() + max_seconds
        self.purge_expired_records()
        failures = self.paypal.reconcile_pending(max_items, deadline)
        # Approval can succeed at Toss while its HTTP response is lost. Such an
        # order has no purchase row yet, so purchase-only reconciliation misses it.
        # Query authoritative state only; never create a second charge here.
        for row in self.db.all("SELECT o.id FROM orders o LEFT JOIN pending_payment_checks p ON p.order_id=o.id WHERE o.status='pending' AND o.payment_key IS NOT NULL ORDER BY COALESCE(p.checked,0),o.created LIMIT ?", (max_items,)):
            if time.monotonic() >= deadline:
                return failures
            try:
                self.reconcile_order(row[0])
            except (ProviderUnavailable, InvalidPurchase):
                failures += 1
            finally:
                with self.db.transaction() as db:
                    db.execute("INSERT INTO pending_payment_checks VALUES(?,?) ON CONFLICT(order_id) DO UPDATE SET checked=excluded.checked", (row[0], self.now()))
        for row in self.db.all("SELECT id FROM subscriptions WHERE cancelled=0 AND next_due<=? ORDER BY next_due LIMIT ?", (self.now(), max_items)):
            if time.monotonic() >= deadline:
                return failures
            try:
                self.charge_subscription(row[0])
            except (ProviderUnavailable, InvalidPurchase):
                failures += 1
        for row in self.db.all("SELECT user_id FROM purchases WHERE checked<? GROUP BY user_id ORDER BY MIN(checked) LIMIT ?", (self.now() - 300, max_items)):
            if time.monotonic() >= deadline:
                break
            failures += self.refresh_purchases(row[0], deadline=deadline)
        return failures

    @serialized
    def purge_expired_records(self):
        now = self.now()
        with self.db.transaction() as db:
            db.execute("DELETE FROM challenges WHERE expires<=?", (now,))
            db.execute("DELETE FROM sessions WHERE expires<=?", (now,))
            db.execute("DELETE FROM rate_limits WHERE expires<=?", (now,))
            db.execute("DELETE FROM social_attempts WHERE expires<=?", (now,))
            db.execute("DELETE FROM social_deleted_identities WHERE deleted<?", (now - 86400,))
            # Five calendar years from account deletion. Valid accounts/grants and
            # all newer transaction records remain intact; batch the maintenance.
            date = datetime.fromtimestamp(now, timezone.utc)
            cutoff = int(date.replace(year=date.year - 5, day=min(date.day, calendar.monthrange(date.year - 5, date.month)[1])).timestamp())
            rows = db.execute("SELECT user_id FROM account_deletions WHERE deleted_at<? LIMIT 20", (cutoff,)).fetchall()
            for row in rows:
                identifier = row[0]
                if not db.execute("SELECT 1 FROM users WHERE id=? AND deleted=1", (identifier,)).fetchone():
                    continue
                db.execute("DELETE FROM pending_payment_checks WHERE order_id IN (SELECT id FROM orders WHERE user_id=?)", (identifier,))
                for table in ("sessions", "purchases", "orders", "paypal_orders", "subscriptions", "billing_auth", "billing_products", "checkout_consents", "complimentary_grants", "account_deletions"):
                    db.execute(f"DELETE FROM {table} WHERE user_id=?", (identifier,))
                db.execute("DELETE FROM users WHERE id=?", (identifier,))
