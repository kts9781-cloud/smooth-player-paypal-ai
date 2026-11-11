"""Authenticated, read-only operating statistics; no payment/provider secrets leave here."""
from datetime import datetime, timedelta, timezone

from .providers import LIFETIME, MONTHLY, YEARLY
from .service import Failure


def overview(service, user):
    if not service.is_admin(user):
        raise Failure(403, "관리자 계정만 현황을 확인할 수 있습니다.")
    service.rate("admin-overview:" + user["id"], 120, 600)
    now = service.now()
    kst = timezone(timedelta(hours=9))
    today = int(datetime.fromtimestamp(now, kst).replace(hour=0, minute=0, second=0, microsecond=0).timestamp())
    db = service.db.connect()
    try:
        def one(sql, args=()):
            return db.execute(sql, args).fetchone()

        members = one("""SELECT COUNT(*) AS total,
            COALESCE(SUM(CASE WHEN created>=? THEN 1 ELSE 0 END),0) AS today,
            COALESCE(SUM(CASE WHEN created>=? THEN 1 ELSE 0 END),0) AS week
            FROM users WHERE deleted=0""", (today, now - 7 * 86400))
        free = one("SELECT COUNT(*) FROM complimentary_grants g JOIN users u ON u.id=g.user_id WHERE u.deleted=0")[0]
        active = "u.deleted=0 AND p.active=1 AND (p.expires IS NULL OR p.expires>?) AND p.checked>?"
        args = (now, now - service.c.offline_seconds)
        purchases = one("""SELECT COUNT(DISTINCT p.user_id) AS members,
            COALESCE(SUM(CASE WHEN p.product=? THEN 1 ELSE 0 END),0) AS monthly,
            COALESCE(SUM(CASE WHEN p.product=? THEN 1 ELSE 0 END),0) AS yearly,
            COUNT(DISTINCT CASE WHEN p.product=? THEN p.user_id END) AS lifetime
            FROM purchases p JOIN users u ON u.id=p.user_id WHERE """ + active, (MONTHLY, YEARLY, LIFETIME, *args))
        stale = one("""SELECT COUNT(*) FROM purchases p JOIN users u ON u.id=p.user_id
            WHERE u.deleted=0 AND p.active=1 AND (p.expires IS NULL OR p.expires>?) AND p.checked<=?""", args)[0]
        payments = one("""SELECT
            COALESCE(SUM(CASE WHEN status='done' THEN 1 ELSE 0 END),0) AS completed,
            COALESCE(SUM(CASE WHEN status='done' THEN amount ELSE 0 END),0) AS amount,
            COALESCE(SUM(CASE WHEN status='cancelled' THEN 1 ELSE 0 END),0) AS cancelled,
            COALESCE(SUM(CASE WHEN status NOT IN ('done','cancelled') THEN 1 ELSE 0 END),0) AS pending
            FROM orders""")
        renewals = one("""SELECT
            COALESCE(SUM(CASE WHEN s.cancelled=0 AND s.next_due>? THEN 1 ELSE 0 END),0) AS scheduled,
            COALESCE(SUM(CASE WHEN s.cancelled=0 AND s.next_due<=? THEN 1 ELSE 0 END),0) AS due,
            COALESCE(SUM(CASE WHEN s.cancelled=1 THEN 1 ELSE 0 END),0) AS stopped
            FROM subscriptions s JOIN users u ON u.id=s.user_id WHERE u.deleted=0""", (now, now))
        orders = db.execute("""SELECT o.id,o.product,o.amount,o.status,o.created,u.email,u.deleted
            FROM orders o JOIN users u ON u.id=o.user_id ORDER BY o.created DESC,o.id DESC LIMIT 20""").fetchall()
        subscriptions = db.execute("""SELECT p.provider,p.reference,p.product,p.active,p.expires,p.checked,u.email,u.deleted
            FROM purchases p JOIN users u ON u.id=p.user_id WHERE p.product IN (?,?,?)
            ORDER BY p.checked DESC,p.provider,p.reference LIMIT 20""", (MONTHLY, YEARLY, LIFETIME)).fetchall()
    finally:
        db.close()

    def metric(identifier, title, value, format="count"):
        return {"id": identifier, "title": title, "value": int(value), "format": format}

    def masked(row):
        if row["deleted"]:
            return "탈퇴 회원"
        name, domain = row["email"].split("@", 1)
        return name[:1] + "***@" + domain

    def status(row):
        if row["deleted"] or not row["active"]:
            return "종료·해제"
        if row["expires"] is not None and row["expires"] <= now:
            return "기간 만료"
        if row["checked"] <= now - service.c.offline_seconds:
            return "재확인 필요"
        return "이용 중"

    # Purchase reference tokens, proof, billing keys and account sessions are never returned.
    return {
        "generatedAt": now, "timezone": "Asia/Seoul",
        "sections": [
            {"id": "members", "title": "가입자", "metrics": [
                metric("members", "전체 가입자", members["total"]), metric("today", "오늘 가입", members["today"]),
                metric("week", "최근 7일 가입", members["week"]), metric("free", "무료 이용권 회원", free),
                metric("administrators", "관리자 무료 회원", 1)]},
            {"id": "subscriptions", "title": "이용권·구독", "metrics": [
                metric("paidMembers", "유료 이용권 회원", purchases["members"]),
                metric("monthly", "유효 월 구독", purchases["monthly"]), metric("yearly", "유효 연 구독", purchases["yearly"]),
                metric("lifetime", "유료 평생 이용권 회원", purchases["lifetime"]), metric("unconfirmed", "구매 재확인 필요", stale)]},
            {"id": "payments", "title": "토스 결제", "metrics": [
                metric("completed", "결제 완료", payments["completed"]), metric("amount", "완료 결제 금액", payments["amount"], "krw"),
                metric("cancelled", "취소·중단", payments["cancelled"]), metric("pending", "미완료 주문", payments["pending"])]},
            {"id": "renewals", "title": "토스 자동 갱신", "metrics": [
                metric("scheduled", "다음 갱신 예정", renewals["scheduled"]), metric("due", "갱신 처리 대기", renewals["due"]),
                metric("stopped", "자동 갱신 해지", renewals["stopped"])]},
        ],
        "recentOrders": [{"id": r["id"], "member": masked(r), "product": r["product"], "amount": r["amount"],
                          "status": {"done": "결제 완료", "cancelled": "취소·중단"}.get(r["status"], "미완료"), "createdAt": r["created"]} for r in orders],
        "recentSubscriptions": [{"id": str(i), "member": masked(r), "provider": r["provider"], "product": r["product"],
                                 "status": status(r), "expiresAt": r["expires"], "checkedAt": r["checked"]} for i, r in enumerate(subscriptions)],
        "notice": "가입자는 탈퇴 회원을 제외합니다. 구독은 계정에 연결된 구매의 최근 확인 결과이며, 관리자 무료 이용은 유료 집계에서 제외됩니다. 결제 금액은 현재 완료 상태인 토스 주문 합계로 정산액이 아닙니다. App Store·Google Play 매출과 계정에 연결하지 않은 구매는 각 스토어 콘솔에서 확인하세요.",
    }
