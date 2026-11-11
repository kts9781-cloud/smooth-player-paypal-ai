import hmac
import time
from pathlib import Path
from urllib.parse import parse_qsl

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ConfigDict, Field

from .config import Config
from .providers import InvalidPurchase, ProviderUnavailable
from .service import Failure, Service


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid")


class EmailInput(Input):
    email: str = Field(max_length=254)


class CodeInput(Input):
    challengeId: str = Field(max_length=64)
    code: str = Field(pattern=r"^\d{8}$")


class ProductInput(Input):
    product: str = Field(max_length=64)
    amount: int | None = Field(default=None, gt=0, strict=True)
    termsVersion: str = Field(default="", max_length=64)


class PayPalProductInput(ProductInput):
    language: str = Field(default="ko", pattern=r"^(ko|en)$")


class ComplimentaryInput(Input):
    code: str = Field(min_length=1, max_length=128)


class ConfirmInput(Input):
    orderId: str = Field(max_length=64)
    paymentKey: str = Field(min_length=1, max_length=300)
    amount: int = Field(gt=0, strict=True)


class BillingInput(Input):
    orderId: str = Field(max_length=64)
    authKey: str = Field(min_length=1, max_length=300)
    customerKey: str = Field(max_length=64)


class AppleInput(Input):
    signedTransaction: str = Field(min_length=1, max_length=32000)


class GoogleInput(Input):
    product: str = Field(max_length=64)
    token: str = Field(min_length=1, max_length=4096)


class SocialStartInput(Input):
    provider: str = Field(pattern=r"^(google|apple)$")
    challenge: str = Field(pattern=r"^[A-Za-z0-9_-]{43}$")
    client: str = Field(pattern=r"^(apple|android|web)$")


class SocialCompleteInput(Input):
    id: str = Field(max_length=64)
    verifier: str = Field(pattern=r"^[A-Za-z0-9._~-]{43,128}$")


class BodyLimit:
    """Bound chunked bodies as well as requests with Content-Length."""
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        chunks, size = [], 0
        while True:
            event = await receive()
            if event["type"] == "http.disconnect":
                return
            size += len(event.get("body", b""))
            if size > (1048576 if scope.get("path") == "/v1/nas/sync" else 65536):
                return await JSONResponse({"message": "요청이 너무 큽니다."}, status_code=413)(scope, receive, send)
            chunks.append(event.get("body", b""))
            if not event.get("more_body", False):
                break
        consumed = False
        async def bounded_receive():
            nonlocal consumed
            if not consumed:
                consumed = True
                return {"type": "http.request", "body": b"".join(chunks), "more_body": False}
            return await receive()
        await self.app(scope, bounded_receive, send)


def create_app(config=None, *, mailer=None, providers=None, clock=None):
    service = Service(config or Config.from_env(), mailer, providers, **({"clock": clock} if clock else {}))
    app = FastAPI(title="Smooth Player Accounts", docs_url=None, redoc_url=None)
    app.state.service = service

    def token(request):
        value = request.headers.get("authorization", "")
        if not value.startswith("Bearer ") or len(value) > 512:
            raise Failure(401, "로그인이 필요합니다.")
        return value[7:]

    def user(request):
        return service.user(token(request))

    @app.middleware("http")
    async def headers(request, call_next):
        apple_callback = (request.method == "POST" and request.url.path == "/v1/auth/social/callback/apple"
                          and request.headers.get("origin") == "https://appleid.apple.com")
        if request.headers.get("origin") not in (None, service.c.origin) and not apple_callback:
            return JSONResponse({"message": "허용되지 않은 요청입니다."}, status_code=403)
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self' https://js.tosspayments.com; style-src 'self' 'unsafe-inline'; frame-src https://*.tosspayments.com https://*.toss.im; connect-src 'self' https://*.tosspayments.com https://*.toss.im; img-src 'self' data: https:; base-uri 'none'; object-src 'none'; form-action 'self' https://*.tosspayments.com"
        if service.c.environment == "production":
            response.headers["Strict-Transport-Security"] = "max-age=31536000"
        return response

    @app.exception_handler(Failure)
    async def failure(_, error):
        return JSONResponse({"message": error.message}, status_code=error.status)

    @app.exception_handler(InvalidPurchase)
    async def invalid(_, error):
        return JSONResponse({"message": "구매 내역을 확인하지 못했습니다. 결제 상태를 확인해 주세요."}, status_code=400)

    @app.exception_handler(ProviderUnavailable)
    async def unavailable(_, error):
        return JSONResponse({"message": "결제 서비스에 연결하지 못했습니다. 잠시 후 다시 확인해 주세요."}, status_code=503)

    @app.get("/health")
    def health():
        return {"status": "ok", "environment": service.c.environment}

    @app.get("/v1/auth/providers")
    def login_providers(request: Request):
        return service.social.configuration(user(request) if request.headers.get("authorization") else None)

    @app.get("/v1/admin/overview")
    def admin_overview(request: Request):
        from .admin import overview
        return overview(service, user(request))

    @app.post("/v1/auth/social/start")
    def social_start(body: SocialStartInput, request: Request):
        owner = user(request) if request.headers.get("authorization") else None
        return service.social.start(body.provider, body.challenge, body.client, owner,
                                    token(request) if owner else "", request.client.host)

    @app.get("/v1/auth/social/browser/{identifier}")
    def social_browser(identifier: str):
        location, cookie = service.social.browser(identifier)
        response = RedirectResponse(location, status_code=303)
        response.set_cookie(service.social.cookie_name(identifier), cookie, max_age=600, httponly=True,
                            secure=service.c.environment == "production", samesite="none" if service.c.environment == "production" else "lax",
                            path="/v1/auth/social/callback/")
        return response

    @app.api_route("/v1/auth/social/callback/{provider}", methods=["GET", "POST"])
    async def social_callback(provider: str, request: Request):
        from starlette.concurrency import run_in_threadpool
        if provider == "apple" and request.method == "POST":
            if request.headers.get("content-type", "").split(";")[0] != "application/x-www-form-urlencoded":
                raise Failure(400, "로그인 응답 형식을 확인해 주세요.")
            try:
                pairs = parse_qsl((await request.body()).decode("utf-8"), max_num_fields=16)
            except (ValueError, UnicodeError):
                raise Failure(400, "로그인 응답을 확인해 주세요.")
        elif provider == "google" and request.method == "GET":
            pairs = list(request.query_params.multi_items())
        else:
            raise Failure(400, "지원하지 않는 로그인 응답입니다.")
        if len(pairs) > 16 or len(dict(pairs)) != len(pairs):
            raise Failure(400, "로그인 응답을 확인해 주세요.")
        identifier, client = await run_in_threadpool(service.social.callback, provider, dict(pairs), request.cookies)
        if client == "web":
            response = RedirectResponse("/?social=complete", status_code=303)
        elif client == "apple":
            response = RedirectResponse("smoothplayer-auth://complete?attempt=" + identifier, status_code=303)
        else:
            # Explicit browser gesture returns Android to the original task. No
            # session/code/verifier is included; the app redeems its private verifier.
            response = HTMLResponse('<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Smooth Player 로그인</title><link rel="stylesheet" href="/style.css"><main><h1>인증 응답을 받았습니다</h1><p>앱으로 돌아가 로그인 결과를 확인해 주세요.</p><a href="smoothplayer-auth://complete?attempt=' + identifier + '">Smooth Player로 돌아가기</a></main></html>')
        response.delete_cookie(service.social.cookie_name(identifier), path="/v1/auth/social/callback/",
                               secure=service.c.environment == "production", httponly=True,
                               samesite="none" if service.c.environment == "production" else "lax")
        return response

    @app.post("/v1/auth/social/complete")
    def social_complete(body: SocialCompleteInput, request: Request):
        return service.social.complete(body.id, body.verifier, request.client.host)

    @app.post("/v1/nas/sync")
    async def nas_sync(request: Request):
        from .nas_sync import synchronize
        from starlette.concurrency import run_in_threadpool
        owner = await run_in_threadpool(user, request)
        try:
            body = await request.json()
        except (ValueError, UnicodeError):
            raise Failure(400, "NAS 동기화 데이터를 읽지 못했습니다.")
        return await run_in_threadpool(synchronize, service, owner, body)

    @app.get("/privacy.html", response_class=HTMLResponse, include_in_schema=False)
    @app.get("/privacy", response_class=HTMLResponse)
    def privacy(lang: str = "ko"):
        from .legal import page
        return page(service.c, "privacy", lang)

    @app.get("/terms", response_class=HTMLResponse)
    def terms(lang: str = "ko"):
        from .legal import page
        return page(service.c, "terms", lang)

    @app.get("/support", response_class=HTMLResponse)
    def support(lang: str = "ko"):
        from .legal import page
        return page(service.c, "support", lang)

    @app.get("/v1/internal/reconcile")
    def reconcile(request: Request):
        secret = service.c.cron_secret
        if len(secret) < 32 or not hmac.compare_digest(request.headers.get("authorization", ""), "Bearer " + secret):
            raise Failure(401, "인증이 필요합니다.")
        failures = service.reconcile()
        failures += service.social.revoke_pending(time.monotonic() + 30)
        return JSONResponse({"ok": failures == 0, "providerFailures": failures}, status_code=503 if failures else 200)

    @app.get("/v1/catalog")
    def catalog():
        return service.catalog()

    @app.post("/v1/auth/code")
    def request_code(body: EmailInput, request: Request):
        return service.request_code(body.email, request.client.host)

    @app.post("/v1/auth/verify")
    def verify(body: CodeInput, request: Request):
        return service.verify_code(body.challengeId, body.code, request.client.host)

    @app.post("/v1/auth/logout")
    def logout(request: Request):
        service.logout(token(request))
        return {"ok": True}

    @app.delete("/v1/account")
    def delete_account(request: Request):
        service.delete_user(user(request))
        return {"ok": True, "message": "계정을 삭제했습니다. Apple·Google 구독은 해당 스토어에서 별도로 해지해 주세요."}

    @app.get("/v1/me")
    def me(request: Request):
        return service.entitlement(user(request))

    @app.post("/v1/complimentary/redeem")
    def redeem(body: ComplimentaryInput, request: Request):
        return service.redeem_complimentary(user(request), body.code, request.client.host)

    @app.post("/v1/purchases/apple")
    def apple(body: AppleInput, request: Request):
        return service.claim(user(request), "apple", body.model_dump())

    @app.post("/v1/purchases/google")
    def google(body: GoogleInput, request: Request):
        return service.claim(user(request), "google", body.model_dump())

    @app.post("/v1/orders")
    def order(body: ProductInput, request: Request):
        return service.create_order(user(request), body.product, body.amount, body.termsVersion)

    @app.post("/v1/paypal/orders")
    def paypal_order(body: PayPalProductInput, request: Request):
        return service.paypal.create(user(request), body.product, body.amount, body.termsVersion, body.language)

    @app.post("/v1/paypal/orders/{identifier}/capture")
    def paypal_capture(identifier: str, request: Request):
        return service.paypal.capture(user(request), identifier)

    @app.post("/v1/paypal/orders/{identifier}/refund")
    def paypal_refund(identifier: str, request: Request):
        return service.paypal.refund(user(request), identifier)

    @app.get("/v1/paypal/orders")
    def paypal_history(request: Request):
        rows = service.db.all("SELECT id,product,amount,currency,status,created,expires FROM paypal_orders WHERE user_id=? ORDER BY created DESC LIMIT 20", (user(request)["id"],))
        return {"orders": [dict(row) for row in rows]}

    @app.post("/v1/paypal/webhook")
    async def paypal_hook(request: Request):
        from starlette.concurrency import run_in_threadpool
        try:
            event = await request.json()
        except ValueError:
            raise Failure(400, "Invalid webhook")
        return await run_in_threadpool(service.paypal.webhook, request.headers, event)

    @app.post("/v1/payments/confirm")
    def confirm(body: ConfirmInput, request: Request):
        return service.confirm(user(request), body.orderId, body.paymentKey, body.amount)

    @app.post("/v1/billing/confirm")
    def billing(body: BillingInput, request: Request):
        return service.confirm_billing(user(request), body.orderId, body.authKey, body.customerKey)

    @app.get("/v1/subscriptions")
    def subscriptions(request: Request):
        return {"subscriptions": [dict(row) for row in service.db.all('SELECT s.id,s.next_due AS "nextDue",s.cancelled,s.amount,COALESCE(p.product,\'smooth_monthly\') AS product FROM subscriptions s LEFT JOIN billing_products p ON p.id=s.id WHERE s.user_id=?', (user(request)["id"],))]}

    @app.post("/v1/subscriptions/{identifier}/cancel")
    def cancel(identifier: str, request: Request):
        service.cancel_subscription(user(request), identifier)
        return {"ok": True}

    @app.post("/v1/hooks/{provider}/{secret}")
    def hook(provider: str, secret: str, request: Request):
        # Treat the notification only as a wake-up signal. Never trust its purchase state.
        if provider not in ("toss", "apple", "google") or not service.c.webhook_token or not hmac.compare_digest(secret, service.c.webhook_token):
            raise Failure(404, "찾을 수 없습니다.")
        service.rate("hook:" + provider, 30, 60)
        # Invalidate freshness, then scheduled reconcile obtains authoritative provider state.
        with service.db.transaction() as db:
            db.execute("UPDATE purchases SET checked=MIN(checked,?) WHERE provider=?", (service.now() - 301, provider))
        return {"ok": True}

    app.mount("/", StaticFiles(directory=Path(__file__).parent.parent / "web", html=True), name="web")
    app.add_middleware(BodyLimit)
    return app
