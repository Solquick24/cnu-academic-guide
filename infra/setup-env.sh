#!/usr/bin/env bash
# 2주차: 저장소(S3, DynamoDB)와 Lambda 실행 역할(IAM)을 만든다.
# CloudShell(ap-northeast-2)에서 저장소 루트 기준으로 실행한다: ./infra/setup-env.sh
# 이미 있는 리소스는 건너뛰므로 여러 번 실행해도 된다.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/config.env"
export AWS_DEFAULT_REGION="$REGION"

echo "== 계정 $ACCOUNT_ID / 리전 $REGION"

# 1) S3 문서 버킷: 퍼블릭 차단, 기본 암호화, 버전 관리
if aws s3api head-bucket --bucket "$DOCS_BUCKET" 2>/dev/null; then
  echo "[S3] $DOCS_BUCKET 이미 있음"
else
  aws s3api create-bucket --bucket "$DOCS_BUCKET" \
    --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  echo "[S3] $DOCS_BUCKET 생성"
fi
aws s3api put-public-access-block --bucket "$DOCS_BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$DOCS_BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
aws s3api put-bucket-versioning --bucket "$DOCS_BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-tagging --bucket "$DOCS_BUCKET" --tagging \
  "TagSet=[{Key=Project,Value=$PROJECT_TAG},{Key=Week,Value=$WEEK_TAG}]"
aws s3 cp "$ROOT_DIR/docs/sample/" "s3://$DOCS_BUCKET/raw/sample/" --recursive --exclude "*" --include "*.md" \
  --content-type "text/markdown; charset=utf-8" --only-show-errors
echo "[S3] 퍼블릭 차단, SSE-S3, 버전 관리, 샘플 문서 업로드 완료"

# 2) DynamoDB 대화 로그 테이블: 온디맨드, TTL(expiresAt)
if aws dynamodb describe-table --table-name "$CHAT_TABLE" >/dev/null 2>&1; then
  echo "[DynamoDB] $CHAT_TABLE 이미 있음"
else
  aws dynamodb create-table --table-name "$CHAT_TABLE" \
    --attribute-definitions AttributeName=sessionId,AttributeType=S AttributeName=createdAt,AttributeType=S \
    --key-schema AttributeName=sessionId,KeyType=HASH AttributeName=createdAt,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --tags Key=Project,Value="$PROJECT_TAG" Key=Week,Value="$WEEK_TAG" >/dev/null
  aws dynamodb wait table-exists --table-name "$CHAT_TABLE"
  echo "[DynamoDB] $CHAT_TABLE 생성"
fi
TTL_STATUS=$(aws dynamodb describe-time-to-live --table-name "$CHAT_TABLE" \
  --query 'TimeToLiveDescription.TimeToLiveStatus' --output text)
if [ "$TTL_STATUS" = "DISABLED" ]; then
  aws dynamodb update-time-to-live --table-name "$CHAT_TABLE" \
    --time-to-live-specification Enabled=true,AttributeName=expiresAt >/dev/null
fi
echo "[DynamoDB] TTL(expiresAt) 설정 확인"

# 3) Lambda 실행 역할: 필요한 리소스에만 권한을 준다(최소 권한)
if aws iam get-role --role-name "$LAMBDA_ROLE" >/dev/null 2>&1; then
  echo "[IAM] $LAMBDA_ROLE 이미 있음"
else
  aws iam create-role --role-name "$LAMBDA_ROLE" \
    --assume-role-policy-document "file://$SCRIPT_DIR/policies/lambda-trust.json" \
    --description "CNU academic guide chat API Lambda role" \
    --tags Key=Project,Value="$PROJECT_TAG" Key=Week,Value="$WEEK_TAG" >/dev/null
  echo "[IAM] $LAMBDA_ROLE 생성"
fi
POLICY_DOC=$(sed -e "s/__DOCS_BUCKET__/$DOCS_BUCKET/g" -e "s/__REGION__/$REGION/g" \
  -e "s/__ACCOUNT_ID__/$ACCOUNT_ID/g" -e "s/__CHAT_TABLE__/$CHAT_TABLE/g" \
  -e "s/__LAMBDA_NAME__/$LAMBDA_NAME/g" "$SCRIPT_DIR/policies/chat-api-access.json")
aws iam put-role-policy --role-name "$LAMBDA_ROLE" --policy-name CnuGuide-ChatApiAccess \
  --policy-document "$POLICY_DOC"
echo "[IAM] 인라인 정책 CnuGuide-ChatApiAccess 적용"

# 4) Lambda 로그 그룹을 미리 만들어 보존 기간을 정한다
LOG_GROUP="/aws/lambda/$LAMBDA_NAME"
if ! aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
    --query "logGroups[?logGroupName=='$LOG_GROUP'] | length(@)" --output text | grep -q '^1$'; then
  aws logs create-log-group --log-group-name "$LOG_GROUP" --tags Project="$PROJECT_TAG",Week="$WEEK_TAG"
fi
aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days "$LOG_RETENTION_DAYS"
echo "[Logs] $LOG_GROUP 보존 ${LOG_RETENTION_DAYS}일"

echo "== setup-env 완료. 다음: ./infra/deploy-api.sh"
