# 아키텍처 변경 기록 및 설계 근거

이 문서는 Phase 0부터 Phase 4까지 진행된 모든 변경 사항과 그 설계 근거를 기록한다.

---

## 목차

1. [프로젝트 전체 구조 변화](#1-프로젝트-전체-구조-변화)
2. [Phase 0: 로컬 기반 보안·관측성 강화](#2-phase-0-로컬-기반-보안관측성-강화)
3. [Phase 1: AWS 최소 운영 인프라](#3-phase-1-aws-최소-운영-인프라)
4. [Phase 2: 클라우드 데이터 파이프라인](#4-phase-2-클라우드-데이터-파이프라인)
5. [설계 결정 요약](#5-설계-결정-요약)
6. [로컬 개발 vs 클라우드 동작 비교](#6-로컬-개발-vs-클라우드-동작-비교)
7. [Phase 3: Training Worker 분리 + 모델 버전 관리](#7-phase-3-training-worker-분리--모델-버전-관리)
8. [Phase 4: SLO 자동화 + CI/CD 완성](#8-phase-4-slo-자동화--cicd-완성)

---

## 1. 프로젝트 전체 구조 변화

### 초기 구조 (Phase 0 이전)

```
사용자 브라우저
  └── Chrome Extension
        └── 직접 HTTP 요청 → localhost:8000 (FastAPI)
                                  ├── 추론 (BERT 모델)
                                  ├── 학습 데이터 저장 (로컬 JSONL)
                                  └── 재학습 트리거 (동일 프로세스 내 스레드)
```

문제점:
- 인증 없음 → 외부에서 API 호출 가능
- 단일 프로세스에서 추론 + 학습 동시 실행 → 리소스 경합
- 학습 데이터가 로컬 디스크에만 존재 → 인스턴스 교체 시 데이터 소실
- 모델 파일도 로컬 디스크 → 다중 인스턴스 불가

### Phase 2 완료 후 구조

```
사용자 브라우저
  └── Chrome Extension
        └── HTTPS 요청
              └── API Gateway (HTTP API)
                    └── WAF (기본 규칙)
                          └── ALB
                                └── ECS Fargate (추론 API)
                                      ├── 학습 데이터 저장 → S3
                                      ├── 재학습 트리거 → SQS
                                      └── 메타데이터 기록 → RDS (PostgreSQL)
```

---

## 2. Phase 0: 로컬 기반 보안·관측성 강화

### 변경 파일

- `server/app.py`
- `server/Dockerfile`
- `server/.env.example`
- `extension/options.html`, `extension/background.js`, `extension/popup.js`

### 변경 내용과 근거

#### 2-1. Dockerfile 추가

**변경:** `server/Dockerfile` 생성, uvicorn 실행 인자와 환경변수(`PORT`, `LOG_LEVEL`, `HOST`) 외부 주입 구조로 변경.

**근거:** 클라우드 배포는 컨테이너 이미지 단위로 이루어진다. Python 직접 실행이나 EXE 방식은 AWS ECS에서 실행 불가. 이 시점에 컨테이너화하지 않으면 이후 모든 인프라 코드가 무의미해진다.

#### 2-2. API Key 인증 추가

**변경:** `ENFORCE_AUTH`, `API_KEY` 환경변수 기반 선택적 인증. `X-API-Key` 헤더 검증 미들웨어 추가. Chrome Extension에도 `X-API-Key` 헤더 연동.

**근거:** 서버를 공인 IP에 올리는 순간 누구나 `/predict`를 호출할 수 있다. 모델 추론은 CPU/메모리 집약적 연산이므로 무인증 상태로 공개하면 악용 즉시 비용 폭증. `ENFORCE_AUTH=false`를 기본값으로 유지한 이유는 로컬 개발 마찰을 없애기 위함.

#### 2-3. CORS 화이트리스트

**변경:** `ALLOWED_ORIGINS`, `ALLOWED_EXTENSION_IDS` 환경변수로 허용 오리진 명시. 와일드카드(`*`) 미사용.

**근거:** Chrome Extension의 오리진은 `chrome-extension://<id>` 형태. FastAPI CORS 미들웨어가 `chrome-extension://*`를 안전하게 매칭하지 못하기 때문에 extension ID를 명시적으로 전달해 `chrome-extension://<id>` 형태로 조합한다.

#### 2-4. 헬스체크 분리

**변경:** `/health/live`, `/health/ready` 추가. `/health`는 하위 호환 유지.

**근거:** ECS ALB 헬스체크는 단순 `200 OK` 여부만 본다. `/health/live`는 프로세스가 살아있는지만 확인하고, `/health/ready`는 모델이 실제로 로드되어 추론 가능한 상태인지를 반환한다. 로드 중 트래픽이 들어오면 503을 반환해 ALB가 해당 태스크로 라우팅하지 않도록 한다. 이 구분 없이 단일 `/health`만 쓰면 모델 로딩 중에도 요청을 받아 에러가 발생한다.

#### 2-5. Rate Limiter

**변경:** `InMemoryRateLimiter` 클래스 추가. `/predict`, `/training-data/lookup`, `/training-data` 경로별 분당 제한.

**근거:** API Gateway/WAF가 앞에 붙기 전에도 앱 레벨 방어가 필요하다. 특히 하나의 클라이언트가 반복 배치 요청으로 모델을 독점하는 상황을 막는다. 메모리 기반이므로 수평 확장 시 효력이 약해지지만, Phase 1에서는 단일 태스크 운영이 전제이므로 충분하다. Phase 3에서 Redis 기반으로 교체 예정.

#### 2-6. 트래픽 메트릭 수집

**변경:** `TrafficMetrics` 클래스 추가. `PREDICT_METRIC`, `TRAFFIC_SNAPSHOT` 구조화 로그 출력.

**근거:** CloudWatch Logs로 수집할 로그 포맷을 미리 JSON으로 통일한다. 이후 CloudWatch Logs Insights 쿼리로 p95 레이턴시, 배치 크기 분포, 상위 클라이언트를 분석 가능하게 한다. 프로메테우스 같은 외부 메트릭 서버 없이도 기본 운영 지표를 확보하는 것이 목표.

---

## 3. Phase 1: AWS 최소 운영 인프라

### 변경 파일

```
infra/
  modules/
    network/          # VPC, Subnet, NAT Gateway, Route Table
    ecr/              # ECR 리포지토리
    observability/    # CloudWatch Log Group
    ssm_parameters/   # SSM Parameter Store
    ecs_service/      # ECS Fargate + ALB + Security Group + IAM Role
    api_gateway/      # API Gateway HTTP API
    waf/              # WAF Web ACL
    github_oidc_roles/ # GitHub Actions용 OIDC IAM Role
  environments/
    dev/
      main.tf
      variables.tf
      terraform.tfvars
      backend.hcl
    prod/
      (골격만)
.github/workflows/
  terraform-infra.yml
  deploy-app.yml
```

### 변경 내용과 근거

#### 3-1. 네트워크 구조: Public + Private Subnet 분리

**변경:** VPC `10.40.0.0/16`, public subnet 2개 (ALB), private subnet 2개 (ECS, RDS), NAT Gateway.

**근거:**
- ECS 태스크는 외부에서 직접 접근 불가능한 private subnet에 배치한다. 외부 트래픽은 반드시 ALB를 경유하도록 강제.
- NAT Gateway는 ECS 태스크가 ECR에서 이미지를 pull하거나 AWS API를 호출할 때 필요하다. Internet Gateway 직접 연결보다 비용이 높지만 태스크에 공인 IP를 부여하지 않아도 된다.
- AZ를 `a`, `c` 두 개 사용한 이유: ALB는 최소 2개 AZ를 요구한다.

#### 3-2. ECS Fargate 선택

**변경:** ECS Fargate 서비스로 추론 API 운영.

**근거:**
- EC2 기반 ECS는 인스턴스 타입, AMI, OS 패치를 직접 관리해야 한다.
- Fargate는 컨테이너 실행 환경을 AWS가 관리. 운영 부담이 적고 태스크 단위 과금이라 저트래픽 서비스에서 경제적.
- 단점: cold start가 있고, GPU 워크로드는 EC2가 유리하다. 현재 추론은 CPU로 충분하므로 Fargate 선택.

#### 3-3. ALB → API Gateway 구조

**변경:** `Chrome Extension → API Gateway HTTP API → ALB → ECS` 구조.

**근거:**
- API Gateway가 앞단에 있으면 SSL 종료, throttling, usage plan, 로깅을 관리형으로 처리 가능.
- ALB는 내부 라우팅과 헬스체크 담당. API Gateway private integration (VPC Link)은 Phase 3 예정.
- 현재는 API Gateway → public ALB HTTP 연결이므로 ALB-ECS 구간 암호화는 없다. Phase 3에서 HTTPS + VPC Link로 전환 예정.

#### 3-4. WAF를 ALB에 붙인 이유

**변경:** `module "waf"` — ALB에 Web ACL 연결.

**근거:** API Gateway HTTP API는 WAF v2 연결에 Regional API가 필요하다. 현재 HTTP API(Regional)는 WAF 연결을 지원하지만 설정이 복잡하다. ALB에 먼저 붙이는 것이 Phase 1에서 방어층을 가장 빠르게 확보하는 방법.

#### 3-5. 비밀정보: SSM Parameter Store

**변경:** `API_KEY`, `DB_PASSWORD`를 SSM Parameter Store SecureString으로 저장. ECS task definition의 `secrets` 필드로 주입.

**근거:** 환경변수에 평문 비밀정보를 넣으면 ECS 콘솔이나 CloudTrail 로그에 노출될 수 있다. SSM SecureString은 KMS로 암호화된 상태로 저장되고, ECS가 태스크 시작 시 복호화해 컨테이너 내부에만 주입한다. 코드나 이미지에 하드코딩이 없으므로 이미지가 유출되어도 비밀정보는 안전.

#### 3-6. GitHub OIDC Role

**변경:** `infra/modules/github_oidc_roles` — GitHub Actions 전용 IAM Role, OIDC 신뢰 정책.

**근거:** GitHub Actions에서 AWS 작업을 수행할 때 Access Key ID + Secret를 GitHub Secrets에 저장하는 방식은 키 유출 위험이 있고 만료 관리가 번거롭다. OIDC를 쓰면 GitHub이 단기 토큰을 발급하고 AWS가 이를 검증해 Role을 assume하는 방식으로 장기 자격증명이 불필요해진다. `terraform apply`용 Role과 `docker push + ECS deploy`용 Role을 분리해 최소 권한 원칙을 지킨다.

#### 3-7. Terraform S3 Remote Backend

**변경:** `backend "s3" {}`, `backend.hcl`로 상태 파일을 S3에 저장.

**근거:** Terraform 상태 파일을 로컬에 두면 팀 협업 시 상태 충돌이 발생하고, 로컬 파일 손실 시 인프라를 관리할 수 없게 된다. S3 + DynamoDB lock은 Terraform의 표준 원격 백엔드 구성으로, 상태 파일 버전 관리와 동시 실행 잠금을 제공한다.

---

## 4. Phase 2: 클라우드 데이터 파이프라인

### 변경 파일 목록

```
infra/
  modules/
    s3/               # 신규: 학습 데이터 S3 버킷
    sqs/              # 신규: 비동기 학습 트리거 큐
    rds/              # 신규: PostgreSQL 메타데이터 DB
    ecs_service/
      outputs.tf      # 수정: task_role_name, task_role_arn, service_security_group_id 추가
  environments/
    dev/
      main.tf         # 수정: s3/sqs/rds 모듈 추가, ECS 환경변수 확장, IAM 정책 추가
      variables.tf    # 수정: db_password 변수 추가
      terraform.tfvars # 수정: db_password 값 추가
server/
  app.py              # 수정: S3/SQS/RDS 통합, 로컬 폴백 유지
  requirements.txt    # 수정: boto3, psycopg2-binary 추가
```

### 4-1. S3: 학습 데이터 저장소 전환

#### 구현 방식

**Terraform (`infra/modules/s3/main.tf`):**
```hcl
resource "aws_s3_bucket" "this" { ... }
resource "aws_s3_bucket_versioning" "this" { ... }          # 버전 관리 활성화
resource "aws_s3_bucket_server_side_encryption_configuration" { ... } # AES256 암호화
resource "aws_s3_bucket_public_access_block" { ... }        # 퍼블릭 접근 완전 차단
resource "aws_s3_bucket_lifecycle_configuration" { ... }    # training-data/ 365일 후 만료
```

버킷 이름: `ylcf-dev-training-data`
저장 경로 구조:
```
ylcf-dev-training-data/
  training-data/
    training_data_2026-03-23.jsonl   # 확정 학습 데이터
  training-temp/
    training_data_2026-03-23.jsonl   # 임시 클릭 라벨 캐시
```

**app.py (`_save_training_data_s3`):**
```python
def _save_training_data_s3(text, label, user_id, bucket, use_temp):
    s3 = boto3.client("s3")
    key = f"{'training-temp' if use_temp else 'training-data'}/training_data_{date_str}.jsonl"

    # 기존 파일 내용 읽기 (없으면 빈 바이트)
    existing = s3.get_object(Bucket=bucket, Key=key)["Body"].read()

    # 새 레코드를 뒤에 붙여서 덮어씌우기
    new_content = existing + (json.dumps(record) + "\n").encode("utf-8")
    s3.put_object(Bucket=bucket, Key=key, Body=new_content)
```

**실행 흐름:**
1. Chrome Extension이 댓글에 라벨을 붙임
2. `POST /training-data` 요청 → `save_training_data()` 호출
3. `TRAINING_DATA_BUCKET` 환경변수가 있으면 `_save_training_data_s3()` 실행
4. S3에서 오늘 날짜 파일을 읽고 새 줄을 붙여 다시 저장
5. 환경변수 없으면 기존 로컬 JSONL 파일 방식으로 폴백

**로컬 파일 방식을 버린 이유:**
- ECS 태스크는 stateless container. 재시작 또는 태스크 교체 시 로컬 디스크가 초기화된다.
- 수평 확장(desired_count > 1) 시 각 태스크가 다른 파일에 데이터를 쓰게 되어 데이터가 분산된다.
- S3는 모든 태스크가 동일한 저장소를 공유하므로 다중 인스턴스에서도 데이터가 통합된다.

**Append-only 방식을 선택한 이유:**
- S3는 네이티브 append를 지원하지 않는다. `get → append → put` 패턴이 표준.
- 날짜별로 파일을 분리하면 한 번의 put 크기가 작아 비용과 응답 시간이 낮다.
- 파일이 너무 커지면 학습 시 S3 Select나 prefix 필터로 특정 날짜 범위만 로딩 가능.

#### IAM 권한

ECS task role에 인라인 정책으로 부여:
```json
{
  "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:DeleteObject"],
  "Resource": ["arn:aws:s3:::ylcf-dev-training-data", "arn:aws:s3:::ylcf-dev-training-data/*"]
}
```

task role과 execution role을 분리한 이유:
- `execution role`: ECS 에이전트가 ECR pull, CloudWatch 로그 전송, SSM 비밀값 읽기에 사용. AWS 관리형 정책으로 충분.
- `task role`: 컨테이너 내 애플리케이션 코드가 AWS API를 호출할 때 사용. S3/SQS/RDS 같은 비즈니스 로직 권한은 여기에.

---

### 4-2. SQS: 비동기 학습 트리거

#### 구현 방식

**Terraform (`infra/modules/sqs/main.tf`):**
```hcl
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name}-dlq"
  message_retention_seconds = 1209600  # 14일
}

resource "aws_sqs_queue" "this" {
  name                       = var.name
  visibility_timeout_seconds = 900   # 15분 — 학습 작업 충분한 시간
  message_retention_seconds  = 86400 # 1일
  receive_wait_time_seconds  = 20    # long polling

  redrive_policy = {
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3  # 3번 실패하면 DLQ로
  }
}
```

큐 이름: `ylcf-dev-training-queue`
DLQ 이름: `ylcf-dev-training-queue-dlq`

**app.py (`_publish_training_job`, `/model/retrain`):**
```python
def _publish_training_job(queue_url, sample_count):
    sqs = boto3.client("sqs")
    message = json.dumps({
        "action": "retrain",
        "triggered_at": datetime.now().isoformat(),
        "sample_count": sample_count,
    })
    sqs.send_message(QueueUrl=queue_url, MessageBody=message)

@app.post("/model/retrain")
def start_retraining(background_tasks):
    # 현재 샘플 수 집계
    sample_count = count_local_samples()

    if BOTO3_AVAILABLE and SETTINGS.training_queue_url:
        _record_training_run(sample_count, triggered_by="api")  # RDS에 기록
        ok = _publish_training_job(SETTINGS.training_queue_url, sample_count)
        return {"success": ok, "message": "재학습 요청이 큐에 등록되었습니다 (async)"}

    # 로컬 폴백: 기존 스레드 방식
    background_tasks.add_task(run_training_background)
    return {"success": True, "message": "재학습이 시작되었습니다"}
```

**실행 흐름:**
1. 사용자가 `POST /model/retrain` 호출
2. `TRAINING_QUEUE_URL` 설정 시 → SQS에 메시지 발행 후 즉시 응답 반환
3. SQS 메시지를 소비하는 별도 Worker 컨테이너(Phase 3 구현 예정)가 실제 학습 수행
4. Worker가 3번 실패하면 메시지가 DLQ로 이동 → 알람 트리거 가능

**스레드 방식을 버린 이유:**
- 기존 방식은 추론 API 프로세스 내에서 학습 스레드가 실행된다. 학습 중 CPU/메모리를 추론과 경합.
- ECS Fargate 태스크 하나가 학습 + 추론을 동시에 하면 추론 레이턴시가 크게 증가한다.
- SQS 방식은 메시지를 발행하고 즉시 응답. 실제 학습은 별도 Worker가 담당하므로 추론 서비스에 영향 없음.

**Visibility Timeout을 900초(15분)로 설정한 이유:**
- Worker가 메시지를 받아 학습 완료까지 최대 시간의 여유를 주어야 한다.
- 이 시간 안에 완료하지 못하면 메시지가 다시 visible 상태로 돌아와 재처리된다.
- 학습 데이터가 적을 때 기준 10분 + 5분 여유 = 15분.

**DLQ를 붙인 이유:**
- Worker가 알 수 없는 이유로 계속 실패해도 메시지가 무한 재처리되지 않는다.
- DLQ에 메시지가 쌓이면 CloudWatch Alarm으로 팀에 알림 가능.
- 실패한 메시지를 직접 검사하고 원인 파악 후 재처리할 수 있다.

---

### 4-3. RDS PostgreSQL: 학습 메타데이터 저장

#### 구현 방식

**Terraform (`infra/modules/rds/main.tf`):**
```hcl
resource "aws_db_subnet_group" "this" {
  subnet_ids = var.subnet_ids  # private subnet 2개
}

resource "aws_security_group" "rds" {
  ingress {
    from_port       = 5432
    security_groups = [var.allowed_security_group_id]  # ECS service SG만 허용
  }
}

resource "aws_db_instance" "this" {
  engine         = "postgres"
  engine_version = "16.3"
  instance_class = "db.t4g.micro"
  storage_encrypted = true
  publicly_accessible = false
  db_subnet_group_name = aws_db_subnet_group.this.name
}
```

**app.py (`_ensure_training_runs_table`, `_record_training_run`):**
```python
# 서버 시작 시 테이블 자동 생성
def _ensure_training_runs_table():
    conn = _get_db_connection()
    cur.execute("""
        CREATE TABLE IF NOT EXISTS training_runs (
            id           SERIAL PRIMARY KEY,
            started_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            status       TEXT NOT NULL DEFAULT 'queued',
            sample_count INT,
            triggered_by TEXT
        )
    """)

# 재학습 트리거 시 기록
def _record_training_run(sample_count, triggered_by="api"):
    cur.execute(
        "INSERT INTO training_runs (status, sample_count, triggered_by) VALUES ('queued', %s, %s) RETURNING id",
        (sample_count, triggered_by)
    )
```

**실행 흐름:**
1. ECS 태스크 시작 → `_initialize_model()` → `_ensure_training_runs_table()` 순서로 실행
2. DB에 연결되면 `training_runs` 테이블이 없을 경우 자동 생성
3. `POST /model/retrain` 호출 시 `_record_training_run()` 실행 → 레코드 삽입
4. DB 연결 실패는 warning 로그만 남기고 서비스 중단 없이 계속 실행 (메타데이터 손실은 감수)

**RDS를 선택한 이유 (S3 JSONL과 역할 분리):**

| 저장소 | 저장 데이터 | 특성 |
|--------|------------|------|
| S3 | 실제 학습 데이터 (텍스트 + 라벨) | 대용량, append-only, 학습 시 일괄 로딩 |
| RDS | 학습 실행 메타데이터 | 소용량, 실시간 쿼리, 이력 조회·집계 필요 |

- "오늘 몇 건의 재학습이 트리거됐는가", "마지막 성공한 학습은 언제인가" 같은 쿼리는 RDBMS가 적합하다.
- S3에 메타데이터를 넣으면 집계 쿼리마다 파일 전체를 스캔해야 한다.

**`db.t4g.micro`를 선택한 이유:**
- dev 환경에서 메타데이터만 기록하므로 최소 스펙으로 충분.
- ARM 기반 T4g가 T3 대비 ~20% 저렴하다.
- prod 전환 시 `db.t4g.small` 이상으로 변경 권장.

**RDS를 private subnet에 배치한 이유:**
- DB는 외부에서 직접 접근 불가능해야 한다.
- Security Group으로 ECS service의 SG만 5432 포트 inbound 허용. 다른 모든 경로는 차단.
- 운영자가 직접 접속이 필요할 때는 Bastion Host 또는 AWS Systems Manager Session Manager 사용 권장.

---

### 4-4. ECS task role IAM 정책 분리

**변경:** `ecs_service` 모듈이 task role을 생성하지만 Phase 2 전까지 정책이 없었다. Phase 2에서 `infra/environments/dev/main.tf`에 인라인 정책을 추가.

**근거:** S3, SQS 권한을 `ecs_service` 모듈 내부에 하드코딩하면 모듈이 특정 버킷/큐에 종속된다. 대신 모듈이 `task_role_name`을 출력하고, 환경별 `main.tf`에서 필요한 권한만 붙이는 방식이 재사용성이 높다.

---

### 4-5. 로컬 폴백 설계

모든 Phase 2 기능은 환경변수가 없을 때 자동으로 기존 방식으로 동작한다.

```python
# S3 폴백
if _BOTO3_AVAILABLE and SETTINGS.training_data_bucket:
    return _save_training_data_s3(...)  # S3에 저장
# 없으면 로컬 파일

# SQS 폴백
if _BOTO3_AVAILABLE and SETTINGS.training_queue_url:
    return _publish_training_job(...)   # SQS 발행
# 없으면 background thread

# RDS 폴백
if not _PSYCOPG2_AVAILABLE or not SETTINGS.db_host:
    return None  # 무시하고 계속
```

**이 설계를 선택한 이유:**
- 로컬에서 `python app.py`로 실행할 때 boto3 / psycopg2가 없어도, AWS 자격증명이 없어도 동작한다.
- EXE 빌드(기존 Windows 배포용)도 환경변수 주입 없이 그대로 실행된다.
- 클라우드 환경에서는 ECS가 환경변수를 자동 주입하므로 코드 변경 없이 Phase 2 기능이 활성화된다.

---

## 5. 설계 결정 요약

| 결정 | 선택 | 대안 | 선택 근거 |
|------|------|------|-----------|
| 컴퓨트 | ECS Fargate | EC2, Lambda | OS 관리 불필요, CPU 추론에 적합 |
| 이미지 레지스트리 | ECR | Docker Hub | AWS 내부 네트워크로 빠르고 IAM 통합 |
| 학습 데이터 저장 | S3 | EFS, RDS | 대용량 비정형 데이터, 저비용 |
| 학습 트리거 | SQS | EventBridge, SNS | 단순 point-to-point 큐, DLQ 내장 |
| 메타데이터 | RDS PostgreSQL | DynamoDB, S3 | 집계 쿼리, 이력 조회에 RDBMS 적합 |
| 비밀정보 | SSM Parameter Store | Secrets Manager | 단순 문자열 비밀에 충분, 비용 낮음 |
| 인증 | API Key (X-API-Key) | JWT, Cognito | 단일 서비스 단순 인증에 적합 |
| WAF 위치 | ALB | API Gateway | Phase 1에서 빠른 방어층 확보 |
| CI 자격증명 | OIDC Role | Access Key | 장기 자격증명 불필요, 보안 우수 |
| Rate Limit | In-process (메모리) | Redis, API GW | Phase 1 단일 태스크 기준 충분 |

---

## 6. 로컬 개발 vs 클라우드 동작 비교

| 기능 | 로컬 (환경변수 없음) | 클라우드 (ECS + 환경변수 주입) |
|------|---------------------|-------------------------------|
| 학습 데이터 저장 | 로컬 JSONL 파일 | S3 JSONL 파일 |
| 임시 라벨 캐시 | 로컬 JSONL 파일 | S3 training-temp/ |
| 재학습 트리거 | FastAPI background thread | SQS SendMessage |
| 학습 실행 | 동일 프로세스 내 | 별도 Worker 컨테이너 (Phase 3) |
| 메타데이터 기록 | 없음 (무시) | RDS training_runs 테이블 |
| 인증 | 선택 (ENFORCE_AUTH=false) | 강제 (ENFORCE_AUTH=true) |
| 모델 경로 | `model/` 또는 `user_data/model/` | 컨테이너 이미지 내 번들 |

---

## 7. Phase 3: Training Worker 분리 + 모델 버전 관리

*구현 날짜: 2026-03-25*

### 7-1. 핵심 문제 — 추론/학습 CPU 경합

Phase 2까지 `app.py` 하나가 `/predict` 추론과 `/model/retrain` 학습을 동일 프로세스에서 처리했다. 재학습 요청이 들어오면 BERT 파인튜닝이 같은 0.5 vCPU를 차지해 추론 latency가 급등하는 구조였다.

SQS 큐는 Phase 2에서 이미 배포되었지만 메시지를 소비하는 Worker가 없었다 — 큐에 쌓기만 하고 아무도 읽지 않는 상태.

### 7-2. 구현 내용

**`server/worker.py` (신규)**

SQS 롱폴링(WaitTimeSeconds=20) Worker. 메시지 수신 시:
1. S3 `training-data/*.jsonl` 다운로드
2. `train.py`의 `train_model()` 호출 (기존 코드 재사용)
3. 성공 시 `s3://bucket/models/YYYYMMDD-HHMMSS/` 에 버전 업로드
4. RDS `training_runs` 테이블에 status/model_version/completed_at 기록
5. SQS 메시지 삭제

실패 시 SQS 메시지를 삭제하지 않는다 → visibility timeout 이후 자동으로 DLQ로 이동.

RDS 스키마는 worker가 기동 시 `ALTER TABLE ADD COLUMN IF NOT EXISTS`로 Phase 3 신규 컬럼(started_at, completed_at, model_version, error_message)을 추가한다.

**`infra/modules/ecs_worker/` (신규 Terraform 모듈)**

- ALB 없는 순수 Fargate 서비스 (outbound only)
- API와 동일한 이미지, CMD만 `["python", "/app/server/worker.py"]`로 오버라이드
- 전용 IAM Task Role: SQS Consume + S3 읽기/쓰기 (models/ 포함)
- 전용 CloudWatch Log Group: `/ecs/{name}-worker`
- Worker SG는 egress only — RDS ingress rule은 `dev/main.tf`에서 별도 추가

**`infra/environments/dev/main.tf` 변경**

- `module "ecs_worker"` 추가: cluster_id는 기존 API 클러스터 재사용, CPU 1024/Memory 2048 (BERT 학습용)
- `aws_vpc_security_group_ingress_rule.rds_from_worker`: Worker SG → RDS 5432 허용
- Terraform outputs에 `ecs_worker_service_name`, `worker_log_group_name` 추가

### 7-3. 아키텍처 변화

```
Phase 2 (이전)
───────────────
[/model/retrain 요청]
  → app.py (ECS Task)
      ├── SQS에 메시지 전송 (큐에 쌓이지만 소비자 없음)
      └── BackgroundTask로 즉시 학습 실행 ← 추론 CPU 경합 발생

Phase 3 (이후)
───────────────
[/model/retrain 요청]
  → app.py (ECS Task, 추론 전용)
      └── SQS에 메시지 전송만 (즉시 응답)

[SQS 큐]
  └── worker.py (별도 ECS Task)
        ├── S3에서 학습 데이터 다운로드
        ├── train_model() 실행
        ├── 완료 모델 → S3 models/{version}/
        └── RDS training_runs 업데이트
```

### 7-4. Phase 3 이후 기대 latency 개선

SLO.md Phase 2→3 전환 기준:

| 시나리오 | Phase 2 기준 | Phase 3 목표 | 근거 |
|---------|------------|------------|------|
| Baseline p95 | < 300ms | **< 200ms** | 추론 태스크가 학습 CPU 경합에서 해방 |
| Spike p95 | < 1500ms | **< 1000ms** | 동일 |
| Soak (100 VU, 30분) p95 | < 500ms | **< 300ms** | 동일 |

> 현재 Stage 3 Baseline p95 = 2,407ms. Worker 분리 후 재테스트 예정.

---

## 8. Phase 4: SLO 자동화 + CI/CD 완성

*구현 날짜: 2026-03-25*

### 8-1. CloudWatch Alarms (observability 모듈 확장)

`infra/modules/observability/main.tf`에 3개 알람 추가:

| 알람 이름 | 지표 | 임계값 | 의미 |
|---------|------|--------|------|
| `alb-5xx-high` | ALB HTTPCode_Target_5XX_Count | > 10 / 1분 | ECS 태스크 크래시 또는 내부 오류 |
| `ecs-running-tasks-zero` | ECS RunningTaskCount | < 1 / 2분 연속 | 서비스 완전 다운 |
| `training-dlq-not-empty` | SQS ApproximateNumberOfMessagesVisible (DLQ) | > 0 / 5분 | Worker 재학습 영구 실패 |

알람은 `enable_alarms = true` 시 생성. `sns_topic_arn`이 비어있으면 CloudWatch에만 표시 (알림 없음). SNS 토픽 연결은 prod 환경 설정 시 추가.

변수 추가: `alb_arn_suffix`, `ecs_cluster_name`, `ecs_service_name`, `sqs_dlq_name`, `sns_topic_arn`, `enable_alarms`.

### 8-2. GitHub Actions CI/CD 완성 (deploy-app.yml)

**변경 전**: API 이미지만 빌드/푸시, API ECS 서비스만 force redeploy.

**변경 후**:
1. 동일 이미지를 빌드 (API와 Worker는 같은 이미지, CMD만 다름)
2. API ECS 서비스 force redeploy
3. Worker ECS 서비스 force redeploy (`ECS_WORKER_SERVICE` 변수 설정 시)

GitHub Actions 환경 변수 추가 필요:
- `DEV_ECS_WORKER_SERVICE` = Terraform output `ecs_worker_service_name` 값
- `PROD_ECS_WORKER_SERVICE` = prod 환경 worker 서비스 이름 (prod 배포 시)

### 8-3. SQS DLQ 출력 추가

`infra/modules/sqs/outputs.tf`에 `dlq_name` 출력 추가. observability 모듈이 DLQ CloudWatch 알람 dimension으로 사용.

---

*최종 업데이트: 2026-03-25*

---

## 8. 비용 최적화 (Phase 2 후속)

### 8-1. NAT Gateway 제거

**변경:** `infra/modules/network/main.tf`에서 NAT Gateway 리소스 제거. ECS 서비스를 private subnet에서 public subnet으로 이동. `assign_public_ip = true` 설정.

**제거 이유:**
- NAT Gateway 비용: 고정 $0.059/시간 + 데이터 처리 $0.059/GB. 30일 기준 약 $42.5의 고정 비용.
- dev 환경에서 트래픽이 미미한 상황에서는 데이터 처리 비용도 사실상 무시 가능하므로, 대부분이 고정 비용.
- ECS 태스크가 ECR 이미지를 pull하거나 AWS API(S3, SQS, CloudWatch)를 호출할 때만 외부 통신이 필요한데, 공인 IP가 있으면 NAT 없이 직접 인터넷 게이트웨이로 나갈 수 있다.

**대안 구조:**
```
기존: ECS (private subnet) → NAT Gateway → Internet Gateway → AWS API / ECR
변경: ECS (public subnet, 공인 IP 할당) → Internet Gateway → AWS API / ECR
```

**보안 트레이드오프와 ALB SG 방어:**
- 공인 IP를 가진 ECS 태스크는 이론상 직접 접근 가능하지만, ALB Security Group이 이를 차단한다.
- ECS 태스크의 Security Group inbound 규칙: 오직 ALB SG에서 오는 8000 포트만 허용. 그 외 모든 inbound 차단.
- 따라서 태스크의 공인 IP:8000으로 직접 접근 시도해도 SG 레벨에서 드롭된다.
- 이 구조는 private subnet + NAT 방식과 보안 결과가 동일하다. 차이는 "네트워크 계층"으로 막느냐 "Security Group 계층"으로 막느냐다.

**NAT Gateway를 없애도 되는 이유 요약:**
| 보호 수단 | 위치 | 역할 |
|---------|------|------|
| ALB Security Group | ECS SG inbound 규칙 | 외부 → ECS 직접 접근 차단 |
| WAF | ALB 앞단 | 악성 HTTP 요청 차단 |
| API Gateway Throttling | API 레이어 | 요청 수 제한 |
| In-process Rate Limiter | 앱 레이어 | 클라이언트별 분당 요청 제한 |

NAT Gateway는 외부에서의 inbound를 막는 역할이 없다. inbound는 SG가 담당하고 NAT는 outbound 전용이다. outbound는 공인 IP + IGW로 대체 가능하다.

---

### 8-2. RDS 인스턴스 다운그레이드

**변경:** `db.t4g.micro` → `db.t2.micro`

**이유:**
- `db.t4g.micro`는 ARM 기반으로 가격이 낮지만, AWS 프리 티어 대상이 아니다.
- `db.t2.micro`는 AWS 프리 티어 대상 (12개월 무료, 이후 약 $12.41/월).
- dev 환경에서 RDS에 저장하는 데이터는 `training_runs` 테이블의 메타데이터뿐이다. 연결 수도 ECS 태스크 1~2개 수준이므로 db.t2.micro로 충분.
- 장기적으로는 Aurora Serverless v2로 교체 검토 (유휴 시 비용 0에 가까움).

---

### 8-3. 월 비용 변화

| 항목 | Phase 2 직후 | 최적화 후 | 절감 |
|------|------------|--------|------|
| NAT Gateway | ~$42.5 | $0 | -$42.5 |
| ECS Fargate (1 task) | ~$12 | ~$12 | - |
| ALB | ~$16 | ~$16 | - |
| RDS db.t4g.micro | ~$13 | $0 (t2.micro 프리티어) | -$13 |
| S3 | ~$1 | ~$1 | - |
| CloudWatch | ~$3 | ~$3 | - |
| API Gateway | ~$4 | ~$4 | - |
| **합계** | **~$91** | **~$36** | **-$55** |

> 프리 티어 종료 후 RDS db.t2.micro는 ~$12.41/월로 전환.

---

## 9. 부하 테스트 전략

### 왜 Phase 전환 전 부하 테스트가 필요한가

Phase 전환은 단순한 기능 추가가 아니라 인프라 구조 자체가 바뀌는 이벤트다. 코드 리뷰와 단위 테스트는 로직 오류는 잡을 수 있지만, 실제 트래픽 하에서의 병목은 발견할 수 없다.

예시:
- Phase 0 → 1 전환: 로컬 FastAPI와 ECS Fargate는 네트워크 경로, cold start 특성, ALB 헬스체크 타이밍이 전혀 다르다.
- Phase 1 → 2 전환: S3 저장 호출이 `/predict` 응답 시간에 영향을 줄 수 있다. 비동기로 분리했는지 반드시 확인 필요.
- Phase 2 → 3 전환: Training Worker 분리 후 추론 태스크의 CPU 여유가 늘어나 latency가 개선되어야 한다. 개선되지 않으면 분리가 의미 없다.

부하 테스트는 "이 구조가 의도한 대로 동작하는가"를 수치로 검증한다.

### Phase별 통과 기준 요약

| Phase 전환 | p95 Latency | 오류율 | 동시 사용자 (Soak) |
|-----------|-------------|--------|-----------------|
| Phase 0 → 1 | < 500ms | < 1% | 30 VU, 30분 |
| Phase 1 → 2 | < 300ms | < 0.5% | 50 VU, 30분 |
| Phase 2 → 3 | < 200ms | < 0.1% | 100 VU, 30분 |

세 가지 시나리오(Baseline, Spike, Soak) 모두 통과해야 Phase 전환이 승인된다.

### 자세한 내용

상세 시나리오 정의, k6 스크립트, CloudWatch Logs Insights 쿼리, 결과 기록 양식은 [LOAD_TESTING.md](./LOAD_TESTING.md)를 참조한다.
