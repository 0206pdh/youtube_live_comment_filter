# RUNBOOK

이 문서는 `youtube_live_comment_filter` 서비스의 장애 대응 절차를 정리한 운영 런북이다. 현재 구조는 `Chrome Extension -> API Gateway -> ALB -> ECS Fargate -> FastAPI` 기준으로 작성하며, 로컬 개발 모드에서는 `Extension -> FastAPI(localhost)` 경로도 함께 고려한다.

## 1. 서비스 개요

현재 운영 대상 구성 요소:

- Chrome Extension: YouTube 라이브 채팅 텍스트를 수집하고 분류 API를 호출한다.
- API Gateway HTTP API: 외부 공개 엔드포인트를 제공한다.
- ALB: API Gateway 뒤에서 ECS 서비스로 트래픽을 전달한다.
- ECS Fargate: FastAPI 앱 컨테이너를 실행한다.
- SSM Parameter Store: `API_KEY`를 저장한다.
- CloudWatch Logs: FastAPI 로그, API Gateway 액세스 로그를 수집한다.
- WAF: ALB 앞단의 기본 웹 방어 계층이다.

현재 앱의 주요 엔드포인트:

- `GET /health`
- `GET /health/live`
- `GET /health/ready`
- `POST /predict`
- `POST /training-data`
- `POST /training-data/lookup`
- `POST /model/retrain`
- `POST /model/reload`
- `GET /model/training-status`

## 2. 공통 대응 원칙

장애 대응 시 기본 순서:

1. 사용자 영향 확인
2. 최근 변경 확인
3. 현재 상태 확인
4. 임시 복구 조치
5. 원인 분석
6. 영구 수정 및 재발 방지

우선 확인 항목:

- 언제부터 장애가 시작됐는가
- dev/prod 중 어느 환경에 발생했는가
- 전체 장애인가, 특정 API만 문제인가
- 최근 `terraform apply`, ECS 재배포, API Key 변경, 모델 재학습이 있었는가

필수 관찰 지점:

- API Gateway 응답 상태코드 추이
- ALB 대상 그룹 헬스 상태
- ECS 서비스 desired/running task 수
- FastAPI 애플리케이션 로그
- WAF 차단 수 급증 여부
- SSM `API_KEY` 교체 이력

## 3. 알람별 액션

### A. Health Check 실패

증상:

- `/health/live` 또는 `/health/ready` 실패
- ALB target group이 unhealthy 상태
- API Gateway는 502/503 증가

즉시 확인:

1. ECS 서비스 이벤트 확인
2. ECS task 로그 확인
3. 컨테이너가 정상 기동됐는지 확인
4. 모델 로딩 실패 메시지 확인

가능한 원인:

- 이미지 배포 실패
- 모델 파일 누락 또는 손상
- 앱 시작 시 예외 발생
- SSM secret 주입 실패
- readiness endpoint가 모델 준비 전까지 200을 못 반환

조치:

1. ECS 서비스의 running task 수가 0이면 새 deployment 강제 실행
2. 최근 이미지 배포 직후면 이전 안정 이미지로 롤백
3. 로그에서 모델 로딩 오류가 있으면 현재 이미지 또는 모델 아티팩트 점검
4. SSM 권한 또는 파라미터 값 문제면 ECS execution role과 파라미터 존재 여부 확인

복구 기준:

- ALB 대상 그룹 healthy
- `/health/live`, `/health/ready` 모두 200
- 5분 이상 5xx 비율 안정화

### B. 5xx 오류 급증

증상:

- API Gateway 5xx 또는 ALB 5xx 증가
- 확장에서 분류 실패 증가

즉시 확인:

1. 최근 배포 여부
2. ECS 로그의 Python stack trace
3. `/predict` 응답 지연과 실패 비율
4. task CPU/메모리 포화 여부

가능한 원인:

- 앱 코드 버그
- 모델 추론 예외
- 요청 폭주
- 메모리 부족으로 task 재시작

조치:

1. 최근 배포가 원인으로 의심되면 이전 이미지로 롤백
2. 메모리 부족이면 task 재시작 패턴과 OOM 징후 확인
3. 트래픽 급증이면 WAF/API Gateway throttling 동작 여부 확인
4. 특정 입력에서만 실패하면 문제 payload를 재현하고 일시적으로 필터링

복구 기준:

- 5xx 비율이 기준치 이하로 복귀
- 사용자 분류 요청 성공률 회복

### C. 지연시간 급증

증상:

- `/predict` 응답이 느려짐
- 확장에서 댓글 처리 지연
- p95 latency 상승

즉시 확인:

1. FastAPI 로그의 `latency_ms`
2. 배치 크기 증가 여부
3. CPU/메모리 사용량
4. 단일 noisy client 존재 여부

가능한 원인:

- 트래픽 급증
- 비정상적으로 큰 요청 배치
- 모델 추론 성능 저하
- 동시성 증가

조치:

1. noisy client가 있으면 WAF 또는 앱 rate limit 확인
2. 필요 시 ECS desired count 일시 상향
3. 최근 모델 교체 후 악화되었으면 이전 모델로 롤백
4. 긴급 시 training 관련 write 경로 사용 중지 검토

복구 기준:

- p95 latency가 평시 범위로 복귀
- 사용자 체감 지연 해소

### D. 인증 실패 급증

증상:

- 401/403 증가
- 확장에서 갑자기 모두 실패

즉시 확인:

1. API Key가 변경됐는지 확인
2. 확장 설정의 `apiKey` 값 확인
3. ECS task에 주입된 `API_KEY` 최신 반영 여부 확인
4. CORS/origin 설정 변경 여부 확인

가능한 원인:

- Parameter Store 값 교체 후 확장 미반영
- ECS 재배포 전후 키 불일치
- `ALLOWED_EXTENSION_IDS` 또는 `ALLOWED_ORIGINS` 오설정

조치:

1. SSM 현재 값과 확장 설정값 동기화
2. ECS 새 deployment로 최신 secret 반영
3. extension ID 허용값 재검토
4. 긴급 시 dev 환경에서는 인증 완화 여부를 팀 판단 하에 제한적으로 검토

복구 기준:

- 정상 사용자 요청의 401/403 감소
- 설정한 extension origin에서 정상 호출 가능

### E. GitHub Actions 배포 실패

증상:

- `terraform-infra` 실패
- `deploy-app` 실패

즉시 확인:

1. GitHub Actions 로그
2. OIDC role ARN과 trust policy
3. GitHub Variables 설정값
4. Terraform backend 설정 불일치 여부

가능한 원인:

- `DEV_TERRAFORM_ROLE_ARN`, `DEV_DEPLOY_ROLE_ARN` 오입력
- GitHub repository name과 OIDC trust 불일치
- backend.hcl과 실제 S3/DynamoDB 리소스 불일치

조치:

1. workflow에서 사용 중인 GitHub Variables 재검증
2. OIDC provider ARN과 trust policy의 `repo:<owner>/<repo>:*` 조건 확인
3. 인프라 배포가 급하지 않으면 로컬 `terraform plan/apply`로 우회
4. 앱 배포만 실패면 ECR push 권한과 ECS update-service 권한 확인

복구 기준:

- workflow 성공
- 새 이미지가 ECS에 반영됨

### F. WAF 차단 급증

증상:

- 정상 사용자도 차단
- 특정 시간대부터 403 증가

즉시 확인:

1. WAF sampled requests 확인
2. 어떤 rule이 차단했는지 확인
3. API Gateway/ALB 4xx 추이와 비교

가능한 원인:

- 공격성 트래픽 급증
- 정상 사용 패턴이 IP rate limit에 걸림

조치:

1. 공격이면 차단 유지 후 영향 범위 점검
2. 정상 트래픽 오탐이면 `ip_rate_limit` 상향 검토
3. 필요 시 일시적으로 rate-based rule만 비활성화

복구 기준:

- 정상 사용자 403 감소
- 실제 공격 방어 상태 유지

## 4. 운영 점검 절차

### 배포 직후 점검

1. `terraform output` 확인
2. `api_gateway_endpoint/health` 확인
3. `api_gateway_endpoint/health/live` 확인
4. `api_gateway_endpoint/health/ready` 확인
5. CloudWatch에서 앱 시작 로그 확인
6. extension에서 실제 분류 요청 테스트

### 일일 점검

- ECS running task 수
- ALB healthy target 수
- 5xx 추이
- auth failure 증가 여부
- rate limit rejection 증가 여부

## 5. 롤백 기준과 방법

롤백이 필요한 경우:

- 신규 배포 후 5분 내 health check 불안정
- 5xx 급증
- latency 급증
- 정상 사용자 인증 실패 급증

롤백 방법:

1. 이전 ECR 이미지 태그 확인
2. ECS task definition을 이전 이미지 기준으로 재배포
3. stable 상태까지 health check 확인

Terraform 변경 롤백:

1. 문제 커밋 revert
2. `terraform plan`으로 역변경 확인
3. 승인 후 `terraform apply`

## 6. 향후 구조 확장 시 런북 변경 포인트

README의 다음 단계 구현 후 이 문서를 확장해야 한다.

- S3 데이터 레이크 장애 대응
- RDS 연결 장애 대응
- SQS backlog 증가 대응
- 학습 worker 실패 대응
- 모델 registry 승격/롤백 절차

그 시점에는 추론 API 장애와 학습 파이프라인 장애를 분리해 운영한다.
