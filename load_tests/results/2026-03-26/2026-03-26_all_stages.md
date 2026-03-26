# 부하 테스트 결과: 전체 재측정 (2026-03-26)

## 변경 사항

| 항목 | Phase 3 (이전) | Stage 3B (이번) |
|------|--------------|----------------|
| ECS API CPU | 512 (0.5 vCPU) | **4096 (4 vCPU)** |
| ECS API Memory | 1024 MiB | **8192 MiB (8 GiB)** |
| ECS Worker CPU | 1024 (1 vCPU) | 1024 (1 vCPU, 동일) |
| 기타 구조 | — | 변경 없음 |

---

## 테스트 환경

| 항목 | Stage 1 | Stage 2 | Stage 3B |
|------|---------|---------|----------|
| 컴퓨팅 | 단일 Docker (로컬) | Docker 2개 + nginx (로컬) | ECS Fargate 4 vCPU / 8 GiB |
| 스토리지 | 로컬 볼륨 | 로컬 볼륨 (각자) | S3 |
| DB | 없음 | 없음 | RDS PostgreSQL 16 (t3.micro) |
| Rate Limit | 300/min (활성화) | 비활성화 | API Gateway → ALB |
| 엔드포인트 | http://localhost:8000 | http://localhost:8080 | https://2un7ms8dak.execute-api.ap-northeast-2.amazonaws.com |

---

## Baseline (10 VU, 5분)

| 지표 | Stage 1 | Stage 2 | Stage 3B |
|------|---------|---------|---------  |
| 총 요청 수 | 2,457 | 2,393 | 2,822 |
| p50 latency | 171 ms | 224 ms | **59 ms** |
| p90 latency | 514 ms | 340 ms | **84 ms** |
| p95 latency | 623 ms | 361 ms | **97 ms** |
| avg latency | 231 ms | 246 ms | **64 ms** |
| max latency | 6,398 ms | 3,941 ms | 330 ms |
| RPS | 8.16 | 7.94 | **9.37** |
| HTTP 실패율 | 38.5%* | **0.0%** | **0.0%** |
| 통과 기준 (p95<500ms) | FAIL | **PASS** | **PASS** |

> \* Stage 1 HTTP 실패: Rate Limit 초과 (300/min)로 인한 429 응답. BERT 추론 속도 향상으로 RPS가 높아져 rate limit에 걸림.
> Stage 1 성공 응답(200) 기준 p95=721ms.

---

## Spike (0→100 VU, 3분)

| 지표 | Stage 1 | Stage 2 | Stage 3B |
|------|---------|---------|---------  |
| 총 요청 수 | 33,811 | 2,431 | 5,665 |
| p50 latency | 35 ms | 5,668 ms | 2,310 ms |
| p95 latency | 210 ms | **9,587 ms** | 3,345 ms |
| avg latency | 257 ms | 5,001 ms | 2,039 ms |
| max latency | 15,062 ms | 15,061 ms | **4,010 ms** |
| RPS | 187.6 | 13.48 | **31.46** |
| HTTP 실패율 | 97.4%* | 0.6% | **0.0%** |
| error_rate | **0.6%** | **0.6%** | **0.0%** |
| 통과 기준 (p95<2000ms) | PASS* | FAIL | FAIL |

> \* Stage 1 Spike: 97.4%는 모두 429 (Rate Limit). 5xx 없음. error_rate(checks 기준)는 0.6% PASS.
> Stage 1 Spike p95 210ms는 429 포함 전체 기준 — 실제 BERT 처리 요청은 일부.
> Stage 3B max=4,010ms: 이전 Phase 3 max=15,001ms 대비 73% 감소. 15초 타임아웃 완전 해소.

---

## Soak (30 VU, 30분) — Stage 3B 측정

| 지표 | Phase 3 (0.5 vCPU) | Stage 3B (4 vCPU) | 변화 |
|------|-------------------|------------------|------|
| 총 요청 수 | 7,107 | **55,921** | +686% |
| p50 latency | 7,066 ms | **190 ms** | **-97.3%** |
| p90 latency | 8,893 ms | **372 ms** | **-95.8%** |
| p95 latency | 9,469 ms | **431 ms** | **-95.4%** |
| avg latency | 6,861 ms | **215 ms** | **-96.9%** |
| max latency | 10,015 ms | 2,367 ms | -76.4% |
| RPS | 3.94 | **31.04** | +688% |
| HTTP 실패율 | 3.0% | **0.004%** | -99.9% |
| 메모리 누수 | 없음 | **없음** | 유지 |
| 통과 기준 (p95<800ms) | **FAIL** | **PASS** | **개선** |

---

## 데이터 일관성 (Stage 2)

| 지표 | Stage 2 (로컬) | Stage 3B (S3/RDS) |
|------|--------------|------------------|
| 조회 총 횟수 | 1,845 | S3/RDS 중앙화 → 불일치 없음 |
| 불일치(miss) 횟수 | **1,845** | 0 |
| 불일치율 | **100.0% (문제 재현 성공)** | **0% (아키텍처 보장)** |

---

## 전체 판정 요약

### Stage 3B 기준

| 시나리오 | 통과 기준 | Stage 3B 실측 | 판정 |
|---------|---------|-------------|------|
| Baseline p95 | < 500ms | **97 ms** | **PASS** |
| Baseline HTTP 실패율 | < 1% | **0.0%** | **PASS** |
| Spike p95 | < 2,000ms | 3,345 ms | FAIL |
| Spike HTTP 실패율 | < 5% | **0.0%** | **PASS** |
| Soak p95 (30VU, 30분) | < 800ms | **431 ms** | **PASS** |
| Soak HTTP 실패율 | < 1% | **0.004%** | **PASS** |
| 메모리 누수 없음 | RPS 안정 | **31 RPS 일정** | **PASS** |

---

## Phase 3 (0.5 vCPU) vs Stage 3B (4 vCPU) 비교

| 시나리오 | Phase 3 | Stage 3B | 개선율 |
|---------|---------|---------|-------|
| Baseline p95 | 2,328 ms | **97 ms** | **-95.8%** |
| Spike p95 | 15,001 ms | 3,345 ms | **-77.7%** |
| Spike HTTP 실패율 | 95.1% | **0.0%** | 완전 해소 |
| Soak p95 | 9,469 ms | **431 ms** | **-95.4%** |
| Soak HTTP 실패율 | 3.0% | **0.004%** | -99.9% |
| Soak RPS | 3.94 | **31.04** | +688% |

---

## Spike FAIL 원인 분석

Stage 3B Spike에서 p95=3,345ms로 목표(2,000ms)에 미달한 원인:

```
100 VU 동시 요청 → API Gateway → ALB → ECS 단일 태스크(1개)
  └─ 100개 동시 BERT 추론 요청을 4 vCPU가 순차 처리
  └─ 큐 대기 시간 증가 → p95=3.3초

해결 방법:
  1. ECS desired_count=2~4 (태스크 수평 확장) → Spike 오류율 감소
  2. ALB target group에 multiple tasks 분산
  3. BERT ONNX 변환으로 단일 추론 속도 개선
```

4 vCPU는 Baseline/Soak에서 충분하지만, 100 VU 동시 Spike에서는 태스크 수 확장이 필요하다.
max=4,010ms (이전 15,001ms → 73% 감소)로 15초 타임아웃은 완전 해소됨.

---

## 다음 단계 (Stage 4)

| 방법 | 예상 효과 | 비용 변화 |
|------|---------|---------  |
| ECS desired_count=2~4 | Spike p95 50% 단축 | +~$0.28/시간/태스크 |
| BERT ONNX 변환 | 단일 추론 속도 30~50% 개선, 비용 절감 | 없음 |
| ECS Auto Scaling (CPU 기반) | Spike 자동 대응 | 사용량 기반 과금 |

> **즉시 적용**: `infra/environments/dev/main.tf`에서 `desired_count = 2`로 변경 후 terraform apply.

---

*테스트 날짜: 2026-03-26*
*테스터: 0206pdh*
*엔드포인트: https://2un7ms8dak.execute-api.ap-northeast-2.amazonaws.com*
