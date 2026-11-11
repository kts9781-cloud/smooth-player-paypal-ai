"""Account-scoped NAS metadata. Never connects to a NAS or accepts local URLs."""
import json
import hashlib
import math
import re
import uuid
from urllib.parse import urlsplit, unquote

from .service import Failure

LIMIT = 524288


def valid(condition):
    if not condition:
        raise Failure(400, "NAS 동기화 데이터 형식을 확인해 주세요.")


def text(value, maximum=4096):
    valid(isinstance(value, str))
    try:
        valid(len(value.encode("utf-8")) <= maximum and not any(c in value for c in "\x00\r\n"))
    except UnicodeError:
        valid(False)
    return value


def identifier(value):
    valid(isinstance(value, str))
    try:
        valid(str(uuid.UUID(value)) == value)
    except (ValueError, AttributeError):
        valid(False)


def path(value, wire=False):
    text(value, 24576 if wire else 8192)
    valid(value.startswith("/") and not value.startswith("//") and "\\" not in value and "://" not in value)
    check = unquote(value) if wire else value
    valid(not any(p in (".", "..") for p in check.split("/")) and not any(c in check for c in "\x00\r\n\\") and not check.startswith("//"))
    if wire:
        valid(all(0x21 <= ord(c) < 0x7f for c in value) and not re.search(r"%(?![0-9a-fA-F]{2})", value))


def number(value, maximum=1e13):
    valid(type(value) in (int, float) and math.isfinite(value) and 0 <= value <= maximum)


def validate_value(key, value):
    valid(isinstance(key, str) and re.fullmatch(r"(server|recent|hidden|youtube):[0-9a-f-]{36}", key))
    identifier(key.split(":", 1)[1])
    if value is None:
        return
    valid(isinstance(value, dict) and value.get("kind") == key.split(":", 1)[0])
    kind = value["kind"]
    if kind == "server":
        valid(set(value) == {"kind", "name", "protocol", "host", "port", "share", "rootPath", "username", "password", "domain", "ftpEncoding"})
        valid(value["protocol"] in ("ftp", "smb"))
        host = text(value["host"], 253)
        valid(host and not any(c.isspace() or c in "/@?#[]" for c in host))
        valid(type(value["port"]) is int and 1 <= value["port"] <= 65535)
        for field in ("name", "username", "domain", "share"):
            text(value[field], 512)
        text(value["password"])
        valid("/" not in value["share"] and "\\" not in value["share"])
        valid(value["ftpEncoding"] in ("automatic", "utf8", "cp949", "eucKR"))
        path(value["rootPath"])
    elif kind == "recent":
        value.setdefault("encodedPath", None)
        value.setdefault("modifiedAt", None)
        valid(set(value) == {"kind", "connectionID", "path", "encodedPath", "name", "position", "duration", "fileSize", "modifiedAt", "openedAt"})
        identifier(value["connectionID"])
        path(value["path"])
        if value["encodedPath"] is not None:
            path(value["encodedPath"], wire=True)
        text(value["name"])
        valid(value["name"] and value["name"] == value["path"].split("/")[-1])
        for field in ("position", "duration", "openedAt"):
            number(value[field])
        valid(value["position"] <= value["duration"])
        valid(type(value["fileSize"]) is int and 0 <= value["fileSize"] <= 2**53 - 1)
        if value["modifiedAt"] is not None:
            number(value["modifiedAt"])
    elif kind == "youtube":
        valid(set(value) == {"kind", "videoID", "title", "position", "duration", "openedAt"})
        video_id = text(value["videoID"], 11)
        valid(re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id))
        expected = str(uuid.UUID(bytes=hashlib.sha256(video_id.encode()).digest()[:16]))
        valid(key == "youtube:" + expected)
        text(value["title"])
        for field in ("position", "duration", "openedAt"):
            number(value[field])
        valid(0 < value["duration"] and value["position"] <= value["duration"])
    else:
        valid(set(value) == {"kind", "scope", "path", "name"})
        scope = text(value["scope"], 512)
        try:
            url = urlsplit(scope)
            valid(url.scheme in ("smb", "ftp") and url.hostname and url.port and not url.username and not url.password and not url.path and not url.query and not url.fragment)
        except ValueError:
            valid(False)
        path(value["path"])
        text(value["name"])


def synchronize(service, user, body):
    valid(isinstance(body, dict) and {"schema", "changes"} <= set(body) <= {"schema", "changes", "includeYouTube"}
          and type(body["schema"]) is int and body["schema"] == 1)
    include_youtube = body.get("includeYouTube", False)
    valid(type(include_youtube) is bool)
    changes = body["changes"]
    valid(isinstance(changes, list) and len(changes) <= 1000)
    seen = set()
    for change in changes:
        valid(isinstance(change, dict) and set(change) == {"id", "baseVersion", "value"})
        validate_value(change["id"], change["value"])
        valid(include_youtube or not change["id"].startswith("youtube:"))
        valid(change["id"] not in seen)
        seen.add(change["id"])
        valid(type(change["baseVersion"]) is int and 0 <= change["baseVersion"] <= 2**53 - 1)
    service.rate("nas:" + user["id"], 120, 60)
    with service.db.transaction() as db:
        # A concurrent account deletion must not leave credentials behind.
        valid(db.execute("SELECT 1 FROM users WHERE id=? AND deleted=0", (user["id"],)).fetchone())
        row = db.execute("SELECT state FROM nas_sync WHERE user_id=?", (user["id"],)).fetchone()
        state = json.loads(service.secrets.decrypt(row[0])) if row else {"owner": user["id"], "records": {}}
        valid(state["owner"] == user["id"])
        records = state["records"]
        conflicts = []
        for change in changes:
            key, value = change["id"], change["value"]
            old = records.get(key)
            version = old["version"] if old else 0
            if old and old["value"] == value:
                continue  # Retry after a lost response: no new version.
            if change["baseVersion"] != version:
                # A later watch checkpoint wins, including completion/rewind=0.
                # A tombstone still requires its exact version: stale devices cannot resurrect it.
                newer_watch = (key.startswith("youtube:") and value and old and old["value"]
                               and value["openedAt"] > old["value"]["openedAt"])
                if not newer_watch:
                    conflicts.append(key)
                    continue
            records[key] = {"id": key, "version": version + 1, "value": value}
        # Deleting a connection cannot leave playable history referencing it.
        for record in list(records.values()):
            value = record["value"]
            if value and value["kind"] == "recent":
                server = records.get("server:" + value["connectionID"])
                valid(server is not None)
                if server["value"] is None:
                    record.update(version=record["version"] + 1, value=None)
        recent = sorted((r for r in records.values() if r["value"] and r["value"]["kind"] == "recent"),
                        key=lambda r: (r["value"]["openedAt"], r["id"]), reverse=True)
        for record in recent[500:]:
            record.update(version=record["version"] + 1, value=None)
        youtube = sorted((r for r in records.values() if r["value"] and r["value"]["kind"] == "youtube"),
                         key=lambda r: (r["value"]["openedAt"], r["id"]), reverse=True)
        for record in youtube[100:]:
            record.update(version=record["version"] + 1, value=None)
        valid(len(records) <= 3000)
        valid(sum(r["value"] is not None and r["id"].startswith("server:") for r in records.values()) <= 128)
        encoded = json.dumps(state, separators=(",", ":"), ensure_ascii=False)
        if len(encoded.encode()) > LIMIT:
            raise Failure(413, "NAS 동기화 저장 한도를 넘었습니다. 최근 목록을 정리해 주세요.")
        if changes:
            db.execute("INSERT INTO nas_sync VALUES(?,?,?) ON CONFLICT(user_id) DO UPDATE SET state=excluded.state,updated=excluded.updated",
                       (user["id"], service.secrets.encrypt(encoded), service.now()))
        # Old iOS clients reject unknown kinds; old Android clients could delete them.
        # Opt-in clients alone receive or modify YouTube records (including tombstones).
        visible = [r for r in records.values() if include_youtube or not r["id"].startswith("youtube:")]
        return {"schema": 1, "userId": user["id"], "records": visible, "conflicts": conflicts}
