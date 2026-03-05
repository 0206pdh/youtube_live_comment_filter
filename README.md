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

