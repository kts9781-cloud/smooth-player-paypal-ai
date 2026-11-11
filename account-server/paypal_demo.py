"""Run real PayPal Sandbox checkout locally, isolated from production accounts.

Run with the account-server directory on PYTHONPATH. Only synthetic demo email
identities are accepted. The payment provider is PayPal's real Sandbox API.
"""
import argparse
import json
from pathlib import Path

import uvicorn
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from smooth_accounts.app import create_app
from smooth_accounts.config import Config
from smooth_accounts.security import digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credentials", type=Path, required=True, help="Private JSON with Sandbox client, secret, merchant_id")
    parser.add_argument("--directory", type=Path, required=True, help="Private demo state, outside the public source directory")
    parser.add_argument("--public-config", type=Path, required=True, help="Native app public origin/key/environment JSON")
    parser.add_argument("--port", type=int, default=8876)
    args = parser.parse_args()
    directory = args.directory.resolve()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    credentials = json.loads(args.credentials.read_text())
    key_path, encryption_path = directory / "signing.pem", directory / "encryption.key"
    if not key_path.exists():
        key = ec.generate_private_key(ec.SECP256R1())
        key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    if not encryption_path.exists():
        encryption_path.write_bytes(Fernet.generate_key())
    key_path.chmod(0o600); encryption_path.chmod(0o600)

    class DemoMail:
        def send(self, email, code):
            raise ValueError("Use demo@review.smoothplayer.invalid with the documented local demo code")

    config = Config(database=str(directory / "sandbox.sqlite3"), origin=f"http://127.0.0.1:{args.port}", environment="test",
                    signing_key_file=str(key_path), encryption_key=encryption_path.read_text().strip(),
                    paypal_enabled=True, paypal_client=credentials["client"], paypal_secret=credentials["secret"],
                    paypal_merchant_id=credentials["merchant_id"], paypal_lifetime_cents=100, paypal_yearly_cents=50,
                    terms_version="sandbox-demo-2026-11-11", review_email="demo@review.smoothplayer.invalid",
                    review_code_digest=digest("24681357"), privacy_url="https://smooth-player-accounts.vercel.app/privacy",
                    terms_url="https://smooth-player-accounts.vercel.app/terms", support_url="https://smooth-player-accounts.vercel.app/support")
    app = create_app(config, mailer=DemoMail())
    args.public_config.parent.mkdir(parents=True, exist_ok=True)
    args.public_config.write_text(json.dumps({"origin": config.origin, "publicKey": app.state.service.secrets.public_key,
                                             "environment": "test"}, indent=2) + "\n")
    print(f"Sandbox only: {config.origin}/en/; demo@review.smoothplayer.invalid / 24681357", flush=True)
    uvicorn.run(app, host="127.0.0.1", port=args.port, access_log=False, proxy_headers=False)


if __name__ == "__main__":
    main()
