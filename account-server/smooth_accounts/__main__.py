import argparse
import base64
import os
from pathlib import Path

from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["init-keys", "serve", "reconcile"])
    parser.add_argument("--directory", default="secrets")
    args = parser.parse_args()
    if args.command == "init-keys":
        directory = Path(args.directory)
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        key = ec.generate_private_key(ec.SECP256R1())
        private = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
        public = base64.b64encode(key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo))
        for name, data in [("signing.pem", private), ("encryption.key", Fernet.generate_key()), ("public-key.txt", public)]:
            with os.fdopen(os.open(directory / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as file:
                file.write(data)
        print("Created keys. Pin public-key.txt in app build configuration; keep the other files on the server only.")
    elif args.command == "serve":
        import uvicorn
        # SQLite-backed deployment: one API process plus one scheduled worker, persistent local disk.
        uvicorn.run("smooth_accounts.app:create_app", factory=True, host="127.0.0.1", port=8787, workers=1, access_log=False,
                    proxy_headers=True, forwarded_allow_ips="127.0.0.1")
    else:
        from .config import Config
        from .service import Service
        failures = Service(Config.from_env()).reconcile()
        print(f"Reconciliation completed; provider failures: {failures}")
        raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
