# 아키텍처 — 인프라 구조 (Infrastructure)

AWS 관리형 서비스 기반의 추론 API + 비동기 학습 파이프라인을 Terraform IaC로 구성한다.
로컬 단일 컨테이너(Stage 1)에서 시작해, 데이터 일관성 · CPU 경합 · 운영 가시성 문제를
단계적으로 해소한 결과가 현재 구조(Stage 3B)다.

관련 소스: `infra/`, `.github/workflows/`, `server/Dockerfile`

---

## 1. 큰 그림

```
                         [Chrome Extension]
                                | HTTPS
                                v
                    [API Gateway HTTP API]  ── stage throttling + CORS + access log
                                |  VPC Link
                                v
                         [WAF Web ACL]  ── AWS Managed Common Rule Set
                                |
                    [Internal ALB (2 AZ)]  ── health check: /health/ready
                                |
          +---------------------+---------------------+
          v                                           v
 [ECS Fargate: inference-api]              [ECS Fargate: retrain-worker]
   4 vCPU / 8 GiB, desired 2                  4 vCPU / 8 GiB, desired 1
   autoscale 2~15 (dev) / 2~100 (prod)        ALB 없음, egress-only
          |            |            |                  |          |
          v            v            v                  v          v
   [RDS PostgreSQL] [S3 bucket]  [SQS queue] <---------+     [S3 bucket]
    training_runs   training-data  + DLQ         consume      models/{version}/
                    models/                                   models/latest.json
          |
          v
   [CloudWatch]  logs + metrics + 5 alarms + dashboard
```

- Region: `ap-northeast-2`
- Terraform `>= 1.6`, AWS provider `~> 5.0`, S3 backend(+ DynamoDB lock)
- 모든 리소스 `default_tags` (Project / Env / Managed=terraform)

---

## 2. Terraform 레이아웃

```
infra/
  modules/
    network              VPC, subnet, IGW, route table, VPC endpoints
    ecr                  컨테이너 이미지 레지스트리
    ecs_service          ALB + TG + Listener + ECS 클러스터/서비스/태스크 + 오토스케일 + IAM
    ecs_worker           학습 Worker 전용 ECS 서비스 + IAM + 로그그룹
    rds                  PostgreSQL + subnet group + SG
    s3                   학습데이터/모델 버킷 (버저닝·암호화·라이프사이클)
    sqs                  학습 큐 + DLQ (redrive)
    api_gateway          HTTP API v2 + VPC Link + HTTP_PROXY 통합 + stage
    waf                  WAFv2 REGIONAL Web ACL + ALB association
    observability        CloudWatch alarms + dashboard
    ssm_parameters       SecureString 파라미터 (API_KEY, DB_PASSWORD)
    github_oidc_roles    GitHub Actions용 OIDC IAM 역할 (terraform / deploy)
  environments/
    dev                  10.40.0.0/16, 저비용 설정, force_destroy
    prod                 10.50.0.0/16, Multi-AZ, deletion_protection
  scripts/               대시보드 캡처 유틸
```

`environments/*/main.tf`가 모듈을 조립하고, 환경별 차이는 변수로만 조정한다.

---

## 3. 네트워크 (`modules/network`)

| 요소 | 내용 |
|---|---|
| VPC | dev `10.40.0.0/16` / prod `10.50.0.0/16`, DNS hostname/support on |
| AZ | `ap-northeast-2a`, `ap-northeast-2c` (2개) |
| Public subnet | `/24` x2 — 인터넷 대면 리소스용(현재 IGW 라우트만) |
| Private subnet | `/24` x2 — 내부 ALB, ECS 태스크, RDS, VPC endpoint |
| IGW | public route table `0.0.0.0/0` |
| Private route table | **NAT 없음** — AWS API 접근은 VPC endpoint로 처리 (NAT Gateway 상시비용 회피) |
| VPC endpoints (옵션) | Gateway: S3 / Interface: `ecs`, `ecr.api`, `ecr.dkr`, `kms`, `logs`, `ssm`, `sqs` |

> ECR 이미지 레이어는 S3에 저장되므로, private 서브넷에서 태스크가 뜨려면
> ECR interface 엔드포인트 + S3 gateway 엔드포인트가 함께 필요하다.

---

## 4. 추론 API — `modules/ecs_service`

### 4.1 로드밸런서 / 라우팅

| 리소스 | 설정 |
|---|---|
| ALB | `internal = true`, private subnet 2 AZ |
| Target Group | target_type `ip`, port 8000, health check `GET /health/ready` (200, healthy 2 / unhealthy 3, interval 30s) |
| Listener | HTTP :80 → forward TG |
| ALB SG | inbound :80 from `alb_ingress_cidrs`(VPC CIDR) — API Gateway VPC Link만 도달 |
| Service SG | inbound :8000 from **ALB SG만** |

### 4.2 태스크 / 서비스

| 항목 | dev | prod |
|---|---|---|
| CPU / Memory | 4096 (4 vCPU) / 8192 (8 GiB) | 동일 |
| desired_count | 2 | 2 |
| autoscaling min / max | 2 / 15 | 2 / 100 |
| CPU 타깃 추적 | 55% | 55% |
| 요청 타깃 추적 | `ALBRequestCountPerTarget` 800 | 동일 |
| 배포 min healthy / max | 100% / 200% (기존 태스크 유지한 채 신규 기동) | 동일 |
| circuit breaker | `rollback = true` | 동일 |
| health check grace | 300s | 300s |
| 이미지 | `:latest` (dev 단순화) | `:latest` (운영은 immutable SHA 권장) |

- `desired_count=2` + `min healthy 100%` → 롤링 모델 교체 중에도 기존 태스크가 계속 요청 처리.
- 환경변수로 rate limit / auth / CORS / S3·SQS·RDS 연결정보 주입.
  dev는 부하테스트 대상이라 rate limit을 사실상 무제한(`100000`)으로, prod는 `120/180/30`.
- 시크릿(`API_KEY`, `DB_PASSWORD`)은 SSM SecureString ARN → ECS `secrets`로 주입(평문 미포함).

### 4.3 IAM

- **execution role**: `AmazonECSTaskExecutionRolePolicy` + SSM `GetParameter(s)` (시크릿 조회, ECR pull, 로그).
- **task role**: 런타임 최소 권한 — S3(`Get/Put/List/Delete` 해당 버킷), SQS(`SendMessage`/`ReceiveMessage`/`DeleteMessage`/`GetQueueAttributes`).

---

## 5. 학습 Worker — `modules/ecs_worker`

| 항목 | 값 |
|---|---|
| 실행 | API와 **동일 이미지**, `command = ["python","/app/server/worker.py"]`로 override |
| 리소스 | 4 vCPU / 8 GiB |
| desired_count | 1 (단일 소비자 — 재학습은 순차 처리) |
| 네트워크 | ALB 없음, SG는 **egress-only** (SQS·S3·RDS 아웃바운드만) |
| 로그 | 별도 그룹 `/ecs/{name}-worker` |
| task role | S3 `Get/Put/Delete/List`, SQS `Receive/Delete/ChangeMessageVisibility/GetQueueAttributes`, **`ecs:UpdateService`/`ecs:DescribeServices` (API 서비스 대상)** |

RDS 접근은 RDS 모듈이 SG 하나만 받으므로, 환경 `main.tf`에서
`aws_vpc_security_group_ingress_rule`로 Worker SG를 5432 두 번째 허용 소스로 추가한다.

> **분리 이유**: BERT fine-tuning이 `/predict`와 CPU를 경합하지 않도록 프로세스·컨테이너·CPU를 완전히 격리.

---

## 6. 저장소 계층

### 6.1 S3 (`modules/s3`)

| 설정 | 값 |
|---|---|
| 버저닝 | Enabled |
| 암호화 | SSE-S3 (AES256) |
| public access | 4종 모두 block |
| 라이프사이클 | `training-data/` 접두사 만료 — dev 기본 / prod 365일 |
| force_destroy | dev `true` (클린 teardown) / prod `false` |

주요 키:
- `training-data/training_data_YYYY-MM-DD.jsonl` — 영구 학습 데이터
- `training-temp/...` — 임시 캐시 라벨
- `models/{version}/...` — 버전별 모델 아티팩트
- `models/latest.json` — 활성 모델 포인터

### 6.2 SQS (`modules/sqs`)

| 설정 | 값 |
|---|---|
| visibility timeout | 3600s (긴 학습 대응, Worker가 heartbeat로 연장) |
| long polling | `receive_wait_time_seconds = 20` |
| redrive | `maxReceiveCount` 초과 시 DLQ |
| DLQ 보존 | 14일 |

### 6.3 RDS PostgreSQL (`modules/rds`)

| 항목 | dev | prod |
|---|---|---|
| instance class | `db.t3.micro` | `db.t3.small` |
| engine | PostgreSQL 16.13 | 동일 |
| storage | gp3 20 GiB, encrypted, max 2x autoscale | gp3 50 GiB |
| Multi-AZ | false | **true** |
| backup 보존 | 7일 | 14일 |
| deletion protection | false | **true** |
| 접근 | private DB subnet group, `publicly_accessible = false`, SG 5432 from ECS(API+Worker) SG |

용도: `training_runs` 테이블(재학습 이력 감사). 이 규모에서는 SQL 집계 조회가 핵심이라 DynamoDB 대신 선택.

---

## 7. 엣지 / 보안

### 7.1 API Gateway (`modules/api_gateway`)

- HTTP API v2, `HTTP_PROXY` 통합, `ANY /` + `ANY /{proxy+}` 전 경로 프록시.
- **VPC Link** → 내부 ALB 리스너 (private 통합). VPC Link 전용 SG.
- stage: `auto_deploy`, `detailed_metrics_enabled`, throttling dev 2000/4000 · prod 8000/10000.
- CORS 설정, access log를 `/apigw/{name}` 로그그룹에 JSON 포맷으로 기록.
- 인증은 애플리케이션 레벨 `X-API-Key`(서버 `ENFORCE_AUTH=true`).

### 7.2 WAF (`modules/waf`)

- WAFv2 `REGIONAL` Web ACL을 ALB에 association.
- `AWSManagedRulesCommonRuleSet` (기본 시그니처).
- 옵션 IP rate-based rule (dev/prod 모두 현재 비활성 — 부하테스트/트래픽 특성 확인 후 활성 예정).

### 7.3 시크릿 (`modules/ssm_parameters`)

- `/{app}/api/API_KEY`, `/{app}/db/DB_PASSWORD` — SecureString.
- ECS `secrets`로만 주입, Terraform state/코드/이미지에 평문 없음.

---

## 8. 관측성 (`modules/observability`)

CloudWatch 로그그룹: `/ecs/{app}` (dev 30일 / prod 90일), `/ecs/{app}-worker`, `/apigw/{app}`.

알람 5종:

| 알람 | 조건 | 의미 |
|---|---|---|
| ALB 5xx high | `HTTPCode_Target_5XX_Count` > 10 / 1분 | 태스크 크래시·오류 |
| ECS running tasks zero | `RunningTaskCount` < 1, 2회 (missing=breaching) | 전체 장애 |
| Training DLQ not empty | DLQ `ApproximateNumberOfMessagesVisible` > 0 | 학습 잡 영구 실패 |
| ALB p95 latency high | `TargetResponseTime` p95 > 0.5s, 5분 중 3회 | 지연 SLO 위반 |
| API CPU high | ECS `CPUUtilization` > 80%, 5분 중 3회 | 용량 부족 |

CloudWatch 대시보드: API latency/요청량, 4xx/5xx, API·Worker CPU/메모리, 큐/DLQ 깊이,
최근 애플리케이션 에러 로그(Insights 쿼리).

---

## 9. CI/CD (`.github/workflows/`)

인증은 전부 **GitHub OIDC → IAM 역할 AssumeRole** (장기 액세스 키 없음, `modules/github_oidc_roles`).

### 9.1 `terraform-infra.yml`

| 트리거 | 동작 |
|---|---|
| PR (`infra/**`) | dev fmt → init(`-backend=false`) → validate → plan |
| push main | dev `apply -auto-approve` |
| workflow_dispatch (prod) | prod `apply -auto-approve` |

### 9.2 `deploy-app.yml`

| 트리거 | 동작 |
|---|---|
| push main (`server/**`) | dev 배포 |
| workflow_dispatch (prod) | prod 배포 |

배포 스텝:
1. `server/Dockerfile`로 **단일 이미지** 빌드 → ECR에 `:{git-sha}` + `:latest` push.
2. API 서비스 `aws ecs update-service --force-new-deployment`.
3. Worker 서비스도 동일하게 강제 재배포 (`ECS_WORKER_SERVICE` 설정 시).

→ API와 Worker가 항상 같은 코드/모델 번들 이미지를 사용.

---

## 10. 환경 차이 요약

| 항목 | dev | prod |
|---|---|---|
| VPC CIDR | 10.40.0.0/16 | 10.50.0.0/16 |
| API autoscale max | 15 (계정 Fargate vCPU 한도 내) | 100 |
| RDS | db.t3.micro, single-AZ, 스냅샷 skip | db.t3.small, Multi-AZ, deletion protection |
| S3 | force_destroy, 짧은 보존 | 보존 365일, 삭제 방지 |
| API Gateway throttle | 2000 / 4000 | 8000 / 10000 |
| rate limit(env) | 사실상 무제한(부하테스트) | 120 / 180 / 30 |
| 로그 보존 | 30일 | 90일 |

> 현재 AWS 리소스는 비용 절감을 위해 `terraform destroy` 상태.
> 재배포는 `infra/environments/dev`에서 `terraform init` + `apply`.
> 수동 유지 리소스: tfstate S3 버킷, DynamoDB lock 테이블, IAM OIDC Provider.
