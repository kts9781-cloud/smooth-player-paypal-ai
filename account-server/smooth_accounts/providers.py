import base64
import json
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from urllib.parse import quote

import httpx

MONTHLY = "smooth_monthly"
YEARLY = "smooth_yearly"
LIFETIME = "smooth_lifetime"
SUBSCRIPTIONS = {MONTHLY, YEARLY}
PRODUCTS = {*SUBSCRIPTIONS, LIFETIME}


class ProviderUnavailable(Exception):
    pass


class InvalidPurchase(Exception):
    pass


@dataclass
class VerifiedPurchase:
    reference: str
    product: str
    active: bool
    expires: int | None = None
    account: str | None = None
    linked_reference: str | None = None


class Providers:
    def __init__(self, config):
        self.c = config

    def toss(self, method, path, body=None, idempotency=None, *, billing=False):
        secret = self.c.toss_billing_secret if billing else self.c.toss_secret
        if not secret:
            raise ProviderUnavailable("Toss is not configured")
        headers = {"Authorization": "Basic " + base64.b64encode((secret + ":").encode()).decode()}
        if idempotency:
            headers["Idempotency-Key"] = idempotency
        try:
            result = httpx.request(method, "https://api.tosspayments.com/v1/" + path, json=body, headers=headers, timeout=20)
            if result.status_code in (401, 403, 429) or result.status_code >= 500:
                raise ProviderUnavailable()
            if result.status_code >= 400:
                raise InvalidPurchase()
            return result.json()
        except (httpx.HTTPError, ValueError) as error:
            raise ProviderUnavailable() from error

    def apple(self, proof):
        c = self.c
        if not all((c.apple_roots or c.apple_roots_base64, c.apple_key_file or c.apple_key_pem, c.apple_key_id, c.apple_issuer)):
            raise ProviderUnavailable("Apple is not configured")
        from appstoreserverlibrary.api_client import AppStoreServerAPIClient
        from appstoreserverlibrary.models.Environment import Environment
        from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier
        environment = Environment.PRODUCTION if c.environment == "production" else Environment.SANDBOX
        try:
            roots = [base64.b64decode(p, validate=True) for p in c.apple_roots_base64.split(",")] if c.apple_roots_base64 else [Path(p).read_bytes() for p in c.apple_roots.split(",")]
            key = c.apple_key_pem.encode() if c.apple_key_pem else Path(c.apple_key_file).read_bytes()
            verifier = SignedDataVerifier(roots, True, environment, c.apple_bundle, c.apple_app_id or None)
            api = AppStoreServerAPIClient(key, c.apple_key_id, c.apple_issuer, c.apple_bundle, environment)
        except Exception as error:
            raise ProviderUnavailable("Apple verification configuration is invalid") from error
        try:
            submitted = verifier.verify_and_decode_signed_transaction(proof["signedTransaction"])
        except Exception as error:
            raise InvalidPurchase() from error
        try:
            current = verifier.verify_and_decode_signed_transaction(api.get_transaction_info(submitted.transactionId).signedTransactionInfo)
            status = None
            grace = None
            if current.productId in SUBSCRIPTIONS:
                entries = api.get_all_subscription_statuses(current.originalTransactionId)
                matching = [item for group in entries.data or [] for item in group.lastTransactions or [] if item.originalTransactionId == current.originalTransactionId]
                if not matching:
                    raise InvalidPurchase()
                item = matching[0]
                current = verifier.verify_and_decode_signed_transaction(item.signedTransactionInfo)
                status = item.rawStatus
                if status == 4 and item.signedRenewalInfo:
                    grace = verifier.verify_and_decode_renewal_info(item.signedRenewalInfo).gracePeriodExpiresDate
        except InvalidPurchase:
            raise
        except Exception as error:
            raise ProviderUnavailable() from error
        if current.productId not in PRODUCTS or current.rawInAppOwnershipType != "PURCHASED":
            raise InvalidPurchase()
        expected = "Auto-Renewable Subscription" if current.productId in SUBSCRIPTIONS else "Non-Consumable"
        if current.rawType != expected or current.originalTransactionId != submitted.originalTransactionId:
            raise InvalidPurchase()
        expiry = int((grace or current.expiresDate) / 1000) if (grace or current.expiresDate) else None
        active = current.revocationDate is None and not current.isUpgraded
        if current.productId in SUBSCRIPTIONS:
            active = active and status in (1, 4) and expiry is not None and expiry > time.time()
        return VerifiedPurchase(current.originalTransactionId, current.productId, active, expiry, str(current.appAccountToken).lower() if current.appAccountToken else None)

    def google(self, proof):
        if not (self.c.google_credentials or self.c.google_credentials_json):
            raise ProviderUnavailable("Google is not configured")
        product, token = proof.get("product"), proof.get("token")
        if product not in PRODUCTS or not isinstance(token, str) or not token or len(token) > 4096:
            raise InvalidPurchase()
        from google.auth.transport.requests import Request
        from google.oauth2.service_account import Credentials
        try:
            scopes = ["https://www.googleapis.com/auth/androidpublisher"]
            credentials = (Credentials.from_service_account_info(json.loads(self.c.google_credentials_json), scopes=scopes)
                           if self.c.google_credentials_json else Credentials.from_service_account_file(self.c.google_credentials, scopes=scopes))
            credentials.refresh(Request())
            base = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/" + quote(self.c.google_package, safe="") + "/purchases/"
            path = ("subscriptionsv2/tokens/" if product in SUBSCRIPTIONS else "productsv2/tokens/") + quote(token, safe="")
            response = httpx.get(base + path, headers={"Authorization": "Bearer " + credentials.token}, timeout=20)
            if response.status_code in (400, 404, 410):
                raise InvalidPurchase()
            response.raise_for_status()
            data = response.json()
        except InvalidPurchase:
            raise
        except Exception as error:
            raise ProviderUnavailable() from error
        is_test = "testPurchase" in data or "testPurchaseContext" in data
        if is_test != (self.c.environment == "test"):
            raise InvalidPurchase()
        items = [item for item in data.get("lineItems", data.get("productLineItem", [])) if item.get("productId") == product]
        if len(items) != 1:
            raise InvalidPurchase()
        if product in SUBSCRIPTIONS:
            expires = int(datetime.fromisoformat(items[0]["expiryTime"].replace("Z", "+00:00")).timestamp())
            active = data.get("subscriptionState") in ("SUBSCRIPTION_STATE_ACTIVE", "SUBSCRIPTION_STATE_IN_GRACE_PERIOD", "SUBSCRIPTION_STATE_CANCELED") and expires > time.time()
            account = data.get("externalAccountIdentifiers", {}).get("obfuscatedExternalAccountId")
        else:
            expires = None
            active = data.get("purchaseStateContext", {}).get("purchaseState") == "PURCHASED"
            account = data.get("obfuscatedExternalAccountId")
        return VerifiedPurchase(token, product, active, expires, account, data.get("linkedPurchaseToken"))
