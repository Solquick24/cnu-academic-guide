#!/usr/bin/env bash
# 2주차: Chat API Lambda를 배포하고 API Gateway HTTP API(GET /health, POST /chat)에 연결한다.
# setup-env.sh 다음에 실행한다: ./infra/deploy-api.sh
# 코드를 고친 뒤 다시 실행하면 함수 코드만 갱신된다.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/config.env"
export AWS_DEFAULT_REGION="$REGION"

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
cp "$ROOT_DIR/backend/chat_api/lambda_function.py" "$BUILD_DIR/"
(cd "$BUILD_DIR" && zip -q function.zip lambda_function.py)

ROLE_ARN=$(aws iam get-role --role-name "$LAMBDA_ROLE" --query Role.Arn --output text)
GIT_SHA=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo local)
ENV_VARS="Variables={DOCS_BUCKET=$DOCS_BUCKET,CHAT_TABLE=$CHAT_TABLE,LOG_TTL_DAYS=30,APP_VERSION=0.1.0-$GIT_SHA}"

# 1) Lambda 함수
if aws lambda get-function --function-name "$LAMBDA_NAME" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$LAMBDA_NAME" \
    --zip-file "fileb://$BUILD_DIR/function.zip" >/dev/null
  aws lambda wait function-updated-v2 --function-name "$LAMBDA_NAME"
  aws lambda update-function-configuration --function-name "$LAMBDA_NAME" \
    --environment "$ENV_VARS" >/dev/null
  aws lambda wait function-updated-v2 --function-name "$LAMBDA_NAME"
  echo "[Lambda] $LAMBDA_NAME 코드 갱신 (version 0.1.0-$GIT_SHA)"
else
  # 방금 만든 IAM 역할은 전파에 몇 초 걸리므로 실패하면 다시 시도한다
  for i in 1 2 3 4 5 6; do
    if aws lambda create-function --function-name "$LAMBDA_NAME" \
        --runtime python3.12 --architectures arm64 \
        --handler lambda_function.lambda_handler --role "$ROLE_ARN" \
        --zip-file "fileb://$BUILD_DIR/function.zip" \
        --timeout 10 --memory-size 128 --environment "$ENV_VARS" \
        --tags Project="$PROJECT_TAG",Week="$WEEK_TAG" >/dev/null 2>"$BUILD_DIR/err"; then
      break
    fi
    if [ "$i" -eq 6 ]; then cat "$BUILD_DIR/err"; exit 1; fi
    echo "[Lambda] IAM 역할 전파 대기 중... ($i/6)"; sleep 10
  done
  aws lambda wait function-active-v2 --function-name "$LAMBDA_NAME"
  echo "[Lambda] $LAMBDA_NAME 생성 (Python 3.12, arm64, 128MB, 10초)"
fi
LAMBDA_ARN=$(aws lambda get-function --function-name "$LAMBDA_NAME" --query Configuration.FunctionArn --output text)

# 2) HTTP API
API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='$API_NAME'].ApiId | [0]" --output text)
if [ -z "$API_ID" ] || [ "$API_ID" = "None" ]; then
  API_ID=$(aws apigatewayv2 create-api --name "$API_NAME" --protocol-type HTTP \
    --cors-configuration '{"AllowOrigins":["*"],"AllowMethods":["GET","POST","OPTIONS"],"AllowHeaders":["content-type"],"MaxAge":300}' \
    --tags Project="$PROJECT_TAG",Week="$WEEK_TAG" --query ApiId --output text)
  echo "[API] $API_NAME 생성 ($API_ID)"
else
  echo "[API] $API_NAME 이미 있음 ($API_ID)"
fi

INTEG_ID=$(aws apigatewayv2 get-integrations --api-id "$API_ID" \
  --query "Items[?IntegrationUri=='$LAMBDA_ARN'].IntegrationId | [0]" --output text)
if [ -z "$INTEG_ID" ] || [ "$INTEG_ID" = "None" ]; then
  INTEG_ID=$(aws apigatewayv2 create-integration --api-id "$API_ID" \
    --integration-type AWS_PROXY --integration-uri "$LAMBDA_ARN" \
    --payload-format-version 2.0 --timeout-in-millis 10000 --query IntegrationId --output text)
fi

for ROUTE in "GET /health" "POST /chat"; do
  ROUTE_ID=$(aws apigatewayv2 get-routes --api-id "$API_ID" \
    --query "Items[?RouteKey=='$ROUTE'].RouteId | [0]" --output text)
  if [ -z "$ROUTE_ID" ] || [ "$ROUTE_ID" = "None" ]; then
    aws apigatewayv2 create-route --api-id "$API_ID" --route-key "$ROUTE" \
      --target "integrations/$INTEG_ID" >/dev/null
  fi
done

# $default 스테이지: 자동 배포, 요청 폭주를 막기 위한 기본 스로틀
if ! aws apigatewayv2 get-stage --api-id "$API_ID" --stage-name '$default' >/dev/null 2>&1; then
  aws apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' --auto-deploy \
    --default-route-settings ThrottlingBurstLimit=20,ThrottlingRateLimit=10 \
    --tags Project="$PROJECT_TAG",Week="$WEEK_TAG" >/dev/null
fi
echo "[API] 경로 GET /health, POST /chat 연결, \$default 스테이지 자동 배포"

# 3) API Gateway가 이 API에서만 Lambda를 호출할 수 있게 허용
SOURCE_ARN="arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*/*"
if ! OUT=$(aws lambda add-permission --function-name "$LAMBDA_NAME" \
    --statement-id "apigw-$API_ID" --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com --source-arn "$SOURCE_ARN" 2>&1); then
  echo "$OUT" | grep -q ResourceConflictException || { echo "$OUT"; exit 1; }
fi

ENDPOINT=$(aws apigatewayv2 get-api --api-id "$API_ID" --query ApiEndpoint --output text)
echo "$ENDPOINT" > "$ROOT_DIR/.api-endpoint"
echo "== 배포 완료: $ENDPOINT"
echo "   확인: ./infra/smoke-test.sh"
