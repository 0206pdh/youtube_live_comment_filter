# 부하 테스트 결과: Phase 3 (Training Worker 분리 후)

## 테스트 환경

| 항목 | 값 |
|------|-----|
| 테스트 날짜 | 2026-03-25 |
| 엔드포인트 | https://lc6wslzqu6.execute-api.ap-northeast-2.amazonaws.com |
| 컴퓨팅 (API) | ECS Fargate (512 CPU / 1024 MiB) |
| 컴퓨팅 (Worker) | ECS Fargate (1024 CPU / 2048 MiB) — 신규 |
| 스토리지 | S3 (ylcf-dev-training-data) |
| DB | RDS PostgreSQL 16.13 (db.t3.micro) |
| 인증 | X-API-Key (SSM 주입) |
| 리전 | ap-northeast-2 |
| 변경사항 | Training Worker ECS 서비스 분리 (SQS consumer) |

---

## Baseline (10 VU, 5분)

| 지표 | Phase 3 (Worker 분리) | Stage 3 (Worker 없음) | 변화 |
|------|----------------------|----------------------|------|
| 총 요청 수 | 1,137 | 1,128 | +9 |
| p50 latency | 1,697 ms | 1,711 ms | **-14ms (-0.8%)** |
| p95 latency | 2,328 ms | 2,407 ms | **-79ms (-3.3%)** |
| p99 latency (max) | 2,665 ms | 2,660 ms | +5ms |
| avg latency | 1,641 ms | - | - |
| RPS | 3.79 | 3.76 | +0.03 |
| **HTTP 실패율** | **0.0%** | **0.0%** | 유지 |
| 통과 기준 (p95<500ms) | FAIL | FAIL | - |

> **결과 해석**: Worker 분리 후 p95가 2,407→2,328ms로 3.3% 소폭 개선됐지만 목표(200ms)에 크게 못 미친다.
> 이 테스트에서는 동시에 재학습이 진행되지 않아 Worker 분리의 직접적 CPU 해방 효과가 나타나지 않는다.
> 순수 BERT 추론 자체가 0.5 vCPU(512 CPU units) 기준으로 병목 — 이것이 latency의 근본 원인이다.

---

## Spike (0→100 VU, 3분)

| 지표 | Phase 3 (Worker 분리) | Stage 3 (Worker 없음) | 변화 |
|------|----------------------|----------------------|------|
| 총 요청 수 | 857 | 875 | -18 |
| p50 latency | 15,001 ms | 15,001 ms | 동일 |
| p95 latency | 15,001 ms | 15,001 ms | 동일 |
| p99 latency (max) | 15,056 ms | 15,001 ms | +55ms |
| **HTTP 실패율** | **95.1%** | **93.3%** | +1.8%p |
| 통과 기준 (p95<2000ms) | FAIL | FAIL | - |

> **결과 해석**: Spike에서 CPU 한계는 동일하다. 100VU 급증 시 0.5vCPU는 처리 불가 — Worker 분리와 무관하다.
> Worker 분리는 Spike 성능에 영향을 주지 않는다. ECS 태스크 수 증설 또는 CPU 상향이 필요하다.

---

## Soak (30 VU, 30분) — Phase 3 최초 측정

| 지표 | Phase 3 측정값 | 통과 기준 | 판정 |
|------|--------------|---------|------|
| 총 요청 수 | 7,107 | - | - |
| p50 latency | 7,066 ms | - | - |
| p90 latency | 8,893 ms | - | - |
| p95 latency | **9,469 ms** | < 800ms | **FAIL** |
| avg latency | 6,861 ms | - | - |
| min latency | 13 ms | - | - |
| max latency | 10,015 ms | - | - |
| RPS | 3.94 | - | - |
| HTTP 실패율 | **3.0%** | < 1% | **FAIL** |

> **결과 해석**:
> - 30 VU는 10 VU의 3배다. 0.5 vCPU에서 BERT 추론을 동시에 30개 처리하면 큐 대기가 폭발적으로 늘어난다.
> - HTTP 실패(3%)는 클라이언트 timeout(10s) 초과 — 응답이 10초를 넘어서 떨어진 것.
> - **메모리 누수 여부**: 30분 내내 요청이 처리되고 RPS가 일정(3.94)하게 유지됐다. 시간에 따른 급격한 latency 상승이 없으므로 메모리 누수는 없다고 판단.
> - SLO 통과 실패의 원인: 트래픽 규모(30VU) 대비 CPU 절대량 부족.

---

## Worker 분리 효과 분석

### 수치로 본 효과 (Baseline 기준)

| 지표 | Stage 3 | Phase 3 | 변화 |
|------|---------|---------|------|
| p50 | 1,711ms | 1,697ms | -0.8% |
| p95 | 2,407ms | 2,328ms | **-3.3%** |
| HTTP 실패율 | 0.0% | 0.0% | 유지 |

### 왜 개선이 미미한가

```
Phase 3 테스트 시 시나리오:
  [추론 요청] → API Task (0.5 vCPU) → BERT 추론
  [Worker] → 대기 중 (SQS 메시지 없음)

API Task의 0.5 vCPU를 추론이 100% 사용 — Worker와 경합 없음
→ 테스트 중 재학습 트리거가 없으므로 분리 효과 미측정
```

### Worker 분리가 실제로 필요한 시나리오

```
분리 전 (Stage 3):
  [/predict × 10 VU]  ┐
                       ├─ 0.5 vCPU 공유 → 추론 latency 급등
  [/model/retrain]    ┘

분리 후 (Phase 3):
  [/predict × 10 VU]   → API Task 0.5 vCPU (추론 전용)
  [/model/retrain]     → SQS 메시지 발행 후 즉시 반환
                       → Worker Task 1.0 vCPU (학습 전용)
```

재학습과 추론이 동시에 일어날 때 API latency 보호가 핵심 목적 — 이 테스트에서는 재현되지 않았다.

---

## 전체 판정 요약

| 시나리오 | 통과 기준 | Phase 3 결과 | 판정 |
|---------|---------|------------|------|
| Baseline p95 | < 500ms (현재), < 200ms (SLO Phase2→3) | 2,328ms | **FAIL** |
| Baseline HTTP 실패율 | < 1% | **0.0%** | **PASS** |
| Spike p95 | < 2,000ms | 15,001ms | **FAIL** |
| Soak p95 (30VU, 30분) | < 800ms | 9,469ms | **FAIL** |
| Soak 메모리 누수 없음 | latency 안정 | RPS 일정 유지 | **PASS** |

---

## 다음 latency 개선 방향 (Phase 3 → 4)

| 방법 | 예상 효과 | 비용 변화 |
|------|---------|---------|
| ECS API Task CPU 512→1024 (1 vCPU) | Baseline p95 ~50% 단축 예상 | +~$12/월 |
| ECS 태스크 2개 (desired_count=2) | Spike 오류율 감소 | +~$24/월 |
| BERT ONNX 변환 + 추론 최적화 | p50/p95 30~50% 단축 | 비용 변화 없음 |
| GPU 인스턴스 전환 | p95 < 100ms 가능 | 대폭 증가 |

> **즉시 적용 가능한 가장 저비용 개선**: `infra/environments/dev/main.tf`에서 ECS task CPU를 `512 → 1024`로 변경 후 terraform apply.

---

*테스트 날짜: 2026-03-25*
*테스터: 0206pdh*
