#!/usr/bin/env bash
# 배포한 API를 호출해 기본 동작을 확인한다: ./infra/smoke-test.sh [API 주소]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
API_URL="${1:-$(cat "$ROOT_DIR/.api-endpoint")}"

pretty() { python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), ensure_ascii=False, indent=2))'; }

echo "### GET $API_URL/health"
curl -sS -w '\n' "$API_URL/health" | pretty

echo "### POST $API_URL/chat"
curl -sS -w '\n' -X POST "$API_URL/chat" -H 'Content-Type: application/json' \
  -d '{"sessionId":"smoke-test","question":"졸업하려면 몇 학점을 들어야 하나요?"}' | pretty

echo "### POST $API_URL/chat (빈 질문 -> 400 이어야 함)"
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' -X POST "$API_URL/chat" \
  -H 'Content-Type: application/json' -d '{"question":""}'
