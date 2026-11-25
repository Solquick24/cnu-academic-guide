# CNU 학사 길잡이 아키텍처

충남대학교 학사, 장학, 졸업요건 안내 RAG 챗봇이다. 1주차 기획서에서 잡은 전체 구조와 주차별 구현 범위를 정리한다.

## 전체 구조 (1주차 기획)

| 영역 | 서비스 | 역할 |
| --- | --- | --- |
| 웹 | CloudFront(OAC) + S3, AWS WAF | 채팅 화면 정적 호스팅과 요청 필터링 |
| API | API Gateway + Lambda(Chat API) | 질문 접수, 검색과 답변 생성 호출 |
| 검색 | Bedrock 지식 기반, Titan Text Embeddings V2, S3 Vectors | 학사 문서 청크(300토큰, 겹침 20%) 임베딩과 검색 |
| 생성 | Claude Sonnet 5 (서울 리전 내 추론) | 검색한 근거로 답변 생성 |
| 데이터 | S3 문서 버킷, DynamoDB 대화 로그 | 원문 문서 보관, 질문과 답변 기록 |
| 수집 | EventBridge Scheduler + 수집 Lambda | 학사 공지 주기 수집 |
| 운영 | IAM, CloudWatch Logs, CloudTrail | 권한, 로그, 감사 |

## 2주차 구현 범위

```
사용자(curl, 브라우저)
   |
   v
API Gateway HTTP API (cnu-guide-api, $default 스테이지)
   |  GET /health, POST /chat
   v
Lambda cnu-guide-chat-api (Python 3.12, arm64)
   |-- s3:ListBucket, s3:GetObject --> S3 cnu-guide-docs-<계정ID> (raw/ 문서)
   |-- dynamodb:PutItem/GetItem/Query --> DynamoDB CnuGuide-ChatLogs
   '-- logs --> CloudWatch Logs /aws/lambda/cnu-guide-chat-api (14일 보존)
```

- 실행 역할 CnuGuide-ChatApiRole에는 위 버킷, 테이블, 로그 그룹에만 권한을 줬다.
- /chat은 아직 고정된 임시 답변을 돌려주고 질문을 대화 로그에 저장한다.

## 다음 주차에 붙일 것

- Bedrock 지식 기반 생성, S3 문서 버킷을 데이터 소스로 연결, 실행 역할에 bedrock:Retrieve 권한 추가
- /chat에서 RetrieveAndGenerate 호출로 교체
- CloudFront + S3 채팅 화면, WAF 연결
