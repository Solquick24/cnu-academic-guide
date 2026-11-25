"""CNU 학사 길잡이 Chat API (2주차 환경 확인용 버전)

HTTP API(payload v2.0)에서 호출하는 Lambda 함수다.

GET  /health : S3 문서 버킷과 DynamoDB 대화 로그 테이블에 실제로 접근해 본다.
POST /chat   : 질문을 받아 대화 로그 테이블에 저장하고 임시 답변을 돌려준다.
               Bedrock 지식 기반 연결(RAG)은 3주차에 붙인다.
"""
import base64
import json
import os
import uuid
from datetime import datetime, timedelta, timezone

import boto3

DOCS_BUCKET = os.environ["DOCS_BUCKET"]
CHAT_TABLE = os.environ["CHAT_TABLE"]
LOG_TTL_DAYS = int(os.environ.get("LOG_TTL_DAYS", "30"))
APP_VERSION = os.environ.get("APP_VERSION", "0.1.0")
MAX_QUESTION_LEN = 500

KST = timezone(timedelta(hours=9))

s3 = boto3.client("s3")
table = boto3.resource("dynamodb").Table(CHAT_TABLE)

TEMP_ANSWER = (
    "아직 학사 문서 지식 기반이 연결되지 않은 테스트 버전입니다. "
    "질문은 대화 로그에 저장했습니다."
)


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json; charset=utf-8"},
        "body": json.dumps(body, ensure_ascii=False),
    }


def _log_item(session_id, kind, question, answer):
    now = datetime.now(KST)
    return {
        "sessionId": session_id,
        # 같은 초에 두 번 저장돼도 겹치지 않도록 짧은 난수를 붙인다.
        "createdAt": f"{now.isoformat(timespec='milliseconds')}#{uuid.uuid4().hex[:6]}",
        "type": kind,
        "question": question,
        "answer": answer,
        "expiresAt": int((now + timedelta(days=LOG_TTL_DAYS)).timestamp()),
    }


def _read_body(event):
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    return json.loads(raw or "{}")


def health(_event):
    checks = {}

    try:
        resp = s3.list_objects_v2(Bucket=DOCS_BUCKET, MaxKeys=20)
        checks["s3_docs_bucket"] = {
            "ok": True,
            "bucket": DOCS_BUCKET,
            "objectCount": resp.get("KeyCount", 0),
            "objects": [o["Key"] for o in resp.get("Contents", [])],
        }
    except Exception as exc:  # 권한 문제 등은 이름만 돌려준다
        checks["s3_docs_bucket"] = {"ok": False, "error": type(exc).__name__}

    try:
        item = _log_item("health-check", "health", "GET /health", "ok")
        table.put_item(Item=item)
        checks["dynamodb_chat_logs"] = {
            "ok": True,
            "table": CHAT_TABLE,
            "writtenKey": {"sessionId": item["sessionId"], "createdAt": item["createdAt"]},
        }
    except Exception as exc:
        checks["dynamodb_chat_logs"] = {"ok": False, "error": type(exc).__name__}

    ok = all(c["ok"] for c in checks.values())
    return _response(
        200 if ok else 503,
        {
            "service": "cnu-academic-guide",
            "version": APP_VERSION,
            "status": "ok" if ok else "degraded",
            "region": os.environ.get("AWS_REGION", ""),
            "time": datetime.now(KST).isoformat(timespec="seconds"),
            "checks": checks,
        },
    )


def chat(event):
    try:
        body = _read_body(event)
    except (ValueError, UnicodeDecodeError):
        return _response(400, {"error": "요청 본문은 JSON 형식이어야 합니다."})
    if not isinstance(body, dict):
        return _response(400, {"error": "요청 본문은 JSON 객체여야 합니다."})

    question = str(body.get("question") or "").strip()
    if not question:
        return _response(400, {"error": "question 값이 비어 있습니다."})
    if len(question) > MAX_QUESTION_LEN:
        return _response(400, {"error": f"질문은 {MAX_QUESTION_LEN}자 이하로 입력해 주세요."})

    session_id = str(body.get("sessionId") or uuid.uuid4())
    item = _log_item(session_id, "chat", question, TEMP_ANSWER)
    table.put_item(Item=item)

    return _response(
        200,
        {
            "sessionId": session_id,
            "question": question,
            "answer": TEMP_ANSWER,
            "sources": [],
            "loggedAt": item["createdAt"],
        },
    )


ROUTES = {
    "GET /health": health,
    "POST /chat": chat,
}


def lambda_handler(event, _context):
    route = event.get("routeKey", "")
    handler = ROUTES.get(route)
    if handler is None:
        return _response(404, {"error": f"지원하지 않는 경로입니다: {route}"})
    return handler(event)
