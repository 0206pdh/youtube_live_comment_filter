# PROJECT OVERVIEW — youtube_live_comment_filter

이 문서는 프로젝트 전체를 한 곳에서 파악할 수 있도록 (1) 프로젝트 개요, (2) 아키텍처 구현, (3) 정량적 개선 결과를 정리한다. 각 항목의 상세 근거는 하단 [참고 문서](#6-참고-문서) 원문을 확인한다.

## 목차

1. [프로젝트 개요](#1-프로젝트-개요)
2. [시스템 구성 요소](#2-시스템-구성-요소)
3. [아키텍처 진화 — Stage 1 → Stage 3B](#3-아키텍처-진화--stage-1--stage-3b)
4. [핵심 인프라 선택 근거](#4-핵심-인프라-선택-근거)
5. [정량적 개선 결과](#5-정량적-개선-결과)
6. [참고 문서](#6-참고-문서)

---

## 1. 프로젝트 개요

**youtube_live_comment_filter**는 유튜브 라이브 채팅에서 욕설/혐오 표현을 실시간으로 분류하고 차단하는 서비스다. Chrome 확장 프로그램이 채팅 텍스트를 수집해 서버의 BERT 기반 분류 모델에 전달하고, 응답 라벨(`normal` / `borderline_abusive` / `abusive`)에 따라 화면에서 댓글을 필터링한다. 사용자가 남긴 라벨 피드백은 학습 데이터로 누적되어 모델 재학습에 사용된다.

프로젝트는 로컬 단일 프로세스 구조(Stage 1)에서 시작해, AWS 관리형 인프라(ECS Fargate + S3 + RDS + SQS + API Gateway) 기반 구조(Stage 3B)까지 단계적으로 고도화되었다. 각 단계는 실제 부하 테스트로 문제를 재현하고, 구조 변경 후 같은 조건에서 재측정하여 개선 효과를 정량적으로 검증하는 방식으로 진행했다.

**핵심 지표 요약** (Baseline 10 VU 기준, Stage 1 → Stage 3B):

| 지표 | Stage 1 | Stage 3B | 개선율 |
|------|---------|----------|--------|
| p95 latency | 2,979 ms | **97 ms** | **-96.7%** |
| HTTP 실패율 | 0.7% | **0.0%** | 완전 해소 |
| 데이터 불일치율 (스케일아웃 시) | 100% | **0%** | 아키텍처적 보장 |
| 재학습 중 추론 오류율 (동일 4 vCPU) | 49.93% | **0.00%** | 완전 해소 |

## 2. 시스템 구성 요소

```text
extension/   Chrome 확장 프로그램 (Manifest V3)
             - content.js    : YouTube 라이브 채팅 DOM에서 댓글 수집·차단 적용
             - background.js : 서버 API 호출, 설정 동기화
             - popup / options: 필터 on/off, 서버 URL·API Key 설정

server/      FastAPI 백엔드
             - app.py   (1,665 lines) : 추론 API, 학습데이터 CRUD, 인증/rate limit, 헬스체크
             - worker.py  (282 lines) : SQS 폴링 기반 재학습 Worker (API 프로세스와 분리)
             - train.py   (256 lines) : BERT fine-tuning 파이프라인

model/       기본 분류 모델 아티팩트 (배포 시 S3 최신 모델로 교체 가능)

infra/       Terraform IaC
             - modules/  : network, ecr, ecs_service, ecs_worker, rds, s3, sqs,
                            api_gateway, waf, observability, ssm_parameters, github_oidc_roles
             - environments/dev, environments/prod

load_tests/  k6 부하 테스트 스크립트 및 Stage별 측정 리포트
test/        모델 검증/역번역 증강 스크립트
```

주요 API 엔드포인트 (`server/app.py`):

| 엔드포인트 | 용도 |
|---|---|
| `POST /predict` | 댓글 텍스트 배치 분류 (핵심 추론 경로) |
| `POST /training-data`, `/training-data/lookup` | 라벨 피드백 저장·조회 |
| `POST /model/retrain` | 재학습 트리거 (SQS 발행 후 즉시 반환) |
| `POST /model/reload` | 최신 모델 재적재 |
| `GET /health/live`, `/health/ready` | liveness/readiness 헬스체크 |
| `GET /metrics/live` | 실시간 트래픽 계측 스냅샷 |

## 3. 아키텍처 진화 — Stage 1 → Stage 3B

| 항목 | Stage 1 | Stage 2 | Stage 3 (Phase 3) | Stage 3B |
|------|---------|---------|-------------------|----------|
| 컴퓨팅 (API) | 단일 Docker (로컬) | Docker 2개 + nginx (로컬) | ECS Fargate 0.5 vCPU | **ECS Fargate 4 vCPU** |
| 스토리지 | 로컬 파일시스템 | 로컬 파일시스템 (각자) | S3 | S3 |
| DB | 없음 | 없음 | RDS PostgreSQL | RDS PostgreSQL |
| 재학습 처리 | 백그라운드 스레드 (API CPU 경합) | 백그라운드 스레드 (API CPU 경합) | **SQS + Worker ECS** (독립 1 vCPU) | SQS + Worker ECS (독립 1 vCPU) |
| 스케일 아웃 | 불가 | 가능 (but 데이터 불일치) | 가능 (데이터 일관성 보장) | 가능 (데이터 일관성 보장) |

### Stage 1의 구조적 문제 (고도화 동기)

1. **단일 장애점**: 컨테이너 1개가 유일한 서버 — 재시작/OOM 시 전체 서비스 중단
2. **데이터 소실 위험**: 학습 데이터·모델 파일이 컨테이너 로컬 볼륨 → 재배포 시 영구 소실
3. **스케일아웃 시 데이터 불일치**: 컨테이너 2개 + 로컬 저장 → 조회 불일치율 100% 실측
4. **추론·재학습 CPU 경합**: `/model/retrain`이 API 프로세스 내 백그라운드 스레드로 실행 → 재학습 중 추론 오류율 49.93%
5. **운영 가시성 없음**: 로그/메트릭/알람/IaC 부재로 장애 감지·재현 불가

### 논리 아키텍처 (현재 목표 구조)

```text
[Chrome Extension]
    |
    v
[API Gateway (Usage Plan/Rate Limit) + WAF]
    |
    v
[ALB] -> [ECS Fargate: inference-api] --logs/metrics--> [CloudWatch]
              |
              +--metadata (피드백/재학습 이력)--> [RDS PostgreSQL]
              |
              +--raw data / model artifacts--> [S3]
              |
              +--재학습 요청(즉시 반환)--> [SQS] --> [ECS Worker: BERT fine-tuning]
                                                          |
                                                          +--> S3 모델 업로드 / RDS 결과 기록

[CI/CD (GitHub Actions, OIDC)] -> ECR Push -> Terraform Apply -> ECS Deploy
```

## 4. 핵심 인프라 선택 근거

| 결정 | 대안 | 채택 이유 |
|---|---|---|
| **ECS Fargate** | EC2 | OS/Docker 엔진 관리 불필요, 태스크 단위 독립 스케일아웃(API/Worker 분리), Terraform IaC 범위 단순, 소규모 기준 EC2 대비 저비용 |
| **ECS Fargate** | Lambda | BERT 모델 로드(수 초) 콜드스타트 문제, fine-tuning 15~30분이 Lambda 15분 제한 초과, 상시 메모리 상주로 즉시 응답 필요 |
| **S3** | EFS | 마운트 상시 비용 없음, 대용량 모델 바이너리 버전 관리 용이(`models/{version}/`), 99.999999999% 내구성 |
| **RDS PostgreSQL** | DynamoDB | 재학습 이력·피드백 통계 등 SQL 집계/조회가 핵심 요구사항 — 이 규모에서 NoSQL 확장성 이점 불필요 |
| **SQS + Worker ECS 분리** | FastAPI BackgroundTasks (기존) | 같은 프로세스 스레드 방식은 CPU를 아무리 늘려도 추론과 경합 → 재학습 중 오류율 50% 재현. SQS로 완전한 프로세스/CPU 격리 확보 |
| **SQS** | SNS | 재학습은 단일 Worker가 순서대로 처리해야 하므로 Pub/Sub이 아닌 큐 모델이 적합. DLQ로 실패 메시지 보존, at-least-once 재시도 |
| **API Gateway** | ALB 직접 노출 | Usage Plan 기반 API Key 별 quota/throttle, 인증 오프로드(Lambda Authorizer/Cognito 확장 가능), CloudWatch 자동 연동 |

## 5. 정량적 개선 결과

> 측정 방식: k6 부하 테스트(Baseline/Spike/Soak) — 최초 측정 2026-03-25, 재측정(Stage 3B) 2026-03-26. 상세 원본 수치는 [`load_tests/COMPARISON.md`](./load_tests/COMPARISON.md) 참조.

### 5.1 Baseline (10 VU, 5분)

| 지표 | Stage 1 | Stage 2 | Stage 3 (0.5 vCPU) | Stage 3B (4 vCPU) |
|------|---------|---------|--------------------|-------------------|
| p50 latency | 818 ms | 255 ms | 1,711 ms | **59 ms** |
| p95 latency | 2,979 ms | 2,254 ms | 2,407 ms | **97 ms** |
| HTTP 실패율 | 0.7% | 0.0% | 0.0% | **0.0%** |
| RPS | 4.61 | 6.41 | 3.76 | **9.37** |
| 판정 (p95<500ms) | FAIL | FAIL | FAIL | **PASS** |

### 5.2 Spike (0→100 VU, 3분)

| 지표 | Stage 1 | Stage 2 | Stage 3 (0.5 vCPU) | Stage 3B (4 vCPU) |
|------|---------|---------|--------------------|-------------------|
| p95 latency (피크) | 15,016 ms | 15,005 ms | 15,001 ms | **3,345 ms** |
| 오류율 (피크) | 81.9% | 67.3% | 93.3% | **0.0%** |
| 판정 (p95<2000ms) | FAIL | FAIL | FAIL | FAIL (단일 태스크 한계 — `desired_count=2` 필요) |

### 5.3 Soak (30 VU, 30분) — Phase 3(0.5 vCPU) vs Stage 3B(4 vCPU)

| 지표 | Phase 3 | Stage 3B | 변화 |
|------|---------|----------|------|
| 총 요청 수 | 7,107 | **55,921** | +686% |
| p50 latency | 7,066 ms | **190 ms** | -97.3% |
| p95 latency | 9,469 ms | **431 ms** | -95.4% |
| RPS | 3.94 | **31.04** | +688% |
| HTTP 실패율 | 3.0% | **0.004%** | -99.9% |
| 판정 (p95<800ms) | FAIL | **PASS** | 개선 |

### 5.4 데이터 일관성 (스케일아웃 시)

| 지표 | Stage 2 (로컬 파일) | Stage 3B (S3/RDS) |
|------|--------------------|--------------------|
| 조회 불일치율 | **100.0%** (nginx 라운드로빈 write/read 분산 → 로컬 상태 미스) | **0%** (중앙 저장소로 아키텍처적 보장) |

### 5.5 재학습 + 추론 동시 처리 (동일 4 vCPU 조건 — 구조 개선 순수 효과)

Stage 1(백그라운드 스레드)과 Phase 3B(Worker 분리)를 **같은 4 vCPU**에서 비교 — CPU 증설이 아닌 구조 변경만의 효과를 분리 측정.

| 지표 | Stage 1 (백그라운드 스레드) | Phase 3B (Worker 분리) | 개선율 |
|------|:---:|:---:|:---:|
| p95 latency | 866 ms | **107 ms** | **-87.6%** |
| avg latency | 222 ms | 66 ms | -70.3% |
| 오류율 | **49.93%** | **0.00%** | 완전 해소 |
| 판정 (p95<500ms) | FAIL | **PASS** | |

**해석**: vCPU를 4개로 늘려도 추론과 재학습이 같은 프로세스에서 경합하면 오류율 50%가 그대로 발생한다. 즉 이 문제는 컴퓨팅 증설이 아니라 SQS+Worker 분리라는 **구조 변경**으로만 해결된다.

### 5.6 단계별 해결된 문제 요약

| 고도화 단계 | 해결된 문제 | 핵심 수치 |
|-----------|-----------|---------|
| Stage 2 (컨테이너 2개) | CPU 처리량 증가 | p50 818ms → 255ms (-68.8%) |
| Stage 3 (ECS + S3 + RDS) | 데이터 불일치 / 데이터 소실 | 불일치율 100% → 0% |
| Phase 3 (SQS + Worker 분리) | 재학습/추론 CPU 경합 | 재학습 중 오류율 49.93% → 0% |
| Stage 3B (4 vCPU) | 추론 자체 CPU 부족 | Baseline p95 2,407ms → 97ms (-95.8%) |

### 5.7 남은 과제 (Stage 4)

Spike 시나리오 p95=3,345ms가 목표(2,000ms)를 미달 — 원인은 100 VU를 단일 ECS 태스크가 처리하는 구조적 한계. `desired_count=2` 이상으로 태스크를 늘리면 해결 가능하며, `infra/environments/dev/main.tf`에서 즉시 적용 가능한 상태다.

## 6. 참고 문서

| 문서 | 내용 |
|---|---|
| [`MLOPS.md`](./MLOPS.md) | 데이터셋/모델 버전 관리, 승격 게이트, 롤백 정책 |
| [`SLO.md`](./SLO.md) | 목표 지표, Phase 전환 부하테스트 게이트, 에러 버짓 정책 |
| [`LOAD_TESTING.md`](./LOAD_TESTING.md) | k6 스크립트, 실행 방법, CloudWatch 쿼리 |
| [`load_tests/COMPARISON.md`](./load_tests/COMPARISON.md) | Stage별 측정 원본 수치 및 근거 |
| [`RUNBOOK.md`](./RUNBOOK.md) | 장애 대응 절차 |
| [`SECURITY.md`](./SECURITY.md) | 인증/권한/키 회전 정책 |
| [`DEPLOYMENT.md`](./DEPLOYMENT.md) | 배포 절차 |
| [`README.md`](./README.md) | Phase별 실행 가이드, Terraform 준비 절차 상세 |
