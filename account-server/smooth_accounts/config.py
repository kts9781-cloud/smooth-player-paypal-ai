import os
import re
import uuid
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit


@dataclass(frozen=True)
class Config:
    database: str = "accounts.sqlite3"
    origin: str = "http://127.0.0.1:8787"
    environment: str = "test"
    signing_key_file: str = ""
    signing_key_pem: str = ""
    encryption_key: str = ""
    encryption_key_file: str = ""
    smtp_host: str = ""
    smtp_port: int = 587
    smtp_user: str = ""
    smtp_password: str = ""
    smtp_from: str = ""
    smtp_tls: bool = True
    toss_secret: str = ""
    toss_client: str = ""
    toss_billing_secret: str = ""
    toss_billing_client: str = ""
    paypal_enabled: bool = False
    paypal_client: str = ""
    paypal_secret: str = ""
    paypal_merchant_id: str = ""
    paypal_webhook_id: str = ""
    paypal_lifetime_cents: int = 0
    paypal_yearly_cents: int = 0
    complimentary_code_digest: str = ""
    admin_user_id: str = ""
    admin_email: str = ""
    review_email: str = ""
    review_code_digest: str = ""
    lifetime_price: int = 0
    monthly_price: int = 0
    yearly_price: int = 0
    lifetime_enabled: bool = False
    billing_enabled: bool = False
    apple_key_file: str = ""
    apple_key_pem: str = ""
    apple_key_id: str = ""
    apple_issuer: str = ""
    apple_app_id: int = 0
    apple_bundle: str = "com.nodelabs.smoothplayer"
    apple_roots: str = ""
    apple_roots_base64: str = ""
    google_credentials: str = ""
    google_credentials_json: str = ""
    google_package: str = "com.nodelabs.smoothplayer"
    webhook_token: str = ""
    offline_seconds: int = 86400
    privacy_url: str = ""
    terms_url: str = ""
    support_url: str = ""
    terms_version: str = ""
    seller_name: str = ""
    seller_representative: str = ""
    seller_registration: str = ""
    seller_sales_registration: str = ""
    seller_address: str = ""
    seller_phone: str = ""
    seller_email: str = ""
    cron_secret: str = ""
    google_login_enabled: bool = False
    google_login_client: str = ""
    google_login_secret: str = ""
    apple_login_enabled: bool = False
    apple_login_client: str = ""
    apple_login_team: str = ""
    apple_login_key_id: str = ""
    apple_login_key_pem: str = ""

    @classmethod
    def from_env(cls):
        defaults = cls()
        values = {}
        for name in cls.__dataclass_fields__:
            value = os.environ.get("SMOOTH_" + name.upper())
            if value is None:
                continue
            default = getattr(defaults, name)
            values[name] = value.lower() == "true" if isinstance(default, bool) else int(value) if isinstance(default, int) else value
        config = cls(**values)
        from dataclasses import replace
        if not config.cron_secret and os.environ.get("CRON_SECRET"):
            config = replace(config, cron_secret=os.environ["CRON_SECRET"])
        if not config.encryption_key and config.encryption_key_file:
            config = replace(config, encryption_key=Path(config.encryption_key_file).read_text().strip())
        if os.environ.get("VERCEL") == "1" and not config.database.startswith(("postgres://", "postgresql://")):
            raise ValueError("Vercel requires a persistent PostgreSQL database; local SQLite is not supported")
        config.validate()
        return config

    def validate(self):
        def require(condition, message="Invalid account server configuration"):
            if not condition:
                raise ValueError(message)
        require(self.environment in ("test", "production"), "Unknown environment")
        require(bool(self.admin_user_id) == bool(self.admin_email), "Set both administrator account ID and verified email")
        if self.admin_user_id:
            require(str(uuid.UUID(self.admin_user_id)) == self.admin_user_id, "Use the administrator's existing account UUID")
            require(self.admin_email == self.admin_email.strip().lower() and re.fullmatch(r"[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+", self.admin_email), "Use a normalized administrator email")
        require(bool(self.review_email) == bool(self.review_code_digest), "Set both review account email and code digest")
        if self.review_email:
            require(re.fullmatch(r"[a-z0-9_-]+@review\.smoothplayer\.invalid", self.review_email), "Review access is limited to reserved demo identities")
            require(re.fullmatch(r"[0-9a-f]{64}", self.review_code_digest), "Use a SHA-256 review code digest")
            require(self.review_email != self.admin_email, "Review accounts cannot be administrators")
        origin = urlsplit(self.origin)
        require(origin.hostname and not origin.username and not origin.password and not origin.query and not origin.fragment)
        require(origin.path in ("", "/") and self.origin == self.origin.rstrip("/"), "Origin must not include a path")
        require(origin.scheme == "https" or (self.environment == "test" and origin.scheme == "http" and origin.hostname in ("localhost", "127.0.0.1")))
        require(bool(self.signing_key_pem) or (self.signing_key_file and Path(self.signing_key_file).is_file()), "Set SMOOTH_SIGNING_KEY_FILE or SMOOTH_SIGNING_KEY_PEM")
        require(self.encryption_key, "Set SMOOTH_ENCRYPTION_KEY")
        require(300 <= self.offline_seconds <= 7 * 86400)
        require(self.lifetime_price >= 0 and self.monthly_price >= 0 and self.yearly_price >= 0)
        require(0 <= self.paypal_lifetime_cents <= 1000000 and 0 <= self.paypal_yearly_cents <= 1000000,
                "PayPal USD prices must be integer cents within the supported range")
        if self.paypal_enabled or self.paypal_client or self.paypal_secret or self.paypal_merchant_id:
            require(self.paypal_client and self.paypal_secret and re.fullmatch(r"[A-Z0-9]{8,32}", self.paypal_merchant_id),
                    "PayPal requires credentials and the verified merchant ID for this environment")
        if self.paypal_enabled:
            require(self.paypal_lifetime_cents > 0 or self.paypal_yearly_cents > 0, "Configure a PayPal price")
            require(self.terms_version, "PayPal checkout requires a terms version")
            if self.environment == "production":
                require(self.paypal_webhook_id, "Live PayPal requires its verified webhook configuration")
        if self.google_login_enabled:
            require(self.google_login_client.endswith(".apps.googleusercontent.com") and self.google_login_secret,
                    "Google login requires its dedicated OAuth client credentials")
        if self.apple_login_enabled:
            require(self.apple_login_client and re.fullmatch(r"[A-Z0-9]{10}", self.apple_login_team)
                    and re.fullmatch(r"[A-Z0-9]{10}", self.apple_login_key_id)
                    and "PRIVATE KEY" in self.apple_login_key_pem,
                    "Apple login requires its Services ID and Sign in with Apple key")
        prefix = "live_" if self.environment == "production" else "test_"
        for secret, client in ((self.toss_secret, self.toss_client), (self.toss_billing_secret, self.toss_billing_client)):
            if secret or client:
                require(secret.startswith(prefix) and client.startswith(prefix), "Missing or mixed payment key pair")
        if self.billing_enabled:
            require(self.toss_billing_secret and self.toss_billing_client, "Billing requires its own approved MID key pair")
        if self.complimentary_code_digest:
            require(re.fullmatch(r"[0-9a-f]{64}", self.complimentary_code_digest), "Use a SHA-256 complimentary code digest")
        if self.environment == "production":
            require(self.smtp_host and self.smtp_from and self.smtp_tls, "Production requires encrypted SMTP")
            require(len(self.webhook_token) >= 32, "Set a long webhook token")
            for value in (self.privacy_url, self.terms_url, self.support_url):
                parsed = urlsplit(value)
                require(parsed.scheme == "https" and parsed.hostname and not parsed.username and not parsed.password, "Configure published privacy, terms and support URLs before production")
            require(self.terms_version, "Set the published checkout terms version")
            require(all((self.seller_name, self.seller_representative, self.seller_registration,
                         self.seller_sales_registration, self.seller_address, self.seller_phone, self.seller_email)),
                    "Configure the verified seller details before production")
