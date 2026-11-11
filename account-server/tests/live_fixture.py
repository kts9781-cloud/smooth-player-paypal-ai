"""Loopback-only test harness. No SMTP, store API or actual payment is used."""
import argparse
import json
from pathlib import Path

from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import APIRouter
import uvicorn

from smooth_accounts.app import create_app
from smooth_accounts.config import Config
from smooth_accounts.providers import LIFETIME, VerifiedPurchase
from smooth_accounts.security import digest
from .test_accounts import Provider


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", required=True)
    parser.add_argument("--social", action="store_true", help="Synthetic OIDC provider, loopback fixture only")
    args = parser.parse_args()
    directory = Path(args.directory).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    key = ec.generate_private_key(ec.SECP256R1())
    private = directory / "signing.pem"
    private.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    private.chmod(0o600)
    class Mailer:
        def send(self, email, code):
            if not email.endswith("@example.test"):
                raise ValueError("Synthetic email addresses only")
            (directory / "outbox.json").write_text(json.dumps({"email": email, "code": code}))
    provider = Provider()
    provider.receipts["fixture-receipt"] = VerifiedPurchase("fixture-original", LIFETIME, True)
    config = Config(database=str(directory / "test.sqlite3"), origin="http://127.0.0.1:8874", signing_key_file=str(private), encryption_key=Fernet.generate_key().decode(),
                    toss_secret="test_sk_fixture", toss_client="test_ck_fixture", lifetime_price=19900, lifetime_enabled=True,
                    complimentary_code_digest=digest("fixture-free-code"))
    app = create_app(config, mailer=Mailer(), providers=provider)
    if args.social:
        from dataclasses import replace
        app.state.service.c = replace(config, google_login_enabled=True, google_login_client="fixture.apps.googleusercontent.com",
                                      apple_login_enabled=True, apple_login_client="com.example.login")
        class SocialProvider:
            def exchange(self, provider, code, data):
                if code != "synthetic-code": raise ValueError("Synthetic authorization only")
                return {"subject": "synthetic-" + provider, "email": provider + "@example.test", "revoke_token": "synthetic-token"}
            def revoke(self, provider, token): pass
        app.state.service.social.provider = SocialProvider()
    # These routes exist only in this explicitly launched loopback fixture,
    # never in the deployed account service. The provider performs no payments.
    fixture = APIRouter()
    if args.social:
        @fixture.post("/fixture/social")
        def fixture_social(body: dict):
            from urllib.parse import urlsplit, parse_qs
            broker = app.state.service.social
            row = app.state.service.db.one("SELECT * FROM social_attempts WHERE id=?", (body["id"],))
            url, cookie = broker.browser(body["id"])
            state = parse_qs(urlsplit(url).query)["state"][0]
            broker.callback(row["provider"], {"state": state, "code": "synthetic-code"}, {broker.cookie_name(row["id"]): cookie})
            return {"callback": "smoothplayer-auth://complete?attempt=" + row["id"]}
    @fixture.get("/fixture/code")
    def fixture_code():
        return json.loads((directory / "outbox.json").read_text())

    @fixture.post("/fixture/refund")
    def fixture_refund(body: dict):
        identifier = body["orderId"]
        provider.payments[identifier]["status"] = "CANCELED"
        provider.payments[identifier]["balanceAmount"] = 0
        app.state.service.reconcile_order(identifier)
        return {"refunded": True, "provider": "synthetic-only"}

    # The application's final '/' StaticFiles mount must not shadow these
    # test-only endpoints. Production routes/configuration remain untouched.
    app.router.routes[0:0] = fixture.routes
    (directory / "public-key.txt").write_text(app.state.service.secrets.public_key)
    uvicorn.run(app, host="127.0.0.1", port=8874, access_log=False, proxy_headers=False)


if __name__ == "__main__":
    main()
