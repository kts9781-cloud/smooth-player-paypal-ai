import base64
import hashlib
import json
import smtplib
import ssl
from email.message import EmailMessage
from pathlib import Path

from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec


def digest(value: str):
    return hashlib.sha256(value.encode()).hexdigest()


class Secrets:
    def __init__(self, config):
        self.cipher = Fernet(config.encryption_key.encode())
        key_bytes = config.signing_key_pem.encode() if config.signing_key_pem else Path(config.signing_key_file).read_bytes()
        self.key = serialization.load_pem_private_key(key_bytes, None)
        if not isinstance(self.key, ec.EllipticCurvePrivateKey) or self.key.curve.name != "secp256r1":
            raise ValueError("A P-256 signing key is required")
        self.public_key = base64.b64encode(self.key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)).decode()

    def encrypt(self, value):
        return self.cipher.encrypt(value.encode()).decode()

    def decrypt(self, value):
        return self.cipher.decrypt(value.encode()).decode()

    def sign(self, payload):
        data = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
        signature = self.key.sign(data, ec.ECDSA(hashes.SHA256()))
        return {"payload": base64.b64encode(data).decode(), "signature": base64.b64encode(signature).decode()}


class SMTPMailer:
    def __init__(self, config):
        self.config = config

    def send(self, email, code):
        c = self.config
        if not c.smtp_host or not c.smtp_from:
            raise RuntimeError("SMTP is not configured")
        message = EmailMessage()
        message["From"] = c.smtp_from
        message["To"] = email
        message["Subject"] = "Smooth Player 로그인 인증 코드"
        message.set_content(f"로그인 인증 코드: {code}\n\n10분 안에 입력해 주세요. 요청하지 않았다면 이 메일을 무시하세요.")
        with smtplib.SMTP(c.smtp_host, c.smtp_port, timeout=15) as client:
            if c.smtp_tls:
                client.starttls(context=ssl.create_default_context())
            if c.smtp_user:
                client.login(c.smtp_user, c.smtp_password)
            client.send_message(message)
