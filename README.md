# CNU 학사 길잡이 (cnu-academic-guide)

충남대학교 학사, 장학, 졸업요건을 학사 문서 근거와 함께 안내하는 RAG 챗봇 프로젝트다.
클라우드 아키텍처 수업 실습 과제로 진행하며, 주차별로 AWS 환경을 쌓아 간다.

- 1주차: 서비스 기획과 아키텍처 설계 ([docs/architecture.md](docs/architecture.md))
- 2주차: AWS 실행 환경, 저장소, 접근 권한 구성과 테스트 API 배포 (현재)

## 폴더 구조

```
backend/chat_api/lambda_function.py   Chat API Lambda (GET /health, POST /chat)
infra/config.env                      리소스 이름, 리전 설정
infra/setup-env.sh                    S3 문서 버킷, DynamoDB 대화 로그, IAM 실행 역할, 로그 그룹 생성
infra/deploy-api.sh                   Lambda 배포, API Gateway HTTP API 연결
infra/smoke-test.sh                   배포한 API 호출 확인
infra/cleanup.sh                      2주차 리소스 전체 삭제
infra/policies/                       IAM 신뢰 정책, 최소 권한 인라인 정책
docs/sample/                          S3에 올리는 환경 확인용 샘플 문서
tests/                                Lambda 단위 테스트 (AWS 접속 없이 실행)
```

## AWS 리소스 (ap-northeast-2)

| 리소스 | 이름 | 설정 |
| --- | --- | --- |
| S3 | cnu-guide-docs-<계정ID> | 퍼블릭 차단, SSE-S3, 버전 관리, raw/ 아래 문서 |
| DynamoDB | CnuGuide-ChatLogs | PK sessionId, SK createdAt, 온디맨드, TTL expiresAt(30일) |
| IAM 역할 | CnuGuide-ChatApiRole | Lambda 신뢰, 위 버킷 읽기, 테이블 쓰기, 자기 로그 그룹 쓰기만 허용 |
| Lambda | cnu-guide-chat-api | Python 3.12, arm64, 128MB, 10초 |
| API Gateway | cnu-guide-api (HTTP API) | GET /health, POST /chat, CORS, 초당 10건 스로틀 |
| CloudWatch Logs | /aws/lambda/cnu-guide-chat-api | 14일 보존 |

## 배포 방법 (AWS CloudShell)

```bash
git clone https://github.com/Solquick24/cnu-academic-guide.git
cd cnu-academic-guide
chmod +x infra/*.sh
./infra/setup-env.sh
./infra/deploy-api.sh
./infra/smoke-test.sh
```

## API

```bash
curl https://<api-id>.execute-api.ap-northeast-2.amazonaws.com/health

curl -X POST https://<api-id>.execute-api.ap-northeast-2.amazonaws.com/chat \
  -H 'Content-Type: application/json' \
  -d '{"sessionId":"demo","question":"졸업하려면 몇 학점을 들어야 하나요?"}'
```

- /health는 S3 문서 버킷 목록 조회와 대화 로그 테이블 쓰기를 실제로 해 보고 결과를 돌려준다.
- /chat은 지금은 임시 답변을 주고 질문을 대화 로그에 저장한다. 3주차에 Bedrock 지식 기반을 붙인다.

## 로컬 테스트

```bash
pip install boto3 pytest
python -m pytest -q
```
