# 재학습 + 추론 동시 시나리오 비교 결과

## 목적

**같은 4 vCPU 조건에서** Worker 분리 전/후 추론(predict) latency를 비교하여
SQS + 별도 ECS Worker라는 **구조 개선**의 실제 효과를 측정.

---

## 환경 구성

| 항목 | Stage 1 (4 vCPU) | Phase 3B (4 vCPU + Worker 분리) |
|------|-----------------|--------------------------------|
| 컴퓨팅 (API) | Docker 단일 컨테이너 (4 vCPU) | ECS Fargate (4 vCPU) |
| 재학습 처리 방식 | API 프로세스 내 **백그라운드 스레드** | **SQS → 별도 ECS Worker 태스크** (1 vCPU) |
| CPU 경합 여부 | 추론 + BERT fine-tuning이 4 vCPU 공유 | Worker ECS가 독립 CPU 사용, API는 추론 전용 |
| 엔드포인트 | http://localhost:8000 | https://2un7ms8dak.execute-api.ap-northeast-2.amazonaws.com |
| 재학습 응답 | 즉시 BERT fine-tuning 시작 (blocking background) | SQS 발행 후 즉시 반환 → Worker 비동기 처리 |
| 훈련 데이터 | 500샘플 (jsonl, 컨테이너 내부) | 500샘플 (S3) |

> **비교 변수**: Worker 분리 구조 하나만 다름. CPU는 동일하게 4 vCPU.

---

## 테스트 시나리오

| 항목 | 설정 |
|------|------|
| 스크립트 | `scripts/retrain_concurrent.js` |
| predict_load | 10 VU, 25분 지속 |
| retrain_ctrl | 5분 시점에 `/model/retrain` 1회 트리거 |
| 판정 기준 | predict p95 < 500ms |

---

## 측정 결과 (같은 4 vCPU)

| 지표 | Stage 1 — 백그라운드 스레드 | Phase 3B — Worker 분리 | 개선율 |
|------|:---:|:---:|:---:|
| p50 latency | 76 ms | **61 ms** | -19.7% |
| **p95 latency** | **866 ms** | **107 ms** | **-87.6%** |
| avg latency | 222 ms | 66 ms | -70.3% |
| max latency | 3,194 ms | 327 ms | -89.8% |
| **오류율** | **49.93%** | **0.00%** | **완전 해소** |
| 총 요청 수 | 15,422건 | 18,408건 | +19.4% |
| 재학습 트리거 | 1회 | 1회 | — |
| **통과 기준 (p95 < 500ms)** | **FAIL ✗** | **PASS ✓** | |

---

## 분석

### Stage 1 FAIL 원인 (4 vCPU, 백그라운드 스레드)

```
/model/retrain 호출
  └─ FastAPI background thread → BERT fine-tuning 시작
  └─ 동일 프로세스(4 vCPU)에서 추론 + 재학습 CPU 경합
  └─ BERT fine-tuning이 vCPU 대부분을 점유
  └─ 추론 latency p95=866ms, 오류율 49.93%
```

- 4 vCPU임에도 BERT 재학습이 추론 요청을 지연시킴
- 오류율 49.93%: CPU 포화로 인한 타임아웃 또는 503 응답
- 5분 이후(재학습 시작 후) latency 급등, 재학습 종료 후 복구

### Phase 3B PASS 원인 (4 vCPU + Worker 분리)

```
/model/retrain 호출
  └─ FastAPI → SQS 메시지 발행 (즉시 반환, ~5ms)
  └─ Worker ECS 태스크(독립 1 vCPU)가 SQS 롱폴링으로 수신
  └─ API ECS(4 vCPU)는 추론 전용 — 재학습과 CPU 분리
  └─ 재학습 중/후 p95=107ms 유지
```

- Worker가 완전히 별도 컨테이너에서 동작 → API CPU에 영향 없음
- 재학습 중에도 p95=107ms 안정 유지
- 오류율 0%: 재학습 전 구간에서 단 1건의 실패도 없음

---

## 결론

| 비교 항목 | 결론 |
|----------|------|
| CPU 조건 | **동일 — 4 vCPU** |
| 구조 차이 | 백그라운드 스레드 vs SQS + Worker ECS |
| p95 개선 | 866ms → 107ms (**-87.6%**) |
| 오류율 개선 | 49.93% → 0.00% (**완전 해소**) |
| SLO 달성 | Stage 1 **FAIL** → Phase 3B **PASS** |

**CPU를 4배 올려도 백그라운드 스레드 방식은 BERT 재학습 중 추론 latency 866ms, 오류율 50%를 기록한다.**
**Worker를 분리(SQS + 별도 ECS 태스크)하면 같은 4 vCPU에서 p95=107ms, 오류율 0%를 달성한다.**

구조 개선(Worker 분리)이 CPU 증설과 무관하게 재학습-추론 CPU 경합을 아키텍처적으로 해결하는 핵심임을 증명한다.

---

*테스트 날짜: 2026-03-26*
*테스터: 0206pdh*
*Stage 1 엔드포인트: http://localhost:8000 (Docker, 4 vCPU limit)*
*Phase 3B 엔드포인트: https://2un7ms8dak.execute-api.ap-northeast-2.amazonaws.com (ECS, 4 vCPU)*
