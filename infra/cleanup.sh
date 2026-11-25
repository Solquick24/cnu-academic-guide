#!/usr/bin/env bash
# 2주차에 만든 리소스를 모두 지운다. 이후 주차에도 쓸 리소스이므로 프로젝트를 접을 때만 실행한다.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/config.env"
export AWS_DEFAULT_REGION="$REGION"

echo "삭제 대상: API $API_NAME, Lambda $LAMBDA_NAME, 로그 그룹, IAM 역할 $LAMBDA_ROLE,"
echo "          DynamoDB $CHAT_TABLE, S3 $DOCS_BUCKET(모든 버전 포함)"
read -r -p "정말 삭제할까요? (y/N) " ANSWER
[ "$ANSWER" = "y" ] || { echo "취소"; exit 0; }

API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='$API_NAME'].ApiId | [0]" --output text)
[ "$API_ID" != "None" ] && [ -n "$API_ID" ] && aws apigatewayv2 delete-api --api-id "$API_ID" && echo "[API] 삭제"

aws lambda delete-function --function-name "$LAMBDA_NAME" 2>/dev/null && echo "[Lambda] 삭제" || true
aws logs delete-log-group --log-group-name "/aws/lambda/$LAMBDA_NAME" 2>/dev/null && echo "[Logs] 삭제" || true

aws iam delete-role-policy --role-name "$LAMBDA_ROLE" --policy-name CnuGuide-ChatApiAccess 2>/dev/null || true
aws iam delete-role --role-name "$LAMBDA_ROLE" 2>/dev/null && echo "[IAM] 삭제" || true

aws dynamodb delete-table --table-name "$CHAT_TABLE" >/dev/null 2>&1 && echo "[DynamoDB] 삭제" || true

if aws s3api head-bucket --bucket "$DOCS_BUCKET" 2>/dev/null; then
  for KIND in Versions DeleteMarkers; do
    OBJS=$(aws s3api list-object-versions --bucket "$DOCS_BUCKET" \
      --query "{Objects: $KIND[].{Key:Key,VersionId:VersionId}}" --output json)
    if [ "$(echo "$OBJS" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["Objects"] or []))')" -gt 0 ]; then
      aws s3api delete-objects --bucket "$DOCS_BUCKET" --delete "$OBJS" >/dev/null
    fi
  done
  aws s3api delete-bucket --bucket "$DOCS_BUCKET" && echo "[S3] 삭제"
fi
rm -f "$ROOT_DIR/.api-endpoint"
echo "== 정리 완료"
