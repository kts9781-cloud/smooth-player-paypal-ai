import time
import base64
from dataclasses import replace
from datetime import datetime, timezone
from types import SimpleNamespace

import httpx
import pytest

from smooth_accounts.providers import InvalidPurchase, LIFETIME, MONTHLY, YEARLY, ProviderUnavailable, Providers
from .test_accounts import env


def google_response(monkeypatch, data):
    from google.oauth2.service_account import Credentials
    monkeypatch.setattr(Credentials, "from_service_account_file", lambda *a, **k: SimpleNamespace(token="fixture", refresh=lambda request: None))
    def get(url, **kwargs):
        assert url.startswith("https://androidpublisher.googleapis.com/androidpublisher/v3/applications/com.nodelabs.smoothplayer/purchases/")
        assert kwargs["headers"]["Authorization"] == "Bearer fixture"
        return httpx.Response(200, json=data, request=httpx.Request("GET", url))
    monkeypatch.setattr(httpx, "get", get)


def test_google_lifetime_environment_and_product(monkeypatch, env):
    provider = Providers(replace(env[1].c, google_credentials="fixture.json"))
    data = {"productLineItem": [{"productId": LIFETIME}], "purchaseStateContext": {"purchaseState": "PURCHASED"}, "testPurchaseContext": {}, "obfuscatedExternalAccountId": "owner"}
    google_response(monkeypatch, data)
    result = provider.google({"product": LIFETIME, "token": "proof"})
    assert result.active and result.account == "owner"
    provider.c = replace(provider.c, environment="production")
    with pytest.raises(InvalidPurchase): provider.google({"product": LIFETIME, "token": "proof"})
    provider.c = replace(provider.c, environment="test")
    data["productLineItem"] = [{"productId": "unrelated"}]
    with pytest.raises(InvalidPurchase): provider.google({"product": LIFETIME, "token": "proof"})


def test_google_cloud_credentials_and_real_unbound_lifetime(monkeypatch, env):
    from google.oauth2.service_account import Credentials
    data = {"productLineItem": [{"productId": LIFETIME}], "purchaseStateContext": {"purchaseState": "PURCHASED"}}
    google_response(monkeypatch, data)
    seen = []
    def load(info, scopes):
        seen.append(info)
        assert scopes == ["https://www.googleapis.com/auth/androidpublisher"]
        return SimpleNamespace(token="fixture", refresh=lambda request: None)
    monkeypatch.setattr(Credentials, "from_service_account_info", load)
    provider = Providers(replace(env[1].c, environment="production", google_credentials_json='{"type":"service_account"}'))
    result = provider.google({"product": LIFETIME, "token": "real-proof"})
    assert result.active and result.account is None and result.reference == "real-proof"
    assert seen == [{"type": "service_account"}]
    provider.c = replace(provider.c, google_credentials_json="invalid")
    with pytest.raises(ProviderUnavailable): provider.google({"product": LIFETIME, "token": "real-proof"})


@pytest.mark.parametrize("state,active", [("ACTIVE", True), ("IN_GRACE_PERIOD", True), ("CANCELED", True), ("ON_HOLD", False), ("PAUSED", False), ("EXPIRED", False), ("PENDING", False)])
@pytest.mark.parametrize("product", [MONTHLY, YEARLY])
def test_google_monthly_states(monkeypatch, env, state, active, product):
    data = {"lineItems": [{"productId": product, "expiryTime": datetime.fromtimestamp(time.time() + 3600, timezone.utc).isoformat()}], "subscriptionState": "SUBSCRIPTION_STATE_" + state, "testPurchase": {}, "linkedPurchaseToken": "previous"}
    google_response(monkeypatch, data)
    result = Providers(replace(env[1].c, google_credentials="fixture.json")).google({"product": product, "token": "proof"})
    assert result.active == active and result.linked_reference == "previous"


def test_toss_uses_secret_on_server_and_stable_idempotency(monkeypatch, env):
    def request(method, url, **kwargs):
        assert url == "https://api.tosspayments.com/v1/payments/confirm"
        assert kwargs["headers"]["Idempotency-Key"] == "stable-order"
        assert kwargs["headers"]["Authorization"].startswith("Basic ")
        return httpx.Response(200, json={"status": "DONE"})
    monkeypatch.setattr(httpx, "request", request)
    assert Providers(env[1].c).toss("POST", "payments/confirm", {}, "stable-order")["status"] == "DONE"


@pytest.mark.parametrize("status,error", [(401, ProviderUnavailable), (429, ProviderUnavailable), (503, ProviderUnavailable), (400, InvalidPurchase)])
def test_toss_error_classification(monkeypatch, env, status, error):
    monkeypatch.setattr(httpx, "request", lambda *a, **k: httpx.Response(status, json={"code": "fixture"}))
    with pytest.raises(error): Providers(env[1].c).toss("GET", "payments/orders/example")


@pytest.mark.parametrize("status,revoked,owned,expected", [(1, False, "PURCHASED", True), (4, False, "PURCHASED", True), (2, False, "PURCHASED", False), (1, True, "PURCHASED", False), (1, False, "FAMILY_SHARED", None)])
@pytest.mark.parametrize("product", [MONTHLY, YEARLY])
@pytest.mark.parametrize("cloud_credentials", [False, True])
def test_apple_current_state_grace_and_ownership(monkeypatch, env, tmp_path, status, revoked, owned, expected, product, cloud_credentials):
    import appstoreserverlibrary.api_client
    import appstoreserverlibrary.signed_data_verifier
    expiry = int((time.time() + 3600) * 1000)
    transaction = SimpleNamespace(transactionId="tx", originalTransactionId="original", productId=product, rawInAppOwnershipType=owned,
                                  rawType="Auto-Renewable Subscription", expiresDate=expiry, revocationDate=1 if revoked else None, isUpgraded=False, appAccountToken=None)
    class Verifier:
        def __init__(self, roots, online, environment, bundle, app_id):
            assert online and bundle == "com.nodelabs.smoothplayer" and roots == [b"fixture"]
            assert environment.value == "Sandbox"
        def verify_and_decode_signed_transaction(self, proof):
            if proof not in ("submitted", "current"): raise ValueError("invalid signature")
            return transaction
        def verify_and_decode_renewal_info(self, proof): return SimpleNamespace(gracePeriodExpiresDate=expiry + 3600000)
    class API:
        def __init__(self, key, key_id, issuer, bundle, environment):
            assert key == b"fixture" and key_id == "id" and issuer == "issuer"
            assert environment.value == "Sandbox"
        def get_transaction_info(self, identifier): return SimpleNamespace(signedTransactionInfo="current")
        def get_all_subscription_statuses(self, identifier):
            return SimpleNamespace(data=[SimpleNamespace(lastTransactions=[SimpleNamespace(originalTransactionId="original", signedTransactionInfo="current", signedRenewalInfo="renewal", rawStatus=status)])])
    monkeypatch.setattr(appstoreserverlibrary.api_client, "AppStoreServerAPIClient", API)
    monkeypatch.setattr(appstoreserverlibrary.signed_data_verifier, "SignedDataVerifier", Verifier)
    cert = tmp_path / "root.cer"; cert.write_bytes(b"fixture")
    provider = Providers(replace(env[1].c, apple_roots=str(cert), apple_key_file=str(cert), apple_key_id="id", apple_issuer="issuer"))
    if cloud_credentials:
        provider.c = replace(provider.c, apple_roots="", apple_key_file="", apple_key_pem="fixture", apple_roots_base64=base64.b64encode(b"fixture").decode())
    if expected is None:
        with pytest.raises(InvalidPurchase): provider.apple({"signedTransaction": "submitted"})
    else:
        result = provider.apple({"signedTransaction": "submitted"})
        assert result.active == expected
        if status == 4: assert result.expires == (expiry + 3600000) // 1000
    with pytest.raises(InvalidPurchase): provider.apple({"signedTransaction": "forged"})


def test_apple_bad_cloud_config_fails_closed(env):
    provider = Providers(replace(env[1].c, apple_key_pem="invalid", apple_roots_base64="!invalid!", apple_key_id="id", apple_issuer="issuer"))
    with pytest.raises(ProviderUnavailable):
        provider.apple({"signedTransaction": "forged"})
