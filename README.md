# youtube_live_comment_filter 클라우드 고도화 가이드

이 문서는 현재 로컬 중심 구조(`Chrome Extension + FastAPI + 로컬 모델`)를 AWS 기반 운영형 아키텍처로 천천히 고도화하기 위한 실행 가이드다.

목표는 다음 4가지를 동시에 달성하는 것이다.

1. 안정성: 서비스 장애 시 빠른 복구와 무중단 배포
2. 확장성: 트래픽 증가 시 자동 확장
3. 보안성: 인증, 네트워크 격리, 비밀정보 보호
4. 운영성: 관측성(로그/메트릭/알람), 재현 가능한 배포(IaC)

---

## 1) 현재 상태 요약

현재 프로젝트는 아래 특성이 있다.

- `server/app.py`: 추론 API, 학습 데이터 저장, 재학습 트리거가 한 프로세스에 결합
- 저장소: 로컬 파일(JSONL, 모델 파일)
- 배포: 로컬 Python 실행 또는 Windows EXE
- 확장 프로그램: 서버 URL에 직접 요청

운영 관점 주요 리스크는 아래다.

- 인증/권한 제어 부재 시 외부 오용 가능
- 단일 인스턴스 장애가 전체 장애로 이어짐
- 학습/추론 결합으로 리소스 경합 발생
- 모델 버전 관리 및 롤백 체계 부족
- 운영 지표 부재로 장애 원인 파악 어려움

---

## 2) 고도화 원칙

천천히 시작하기 위해, 한 번에 모든 것을 바꾸지 않는다.

- 1단계: "배포 자동화 + 기본 보안"만 먼저
- 2단계: "데이터 저장소 분리 + 비동기 처리"
- 3단계: "MLOps(모델 버전/승인/배포전략)"
- 4단계: "SLO/비용 최적화"

핵심 분리 원칙:

- 추론(Inference)과 학습(Training)을 서비스/리소스 차원에서 분리
- 상태(State)를 인스턴스 로컬 디스크에서 관리형 저장소로 이동
- 사람이 하던 배포를 CI/CD와 Terraform으로 코드화

---

## 3) 단계별 고도화 로드맵

### Phase 0 (1~2주): 안전한 시작점 만들기

목표:

- 로컬 개발 경험 유지
- 클라우드 배포를 위한 최소 골격만 구축

작업:

1. 컨테이너화
- `server`를 Docker 이미지로 빌드 가능하게 구성
- `uvicorn` 실행 인자, 환경변수(`PORT`, `LOG_LEVEL`) 분리

2. API 기초 보안
- CORS 허용 도메인 화이트리스트화
- API Key 또는 JWT 검증 미들웨어 추가
- 요청당 rate limit 적용(예: API Gateway usage plan)

3. 헬스체크 분리
- `GET /health/live`
- `GET /health/ready` (모델 로드 상태 포함)

산출물:

- 단일 ECS 서비스로 추론 API 운영 가능
- Terraform으로 dev 환경 1회 배포 가능

현재 저장소 반영 상태:

- 완료: `server/Dockerfile` 추가
- 완료: `server/.env.example` 추가
- 완료: `server/app.py` 환경변수 기반 설정 구조화
- 완료: `server/app.py` 선택적 API Key 인증 추가
- 완료: `server/app.py` `/health/live`, `/health/ready` 추가
- 완료: `extension/options.html`, `extension/background.js`, `extension/popup.js`에 선택적 `X-API-Key` 연동 추가
- 완료: `server/app.py` 실시간 트래픽 계측 로그(`PREDICT_METRIC`, `TRAFFIC_SNAPSHOT`) 추가
- 완료: 학습 모드가 꺼져 있으면 `training_temp` 자동 저장 비활성화
- 완료: 앱 레벨 rate limit 적용 (`/predict`, `/training-data/lookup`, `/training-data`)

Phase 0 로컬 실행 예시:

```bash
docker build -f server/Dockerfile -t ylcf:phase0 .
docker run --rm -p 8000:8000 --env-file server/.env.example ylcf:phase0
```

Phase 0 보안 실행 예시:

```bash
docker run --rm -p 8000:8000 ^
  -e HOST=0.0.0.0 ^
  -e PORT=8000 ^
  -e API_KEY=change-me ^
  -e ENFORCE_AUTH=true ^
  -e ALLOWED_ORIGINS=http://localhost,http://127.0.0.1 ^
  ylcf:phase0
```

헬스체크 예시:

- liveness: `GET /health/live`
- readiness: `GET /health/ready`
- legacy compatibility: `GET /health`
- live metrics: `GET /metrics/live`

Phase 0 rate limit 기본값:

- `/predict`: 클라이언트당 분당 120회
- `/training-data/lookup`: 클라이언트당 분당 180회
- `/training-data`: 클라이언트당 분당 30회
- 초과 시: `429 Too Many Requests`
- 헤더: `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `Retry-After`

Phase 0 관측 로그 예시:

- `PREDICT_METRIC`
  - 요청 1건 기준 로그
  - 배치 크기(`batch_size`)
  - 총 문자 수(`characters`)
  - 추론 지연시간(`latency_ms`)
  - 라벨 분포(`normal`, `borderline_abusive`, `abusive`)
  - 호출자 식별값(`client = ip|origin`)
- `TRAFFIC_SNAPSHOT`
  - 누적 HTTP 요청 수
  - 분당 predict 요청 수
  - 분당 분류 텍스트 수
  - 평균/최대 배치 크기
  - 평균/p50/p95 추론 지연시간
  - 상태코드 분포
  - 상위 호출자(top clients)
  - 인증 실패 수
  - rate limit 차단 수(`rate_limit_rejections_total`)
  - 최대 동시 요청 수

이 로그를 먼저 1~2일 수집한 뒤 rate limit을 적용하면 다음을 전후 비교할 수 있다.

- p95 latency가 줄었는지
- 한 클라이언트가 전체 요청의 몇 %를 차지하는지
- 배치 크기가 실제로 어느 범위인지
- 분당 요청 수의 피크가 얼마인지
- rate limit 이후 401/429가 얼마나 발생하는지

---

### Phase 1 (2~4주): AWS 최소 운영 아키텍처

목표:

- 서버를 AWS로 이전
- 안정적인 배포/롤백 가능

작업:

1. 컴퓨트
- ECS Fargate 서비스 1개(추론 API)
- ALB 또는 API Gateway HTTP API를 앞단으로 배치

2. 이미지 레지스트리
- ECR 리포지토리 생성
- CI에서 이미지 빌드 후 `:sha`, `:latest` 태깅

3. 비밀정보
- Secrets Manager/SSM Parameter Store로 키 관리
- 하드코딩 제거

4. 로깅
- CloudWatch Logs 그룹/보존기간 설정
- 구조화 로그(JSON) 적용

산출물:

- `main` 머지 시 dev 자동 배포
- 수동 승인 후 prod 배포

현재 저장소 반영 상태:

- 시작됨: `infra/` Terraform 디렉터리 추가
- 시작됨: `infra/modules/network`로 VPC, public/private subnet, NAT, route table 구성
- 시작됨: `infra/modules/ecr`로 애플리케이션 이미지 저장소 구성
- 시작됨: `infra/modules/observability`로 CloudWatch Log Group 구성
- 시작됨: `infra/modules/ssm_parameters`로 `API_KEY` 등 런타임 비밀값 저장 시작
- 시작됨: `infra/modules/ecs_service`로 ECS Fargate + ALB dev 서비스 골격 구성
- 시작됨: `infra/modules/api_gateway`로 HTTP API 프록시 진입점 구성
- 시작됨: `infra/modules/waf`로 ALB 앞단 WAF 기본 규칙 구성
- 시작됨: `infra/modules/github_oidc_roles`로 GitHub Actions용 IAM Role 코드화
- 시작됨: `infra/environments/prod`로 prod 환경 골격 추가
- 시작됨: `.github/workflows/terraform-infra.yml` 추가
- 시작됨: `.github/workflows/deploy-app.yml` 추가

현재 단계에서 의도적으로 남겨둔 것:

- 아직 미적용: 원격 Terraform backend(S3 + DynamoDB) 실제 연결
- 아직 미적용: Route53 custom domain / ACM HTTPS 인증서
- 아직 미적용: API Gateway private integration(VPC Link)

설명:

- 지금 Phase 1은 "AWS dev 배포 골격"을 먼저 만드는 단계다.
- Edge는 우선 `API Gateway -> public ALB -> ECS(Fargate)`로 구성했다.
- WAF는 ALB에 먼저 붙였다. 이유는 API Gateway HTTP API에 비해 ALB 연결이 단순하고, Phase 1에서 실제 방어층을 가장 빠르게 확보할 수 있기 때문이다.
- 즉 방향은 여전히 `Chrome Extension -> API Gateway/WAF -> ECS(Fargate)`가 맞고, 지금 저장소는 그 방향의 dev 최소 구현까지 들어간 상태다.
- 여기에 더해 prod 환경과 GitHub OIDC Role 코드까지 추가했기 때문에, 이제 남은 건 "실계정 값 주입"과 "terraform apply"다.
- dev 환경도 이제 `github_oidc_roles`를 포함하므로, dev apply 결과에서 Terraform/deploy role ARN을 직접 확인할 수 있다.

Phase 1 실제 적용 전에 사용자가 준비해야 하는 값:

1. AWS 기본 정보
- AWS Account ID
- 배포 리전 (예: `ap-northeast-2`)
- Terraform state용 S3 bucket 이름/ARN
- Terraform lock용 DynamoDB table 이름/ARN

2. GitHub 연동 정보
- GitHub repository 이름 (`owner/repo`)
- GitHub OIDC provider ARN
- GitHub Actions가 assume할 Terraform role 이름
- GitHub Actions가 assume할 deploy role 이름

3. 애플리케이션 런타임 값
- Chrome extension ID
- 실제 `API_KEY`
- 허용 origin 정책

4. 운영용 선택 사항
- Route53 hosted zone
- ACM certificate ARN
- custom domain 이름

각 값은 어디서 어떻게 준비하는가:

1. AWS 기본 정보
- `AWS Account ID`
  - 위치: AWS Console 우측 상단 계정 메뉴 또는 `My Account`
  - CLI: `aws sts get-caller-identity`
  - 용도: IAM Role ARN, OIDC provider ARN, DynamoDB ARN, S3 ARN 구성
- `배포 리전`
  - 위치: AWS Console 우측 상단 region selector
  - 예시: `ap-northeast-2`
  - 기준: 사용자/운영 대상과 가까운 리전, 비용, 서비스 지원 여부
- `Terraform state용 S3 bucket`
  - 위치: AWS Console > S3 > 버킷 생성
  - 권장 이름 예시: `youtube-live-comment-filter-tfstate`
  - 권장 설정:
    - Versioning 활성화
    - Public access block 전체 활성화
    - SSE-S3 또는 SSE-KMS 암호화 활성화
  - 용도: Terraform 상태 파일 저장
- `state lock용 DynamoDB table`
  - 위치: AWS Console > DynamoDB > 테이블 생성
  - 권장 이름 예시: `youtube-live-comment-filter-tf-lock`
  - 파티션 키:
    - `LockID` (String)
  - 용도: Terraform 동시 실행 잠금 제어

2. GitHub 연동 정보
- `GitHub repository 이름 (owner/repo)`
  - 위치: GitHub 저장소 메인 화면 URL
  - 예시: `your-org/youtube_live_comment_filter`
  - 용도: GitHub OIDC trust policy에서 어느 저장소가 role을 assume할 수 있는지 제한
- `GitHub OIDC provider ARN`
  - 위치: AWS Console > IAM > Identity providers
  - 생성 방법:
    - Provider URL: `https://token.actions.githubusercontent.com`
    - Audience: `sts.amazonaws.com`
  - 생성 후 ARN 예시:
    - `arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com`
  - 용도: GitHub Actions가 장기 액세스 키 없이 AWS role assume
- `GitHub Actions가 assume할 Terraform role 이름`
  - 위치: 이번 저장소의 Terraform 기준으로는 `infra/modules/github_oidc_roles`가 생성
  - 예시 이름:
    - `ylcf-prod-terraform-role`
    - `ylcf-dev-terraform-role`
  - 용도: `terraform plan/apply` 수행
- `GitHub Actions가 assume할 deploy role 이름`
  - 위치: 동일하게 `infra/modules/github_oidc_roles`가 생성
  - 예시 이름:
    - `ylcf-prod-deploy-role`
    - `ylcf-dev-deploy-role`
  - 용도: Docker image push, ECS service redeploy

3. 애플리케이션 런타임 값
- `실제 Chrome extension ID`
  - 위치:
    - Chrome 주소창에 `chrome://extensions`
    - 확장 프로그램 카드에서 ID 확인
  - 주의:
    - 로컬 unpacked extension은 브라우저/환경에 따라 바뀔 수 있음
    - Chrome Web Store 배포 후 고정 ID를 기준으로 운영하는 것이 좋음
  - 용도:
    - `ALLOWED_EXTENSION_IDS`
    - API Gateway / 앱 CORS 정책
- `실제 API_KEY`
  - 준비 방법:
    - 랜덤하고 충분히 긴 문자열 생성
    - 예: 32~64자
  - 생성 예시:
    - PowerShell: `[guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N")`
  - 저장 위치:
    - AWS Console > Systems Manager > Parameter Store
    - 또는 Terraform의 `api_key_placeholder`를 실제 값으로 교체
  - 사용 위치:
    - ECS 컨테이너 환경의 `API_KEY`
    - Chrome extension 옵션의 API Key 입력값
- `허용할 origin 정책`
  - 구성 대상:
    - `ALLOWED_ORIGINS`
    - `ALLOWED_EXTENSION_IDS`
  - 웹 origin 예시:
    - `http://localhost`
    - `http://127.0.0.1`
  - 확장 origin 예시:
    - `chrome-extension://<extension_id>`
  - 기준:
    - 운영에서는 최소 허용 원칙으로 필요한 origin만 등록

4. 운영용 선택 값
- `Route53 hosted zone`
  - 위치: AWS Console > Route53 > Hosted zones
  - 준비 방법:
    - 보유 도메인을 Route53에 등록하거나
    - 외부 도메인을 Route53 hosted zone으로 연결
  - 용도:
    - API Gateway 또는 ALB 앞단에 사람이 읽는 도메인 연결
- `ACM certificate ARN`
  - 위치: AWS Console > Certificate Manager (ACM)
  - 준비 방법:
    - 대상 도메인에 대해 퍼블릭 인증서 요청
    - DNS 검증 수행
  - 예시:
    - `api.example.com` 용 인증서
  - 용도:
    - HTTPS 종단
    - custom domain 연결
- `custom domain 이름`
  - 예시:
    - `api.example.com`
    - `chat-filter.example.com`
  - 준비 기준:
    - Route53 hosted zone과 ACM 인증서가 준비되어 있어야 함
  - 용도:
    - 확장 프로그램에서 고정 API Gateway invoke URL 대신 사람이 관리하기 쉬운 도메인 사용

실제 준비 순서 추천:

1. AWS Account ID와 배포 리전을 먼저 확정
2. Terraform state용 S3 bucket과 DynamoDB lock table 생성
3. GitHub OIDC provider 생성
4. dev 또는 prod용 Terraform / deploy role 생성
5. Chrome extension ID 확정
6. API_KEY 생성 및 SSM Parameter Store 저장
7. 필요하면 Route53 hosted zone, ACM certificate, custom domain 준비

준비 절차 상세:

### 3.1 Terraform state용 S3 bucket 생성

목적:

- Terraform 상태 파일(`terraform.tfstate`)을 안전하게 중앙 저장
- 여러 사람이 작업해도 동일한 상태 기준 사용
- GitHub Actions와 로컬 Terraform이 같은 상태를 공유

AWS Console 기준 절차:

1. AWS Console 접속
2. 상단 검색창에서 `S3` 검색
3. `Buckets` 화면에서 `Create bucket` 클릭
4. Bucket name 입력
   - 예: `youtube-live-comment-filter-tfstate`
   - 전역 고유 이름이어야 함
5. Region 선택
   - Terraform을 주로 적용할 리전과 동일하게 맞추는 것이 관리상 편함
6. `Block Public Access settings for this bucket`
   - 모든 항목 체크 유지
   - 이유: Terraform state는 공개되면 안 됨
7. `Bucket Versioning`
   - `Enable` 선택
   - 이유: state 손상/오류 시 이전 버전 복구 가능
8. `Default encryption`
   - 최소 `SSE-S3` 활성화
   - 가능하면 운영에서는 `SSE-KMS`도 검토
9. `Create bucket` 클릭

생성 후 추가 확인:

- `Properties` 탭에서 Versioning이 `Enabled`인지 확인
- `Permissions` 탭에서 Public access block이 모두 `On`인지 확인
- `Properties` 또는 `General purpose buckets` 목록에서 bucket 이름 확인

나중에 어디에 넣는가:

- `infra/environments/dev/backend.hcl`
- `infra/environments/prod/backend.hcl`

예시:

```hcl
bucket = "youtube-live-comment-filter-tfstate"
```

CLI 예시:

```bash
aws s3api create-bucket \
  --bucket youtube-live-comment-filter-tfstate \
  --region ap-northeast-2 \
  --create-bucket-configuration LocationConstraint=ap-northeast-2

aws s3api put-bucket-versioning \
  --bucket youtube-live-comment-filter-tfstate \
  --versioning-configuration Status=Enabled
```

주의:

- state bucket은 정적 웹 호스팅 용도가 아니므로 퍼블릭 액세스를 절대 열지 않음
- state 파일에는 인프라 구조와 민감 메타데이터가 포함될 수 있음

### 3.2 Terraform lock용 DynamoDB table 생성

목적:

- Terraform 동시 실행 충돌 방지
- GitHub Actions와 로컬 사용자가 동시에 apply할 때 lock 제어

AWS Console 기준 절차:

1. AWS Console에서 `DynamoDB` 검색
2. `Tables` 화면에서 `Create table` 클릭
3. Table name 입력
   - 예: `youtube-live-comment-filter-tf-lock`
4. Partition key 입력
   - 이름: `LockID`
   - 타입: `String`
5. Capacity mode
   - `On-demand` 권장
   - 이유: 락 용도라 트래픽이 낮고 관리가 쉬움
6. 나머지 옵션은 기본값으로 두고 `Create table`

생성 후 확인:

- 테이블 이름
- 리전
- ARN

나중에 어디에 넣는가:

- `infra/environments/dev/backend.hcl`
- `infra/environments/prod/backend.hcl`

예시:

```hcl
dynamodb_table = "youtube-live-comment-filter-tf-lock"
```

CLI 예시:

```bash
aws dynamodb create-table \
  --table-name youtube-live-comment-filter-tf-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-northeast-2
```

### 3.3 GitHub OIDC provider 생성

목적:

- GitHub Actions가 AWS 장기 액세스 키 없이 IAM Role을 Assume
- 보안상 GitHub Secrets에 AWS Access Key를 저장하지 않음

AWS Console 기준 절차:

1. AWS Console에서 `IAM` 검색
2. 왼쪽 메뉴 `Identity providers`
3. `Add provider` 클릭
4. Provider type
   - `OpenID Connect`
5. Provider URL
   - `https://token.actions.githubusercontent.com`
6. Audience
   - `sts.amazonaws.com`
7. `Add provider` 클릭

생성 후 필요한 값:

- Provider ARN
  - 예: `arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com`

나중에 어디에 넣는가:

- `infra/environments/prod/terraform.tfvars`
- 필요 시 dev 환경에도 동일하게 사용

### 3.4 GitHub repository 정보 확인

목적:

- OIDC trust policy에서 어떤 저장소가 role을 assume할 수 있는지 제한

확인 방법:

1. GitHub 저장소 메인으로 이동
2. URL 확인
   - 예: `https://github.com/your-org/youtube_live_comment_filter`
3. 필요한 값 추출
   - `your-org/youtube_live_comment_filter`

나중에 어디에 넣는가:

- `github_repository` 변수

### 3.5 API_KEY 생성 및 저장

목적:

- 확장 프로그램과 서버 사이의 1차 공유 인증값
- extension ID 대신 실제 보호 기준으로 사용

생성 기준:

- 최소 32자 이상
- 예측 가능한 문자열 금지
- 운영/개발 키는 분리

PowerShell 생성 예시:

```powershell
[guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N")
```

OpenSSL 예시:

```bash
openssl rand -hex 32
```

저장 방법 1: Terraform 변수 파일에 임시 저장

- `infra/environments/dev/terraform.tfvars`
- `infra/environments/prod/terraform.tfvars`

예시:

```hcl
api_key_placeholder = "여기에_실제_랜덤_API_KEY"
```

저장 방법 2: AWS Parameter Store에서 직접 수정

1. AWS Console에서 `Systems Manager` 검색
2. `Parameter Store` 이동
3. Terraform으로 생성된 파라미터 찾기
   - 예: `/<project_name>/api/API_KEY`
4. `Edit` 클릭 후 실제 값 입력

확장 프로그램 쪽 사용:

- `chrome://extensions`에서 확장 프로그램 열기
- 옵션 페이지에서 API Key 입력
- 서버와 동일한 값이어야 함

주의:

- 공개 저장소에 실제 API Key를 커밋하지 않음
- dev용과 prod용은 반드시 분리

### 3.6 Chrome extension ID 확인

목적:

- 필요 시 `ALLOWED_EXTENSION_IDS` 또는 origin 정책 구성

확인 방법:

1. Chrome 주소창에 `chrome://extensions`
2. 우측 상단 `개발자 모드` 활성화
3. 해당 확장 프로그램 카드에서 `ID` 확인

주의:

- 현재처럼 unpacked extension 로드 방식이면 사람마다 다를 수 있음
- 따라서 운영의 절대 인증 기준으로 쓰지 않음
- 현재 구조에서는 보조적인 CORS/운영 참고값으로만 사용

### 3.7 허용 Origin 정책 정리

목적:

- CORS를 최소 허용 원칙으로 제한

현재 구조에서 고려할 origin:

1. 로컬 테스트용 웹 origin
- `http://localhost`
- `http://127.0.0.1`

2. Chrome extension origin
- `chrome-extension://<extension_id>`
- 단, unpacked extension 배포 방식에서는 고정 관리가 어려움

권장 운영 원칙:

- 서버 보호의 주 기준은 `API_KEY`, WAF, rate limit
- origin은 보조 정책
- 운영 중 확장 ID가 고정되지 않는다면 `ALLOWED_EXTENSION_IDS`를 필수값으로 강제하지 않음

### 3.8 Route53 hosted zone 준비

필요한 경우:

- 사람이 읽기 쉬운 도메인을 API Gateway 또는 ALB에 연결하고 싶을 때

AWS Console 기준 절차:

1. `Route53` 검색
2. `Hosted zones` 이동
3. `Create hosted zone`
4. Domain name 입력
   - 예: `example.com`
5. Type
   - `Public hosted zone`
6. 생성 후 NS 레코드 확인
7. 외부 도메인을 쓰는 경우 도메인 등록업체에 NS 위임 설정

필요한 값:

- Hosted zone name
- Hosted zone ID

### 3.9 ACM certificate 준비

필요한 경우:

- custom domain에 HTTPS 적용

AWS Console 기준 절차:

1. `Certificate Manager` 또는 `ACM` 검색
2. `Request certificate`
3. `Request a public certificate`
4. 도메인 입력
   - 예: `api.example.com`
5. 검증 방식
   - `DNS validation` 권장
6. Route53 사용 중이면 자동 검증 레코드 생성 가능
7. 발급 완료 후 ARN 확인

필요한 값:

- Certificate ARN

주의:

- API Gateway custom domain과 연결하려면 인증서 리전 조건도 확인해야 함
- 현재 프로젝트는 아직 custom domain 연결 코드는 넣지 않았으므로 준비 정보만 확보

### 3.10 Custom domain 이름 정하기

예시:

- `api.example.com`
- `chat-filter.example.com`

기준:

- API 용도임이 명확한 이름 사용
- 이후 Route53과 ACM에서 동일한 이름으로 연결

### 3.11 Terraform 변수 파일 실제 작성

dev 예시:

1. `infra/environments/dev/terraform.tfvars.example` 복사
2. 파일명을 `terraform.tfvars`로 저장
3. 값 입력

예시:

```hcl
aws_region            = "ap-northeast-2"
project_name          = "ylcf-dev"
github_repository     = "your-org/youtube_live_comment_filter"
allowed_extension_ids = []
api_key_placeholder   = "여기에_랜덤_API_KEY"
```

prod 예시:

1. `infra/environments/prod/terraform.tfvars.example` 복사
2. 파일명을 `terraform.tfvars`로 저장
3. 값 입력

예시:

```hcl
aws_region                 = "ap-northeast-2"
project_name               = "ylcf-prod"
github_repository          = "your-org/youtube_live_comment_filter"
allowed_extension_ids      = []
api_key_placeholder        = "여기에_랜덤_API_KEY"
oidc_provider_arn          = "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
terraform_state_bucket_arn = "arn:aws:s3:::youtube-live-comment-filter-tfstate"
terraform_lock_table_arn   = "arn:aws:dynamodb:ap-northeast-2:<ACCOUNT_ID>:table/youtube-live-comment-filter-tf-lock"
```

### 3.12 Terraform backend 파일 실제 작성

dev 예시:

1. `infra/environments/dev/backend.hcl.example` 복사
2. 파일명을 `backend.hcl`로 저장
3. 값 입력

```hcl
bucket         = "youtube-live-comment-filter-tfstate"
key            = "youtube-live-comment-filter/dev/terraform.tfstate"
region         = "ap-northeast-2"
encrypt        = true
dynamodb_table = "youtube-live-comment-filter-tf-lock"
```

prod 예시:

```hcl
bucket         = "youtube-live-comment-filter-tfstate"
key            = "youtube-live-comment-filter/prod/terraform.tfstate"
region         = "ap-northeast-2"
encrypt        = true
dynamodb_table = "youtube-live-comment-filter-tf-lock"
```

### 3.13 실제 apply 전 점검 체크리스트

1. S3 state bucket 생성 완료
2. DynamoDB lock table 생성 완료
3. GitHub OIDC provider 생성 완료
4. dev/prod `terraform.tfvars` 작성 완료
5. dev/prod `backend.hcl` 작성 완료
6. 실제 `API_KEY` 생성 완료
7. 확장 프로그램 옵션에 동일한 API Key 입력 준비 완료
8. AWS 인증(`aws configure` 또는 SSO) 준비 완료
9. GitHub Actions role ARN placeholder를 실제 값으로 교체할 계획 수립

### 3.14 지금 3.6까지 준비했다면 Phase 1을 마무리하는 순서

전제:

- `3.1 ~ 3.6`까지 준비 완료
- 즉 최소한 아래는 확보된 상태
  - AWS Account ID
  - AWS region
  - Terraform state용 S3 bucket
  - Terraform lock용 DynamoDB table
  - GitHub repository 이름
  - GitHub OIDC provider ARN
  - 실제 API_KEY

이제 해야 할 일은 "준비한 값을 실제 파일과 GitHub 설정에 넣고 apply"하는 것이다.

1. dev용 `terraform.tfvars` 작성

파일:

- `infra/environments/dev/terraform.tfvars`

어떻게 만들까:

- `infra/environments/dev/terraform.tfvars.example`를 복사
- 파일명을 `terraform.tfvars`로 변경

여기에 넣을 값:

- `aws_region`
  - 넣는 값 예: `ap-northeast-2`
- `project_name`
  - 권장 값 예: `ylcf-dev`
- `github_repository`
  - 예: `your-org/youtube_live_comment_filter`
- `allowed_extension_ids`
  - 현재 unpacked extension 운영이면 일단 빈 배열 `[]`로 두는 것을 권장
- `api_key_placeholder`
  - 네가 준비한 실제 API_KEY

예시:

```hcl
aws_region            = "ap-northeast-2"
project_name          = "ylcf-dev"
github_repository     = "your-org/youtube_live_comment_filter"
allowed_extension_ids = []
api_key_placeholder   = "여기에_실제_DEV_API_KEY"
```

2. dev용 `backend.hcl` 작성

파일:

- `infra/environments/dev/backend.hcl`

어떻게 만들까:

- `infra/environments/dev/backend.hcl.example`를 복사
- 파일명을 `backend.hcl`로 변경

여기에 넣을 값:

- `bucket`
  - 네가 만든 Terraform state bucket 이름
- `key`
  - state 파일 경로. dev/prod를 분리
- `region`
  - 실제 AWS region
- `dynamodb_table`
  - 네가 만든 lock table 이름

예시:

```hcl
bucket         = "youtube-live-comment-filter-tfstate"
key            = "youtube-live-comment-filter/dev/terraform.tfstate"
region         = "ap-northeast-2"
encrypt        = true
dynamodb_table = "youtube-live-comment-filter-tf-lock"
```

3. prod용 값도 미리 작성할지 결정

바로 prod까지 갈 계획이면 아래 파일도 같이 작성:

- `infra/environments/prod/terraform.tfvars`
- `infra/environments/prod/backend.hcl`

현재 단계에서 dev 먼저 검증하는 것이 더 안전하다.

4. GitHub Actions Variables 입력

위치:

- GitHub Repository > `Settings` > `Secrets and variables` > `Actions` > `Variables`

넣어야 할 값:

- `AWS_REGION`
- `DEV_TERRAFORM_ROLE_ARN`
- `DEV_DEPLOY_ROLE_ARN`
- `DEV_ECR_REPOSITORY`
- `DEV_ECS_CLUSTER`
- `DEV_ECS_SERVICE`
- `PROD_TERRAFORM_ROLE_ARN`
- `PROD_DEPLOY_ROLE_ARN`
- `PROD_ECR_REPOSITORY`
- `PROD_ECS_CLUSTER`
- `PROD_ECS_SERVICE`

설명:

- 이번 저장소의 `.github/workflows/*.yml`은 이제 하드코딩 placeholder 대신 GitHub Variables를 읽도록 바뀌어 있다.
- 즉 위 값들을 GitHub UI에 넣어야 워크플로가 실제로 동작한다.

5. 로컬에서 dev Terraform 적용

현재 셸이 AWS에 연결돼 있다면 아래 순서로 진행:

```bash
terraform -chdir=infra/environments/dev init -backend-config=backend.hcl
terraform -chdir=infra/environments/dev plan
terraform -chdir=infra/environments/dev apply
```

여기서 기대 결과:

- VPC
- public/private subnet
- NAT gateway
- ECR repository
- CloudWatch log group
- SSM parameter
- ECS cluster/service
- ALB
- API Gateway
- WAF

6. apply 결과값 확인

특히 확인해야 할 출력:

- `api_gateway_endpoint`
- `alb_dns_name`
- `ecr_repository_url`
- `terraform_role_arn`
- `deploy_role_arn`

이 중에서 실제 클라이언트가 바라볼 값은:

- `api_gateway_endpoint`

7. 확장 프로그램 설정 변경

위치:

- Chrome > `chrome://extensions`
- 확장 프로그램 옵션 열기

넣어야 할 값:

- `serverUrl`
  - Terraform apply 결과의 `api_gateway_endpoint`
- `API Key`
  - dev에서 사용한 `api_key_placeholder`와 같은 값

8. 서버 헬스체크 확인

확인 대상:

- `<api_gateway_endpoint>/health`
- `<api_gateway_endpoint>/health/live`
- `<api_gateway_endpoint>/health/ready`

정상이라면:

- API Gateway -> ALB -> ECS(Fargate) -> FastAPI 경로가 연결된 것

9. GitHub Actions로 dev 자동화 검증

확인 방법:

- `main` 브랜치에 infra/server 변경 반영
- GitHub Actions에서 `terraform-infra`와 `deploy-app` 워크플로 동작 확인

10. 그다음 prod로 확장

dev가 안정적이면:

- `infra/environments/prod/terraform.tfvars`
- `infra/environments/prod/backend.hcl`
- prod용 GitHub Variables

를 채우고, prod apply를 수동 승인 기반으로 수행

중요:

- `terraform.tfvars`, `backend.hcl`은 민감 정보가 포함될 수 있으므로 git에 커밋하지 않는다.
- 현재 `.gitignore`에 해당 파일들이 제외되도록 추가되어 있다.

Phase 1 적용 순서:

1. `infra/environments/dev/terraform.tfvars.example`를 복사해 실제 값 채우기
2. 필요 시 `infra/environments/prod/terraform.tfvars.example`도 채우기
3. remote backend를 쓸 경우 `backend.hcl.example` 기반으로 실제 backend 파일 준비
4. AWS 자격증명 또는 SSO로 `terraform init`, `plan`, `apply`
5. apply 결과의 `api_gateway_endpoint`를 확장 프로그램 서버 주소로 설정

---

### Phase 2 (3~6주): 데이터 계층 분리

목표:

- 로컬 파일 의존 제거
- 다중 인스턴스 확장 가능한 상태로 전환

작업:

1. 저장소 전환
- 학습 원천 데이터: S3
- 메타데이터/통계/관리 테이블: RDS PostgreSQL
- 임시 캐시: ElastiCache Redis (선택)

2. 비동기 파이프라인
- 학습데이터 저장 API -> SQS 큐 -> 데이터 처리 워커
- 재학습 요청 -> 배치 잡 트리거(SageMaker Processing 또는 ECS one-off task)

3. 파일 구조 표준화
- S3 key 예시:
  - `raw/training/yyyy/mm/dd/*.jsonl`
  - `processed/dataset/{dataset_version}/...`
  - `models/{model_version}/...`

산출물:

- 앱 인스턴스 증설 시에도 데이터 일관성 유지
- 학습/추론 부하 분리

---

### Phase 3 (4~8주): MLOps 체계 도입

목표:

- "모델 버전 등록 -> 검증 -> 배포" 자동화

작업:

1. 모델 레지스트리
- SageMaker Model Registry 또는 MLflow 도입
- 모델 버전에 메트릭(F1, precision, recall) 저장

2. 배포 전략
- Blue/Green 또는 Canary
- 승격 기준: 오탐/미탐 임계치, p95 latency, 에러율

3. 롤백 체계
- 이전 모델 버전으로 즉시 롤백 스크립트 제공
- 롤백 실행 시 Slack/이메일 알림

산출물:

- 성능 저하 모델의 운영 반영 방지
- 검증된 모델만 프로덕션 반영

---

### Phase 4 (지속): 운영 최적화

목표:

- 비용과 성능 균형 최적화

작업:

1. SLO 설정
- 가용성: 99.9%
- 추론 p95 latency: 예시 300ms 이내
- 5xx 에러율: 예시 1% 미만

2. 오토스케일
- ECS CPU/Memory + 요청 수 기반 타겟 추적
- 피크 시간 사전 스케일 아웃 스케줄링

3. 비용 관리
- CloudWatch 대시보드 + Cost Explorer 태그 분리
- 비활성 환경 자동 중지(예: dev 야간 중지)

---

## 4) AWS 리소스 설계도 (권장안)

### 4.1 논리 아키텍처

```text
[Chrome Extension]
    |
    v
[API Gateway HTTP API + WAF]
    |
    v
[ECS Fargate: inference-api] --(logs/metrics)--> [CloudWatch]
    |                     \
    |                      \--(cache)--> [ElastiCache Redis(Optional)]
    |
    +--(metadata)--> [RDS PostgreSQL]
    |
    +--(raw data/model artifacts)--> [S3]
    |
    +--(async event)--> [SQS] --> [ECS Worker or Lambda]

[CI/CD (GitHub Actions)]
    -> [ECR Push]
    -> [Terraform Apply]
    -> [ECS Deploy]
```

### 4.2 네트워크 설계

- VPC
  - Public Subnet: ALB (또는 NAT Gateway)
  - Private Subnet: ECS, RDS, Redis
- Security Group
  - ALB/API GW -> ECS 80/8000 허용
  - ECS -> RDS 5432 허용
  - ECS -> Redis 6379 허용
- NAT Gateway 최소 1개(운영은 AZ별 검토)

### 4.3 리소스 상세 표

| 영역 | AWS 서비스 | 용도 | 시작 스펙(예시) |
|---|---|---|---|
| Edge/API | API Gateway HTTP API + WAF | 인증 전단, rate limit, 공격 완화 | Stage: dev/prod |
| Compute | ECS Fargate | 추론 API 컨테이너 실행 | 0.5 vCPU / 1GB, min 1 max 4 |
| Registry | ECR | 컨테이너 이미지 저장 | immutable tag 권장 |
| DB | RDS PostgreSQL | 사용자/라벨 메타데이터 | db.t4g.micro (dev) |
| Object Storage | S3 | 학습 원본/모델 아티팩트 | 버저닝 on |
| Queue | SQS | 비동기 학습 파이프라인 | Standard queue |
| Secret | Secrets Manager | API 키, DB 비밀번호 | 자동 회전 옵션 |
| Observability | CloudWatch + X-Ray | 로그/메트릭/트레이싱 | 로그 보존 30일 시작 |
| IAM | IAM Role/Policy | 최소권한 실행 | 서비스별 분리 |

---

## 5) Terraform 디렉터리 구조 (권장)

아래처럼 `infra/`를 루트에 추가해 운영한다.

```text
infra/
  modules/
    network/
      main.tf
      variables.tf
      outputs.tf
    ecr/
      main.tf
      variables.tf
      outputs.tf
    ecs_service/
      main.tf
      variables.tf
      outputs.tf
    rds_postgres/
      main.tf
      variables.tf
      outputs.tf
    s3_data_lake/
      main.tf
      variables.tf
      outputs.tf
    sqs_pipeline/
      main.tf
      variables.tf
      outputs.tf
    observability/
      main.tf
      variables.tf
      outputs.tf
    iam/
      main.tf
      variables.tf
      outputs.tf
  environments/
    dev/
      main.tf
      variables.tf
      terraform.tfvars
      backend.hcl
    prod/
      main.tf
      variables.tf
      terraform.tfvars
      backend.hcl
  global/
    versions.tf
    providers.tf
    backend.tf
  scripts/
    plan-dev.sh
    apply-dev.sh
    plan-prod.sh
    apply-prod.sh
```

운영 규칙:

- `modules/`: 재사용 가능한 리소스 단위
- `environments/dev|prod`: 환경별 조합 및 값 주입
- 상태 파일(terraform state): S3 + DynamoDB Locking 사용
- PR에서는 `terraform plan`만, `main` 병합 후 승인 기반 `apply`

---

## 6) Terraform 작성 순서 (천천히 시작 버전)

1. `network` 모듈 먼저
- VPC, subnet, route table, nat

2. `ecr`, `iam`, `observability`
- 배포 파이프라인 준비

3. `ecs_service`
- Task Definition, Service, Auto Scaling

4. `s3_data_lake`, `rds_postgres`, `sqs_pipeline`
- 데이터 계층 이동

5. `environments/dev` 완성 후 `prod` 복제
- 변수값만 다르게 유지

---

## 7) CI/CD 파이프라인 설계

GitHub Actions 기준으로 예시를 제시한다.

- 파이프라인 A: 애플리케이션 배포 (`server` 이미지 빌드, ECR 푸시, ECS 배포)
- 파이프라인 B: 인프라 배포 (`terraform fmt/validate/plan/apply`)

권장 브랜치 전략:

- `feature/*` -> PR -> `main`
- `main` 머지 시 dev 자동 배포
- prod는 수동 승인 환경(Environment protection rules)

### 7.1 앱 배포 YAML 예시

```yaml
name: deploy-app

on:
  push:
    branches: [ "main" ]
    paths:
      - "server/**"
      - ".github/workflows/deploy-app.yml"

permissions:
  id-token: write
  contents: read

env:
  AWS_REGION: ap-northeast-2
  ECR_REPOSITORY: youtube-live-filter-api
  ECS_CLUSTER: ylcf-dev-cluster
  ECS_SERVICE: ylcf-dev-api
  ECS_TASK_FAMILY: ylcf-dev-task

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/github-actions-deploy-role
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to ECR
        id: ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push image
        env:
          ECR_REGISTRY: ${{ steps.ecr.outputs.registry }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG ./server
          docker tag $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG $ECR_REGISTRY/$ECR_REPOSITORY:latest
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:latest

      - name: Render task definition
        id: taskdef
        uses: aws-actions/amazon-ecs-render-task-definition@v1
        with:
          task-definition: infra/ecs/taskdef-dev.json
          container-name: api
          image: ${{ steps.ecr.outputs.registry }}/${{ env.ECR_REPOSITORY }}:${{ github.sha }}

      - name: Deploy to ECS
        uses: aws-actions/amazon-ecs-deploy-task-definition@v2
        with:
          task-definition: ${{ steps.taskdef.outputs.task-definition }}
          service: ${{ env.ECS_SERVICE }}
          cluster: ${{ env.ECS_CLUSTER }}
          wait-for-service-stability: true
```

### 7.2 Terraform 배포 YAML 예시

```yaml
name: terraform-infra

on:
  pull_request:
    paths:
      - "infra/**"
      - ".github/workflows/terraform-infra.yml"
  push:
    branches: [ "main" ]
    paths:
      - "infra/**"
      - ".github/workflows/terraform-infra.yml"

permissions:
  id-token: write
  contents: read
  pull-requests: write

env:
  AWS_REGION: ap-northeast-2
  TF_VERSION: "1.8.5"

jobs:
  plan:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/github-actions-terraform-role
          aws-region: ${{ env.AWS_REGION }}
      - name: Terraform fmt
        run: terraform -chdir=infra/environments/dev fmt -check -recursive
      - name: Terraform init
        run: terraform -chdir=infra/environments/dev init -backend-config=backend.hcl
      - name: Terraform validate
        run: terraform -chdir=infra/environments/dev validate
      - name: Terraform plan
        run: terraform -chdir=infra/environments/dev plan -out=tfplan

  apply-dev:
    if: github.event_name == 'push'
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/github-actions-terraform-role
          aws-region: ${{ env.AWS_REGION }}
      - name: Terraform init
        run: terraform -chdir=infra/environments/dev init -backend-config=backend.hcl
      - name: Terraform apply
        run: terraform -chdir=infra/environments/dev apply -auto-approve
```

운영 권장:

- prod `apply`는 별도 job + `environment: prod` 승인 필수
- `tfsec`, `checkov`, `trivy`를 PR 게이트에 추가

---

## 8) 보안 체크리스트

필수:

1. API 인증 강제(API Key/JWT)
2. CORS를 확장 프로그램 ID 기준으로 제한
3. Secrets는 코드/레포에 저장 금지
4. 최소 권한 IAM(Role 분리)
5. WAF 룰(봇/과다요청/IP 평판) 적용

권장:

1. CloudTrail, GuardDuty 활성화
2. S3 버킷 퍼블릭 차단 기본값 유지
3. RDS 암호화 at-rest + TLS in-transit

---

## 9) 관측성 설계

로그:

- 요청 ID, 사용자 ID(익명화), 모델 버전, latency_ms, label 분포

메트릭:

- `inference_requests_total`
- `inference_latency_p95_ms`
- `inference_error_rate`
- `training_job_success_rate`

알람:

- 5xx 급증
- p95 latency 임계 초과
- ECS task restart 반복

---

## 10) 비용 추정 접근

초기에는 "최소 안정 운영"으로 시작한다.

- ECS Fargate 소형 스펙 + min task 1
- RDS dev는 최소 스펙, prod는 Multi-AZ 여부 트래픽 기반 결정
- CloudWatch 로그 보존기간 30일로 시작 후 조정

비용 태깅 정책:

- `Project=youtube-live-comment-filter`
- `Env=dev|prod`
- `Owner=<team>`

---

## 11) 실행 우선순위 (추천)

지금 바로 시작 순서:

1. README 기준으로 아키텍처 확정
2. `infra/environments/dev` 먼저 구축
3. 앱 Dockerfile + ECR push + ECS 배포 자동화
4. CORS/인증/비밀관리 적용
5. 학습 데이터 저장을 S3+RDS로 전환

---

## 12) 현재 프로젝트에 바로 적용할 실무 메모

- `server/app.py`에서 추론 경로와 학습/파일관리 API를 장기적으로 분리 권장
  - `inference-api`
  - `data-api`
  - `training-worker`
- 확장 프로그램 `serverUrl`은 최종적으로 API Gateway 도메인으로 전환
- 로컬 EXE 배포 플로우는 개발/오프라인 모드로 유지 가능

---

## 13) 다음 문서화 대상 (후속)

이 문서 다음으로 만들면 좋은 운영 문서:

1. `RUNBOOK.md`: 장애 대응 절차(알람별 액션)
2. `SECURITY.md`: 인증/권한/키 회전 정책
3. `SLO.md`: 목표 지표와 에러 버짓
4. `MLOPS.md`: 데이터셋/모델 승격 기준

---

## 14) Additional Docs

- [RUNBOOK.md](./RUNBOOK.md): Incident response and alarm actions
- [SECURITY.md](./SECURITY.md): Authentication, authorization, and key rotation policy
- [SLO.md](./SLO.md): Service objectives and error budget policy
- [MLOPS.md](./MLOPS.md): Dataset and model promotion criteria
