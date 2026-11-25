"""lambda_function 단위 테스트 (AWS에 접속하지 않고 S3, DynamoDB 호출을 가짜 객체로 바꾼다)

실행: python -m pytest -q
"""
import importlib
import json
import os
import sys
from unittest import mock

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "backend", "chat_api"))

os.environ.setdefault("AWS_DEFAULT_REGION", "ap-northeast-2")
os.environ.setdefault("DOCS_BUCKET", "test-docs-bucket")
os.environ.setdefault("CHAT_TABLE", "test-chat-table")


@pytest.fixture()
def fn():
    module = importlib.import_module("lambda_function")
    module.s3 = mock.Mock()
    module.table = mock.Mock()
    module.s3.list_objects_v2.return_value = {
        "KeyCount": 1,
        "Contents": [{"Key": "raw/sample/test-guide.md"}],
    }
    return module


def call(fn, route, body=None):
    event = {"routeKey": route}
    if body is not None:
        event["body"] = body if isinstance(body, str) else json.dumps(body)
    resp = fn.lambda_handler(event, None)
    return resp["statusCode"], json.loads(resp["body"])


def test_health_ok(fn):
    status, body = call(fn, "GET /health")
    assert status == 200
    assert body["status"] == "ok"
    assert body["checks"]["s3_docs_bucket"]["objectCount"] == 1
    fn.table.put_item.assert_called_once()


def test_health_reports_failure(fn):
    fn.s3.list_objects_v2.side_effect = PermissionError("denied")
    status, body = call(fn, "GET /health")
    assert status == 503
    assert body["status"] == "degraded"
    assert body["checks"]["s3_docs_bucket"] == {"ok": False, "error": "PermissionError"}


def test_chat_saves_log(fn):
    status, body = call(fn, "POST /chat", {"question": "졸업 요건 알려줘", "sessionId": "s-1"})
    assert status == 200
    assert body["sessionId"] == "s-1"
    item = fn.table.put_item.call_args.kwargs["Item"]
    assert item["sessionId"] == "s-1"
    assert item["question"] == "졸업 요건 알려줘"
    assert item["expiresAt"] > 0


@pytest.mark.parametrize(
    "body",
    ["{not json", json.dumps(["list"]), json.dumps({"question": "   "}), json.dumps({"question": "가" * 501})],
)
def test_chat_rejects_bad_input(fn, body):
    status, _ = call(fn, "POST /chat", body)
    assert status == 400
    fn.table.put_item.assert_not_called()


def test_unknown_route(fn):
    status, _ = call(fn, "DELETE /chat")
    assert status == 404
