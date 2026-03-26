# 재학습 + 추론 동시 시나리오 비교 결과

## 목적

재학습 요청이 동시에 들어올 때 Worker 분리 전/후 추론(predict) latency를 비교하여
**구조 개선(SQS + 별도 ECS Worker)의 실제 효과를 같은 vCPU 조건에서 측정**.

---

## 환경 구성

| 항목 | Stage 1 | Phase 3 |
|------|---------|---------|
| 컴퓨팅 (API) | 단일 Docker (0.5 vCPU) | ECS Fargate (0.5 vCPU) |
| 재학습 처리 방식 | API 프로세스 내 백그라운드 스레드 | SQS → 별도 ECS Worker 태스크 (1 vCPU) |
| CPU 경합 여부 | 추론 + 재학습이 동일 프로세스 공유 | Worker ECS가 독립 CPU 사용 |
| 엔드포인트 | http://localhost:8000 | https://2un7ms8dak.execute-api.ap-northeast-2.amazonaws.com |
| 재학습 API | `/model/retrain` → 즉시 BERT fine-tuning 시작 | `/model/retrain` → SQS 발행 (즉시 반환) → Worker 처리 |

---

## 테스트 시나리오

| 항목 | 설정 |
|------|------|
| 스크립트 | `scripts/retrain_concurrent.js` |
| predict_load | 10 VU, 25분 지속 |
| retrain_ctrl | 5분 시점에 `/model/retrain` 1회 트리거 |
| 판정 기준 | predict p95 < 500ms |

**설계 의도**: 재학습 트리거 직후부터 종료까지 추론 latency가 안정적으로 유지되는지 확인.
Stage 1에서는 BERT fine-tuning이 API 프로세스를 점유 → 추론 latency 급등 예상.
Phase 3에서는 Worker ECS가 별도 CPU에서 처리 → API 추론 latency 영향 없음 예상.

---

## 측정 결과

| 지표 | Stage 1 (백그라운드 스레드) | Phase 3 (Worker 분리) | 개선율 |
|------|---------------------------|----------------------|--------|
| p50 latency | 133 ms | **61 ms** | **-54.1%** |
| p95 latency | **1,826 ms** | **107 ms** | **-94.1%** |
| avg latency | 393 ms | 66 ms | -83.2% |
| max latency | 4,058 ms | 327 ms | -91.9% |
| 오류율 | **42.70%** | **0.00%** | 완전 해소 |
| 총 요청 수 | 13,105건 | 18,408건 | +40.5% |
| 재학습 트리거 | 1회 | 1회 | — |
| 통과 기준 (p95 < 500ms) | **FAIL ✗** | **PASS ✓** | |

---

## 분석

### Stage 1 FAIL 원인

```
/model/retrain 호출
  └─ FastAPI background thread → BERT fine-tuning 시작
  └─ 동일 프로세스(0.5 vCPU)에서 추론 + 재학습 CPU 경합
  └─ 추론 latency 1,826ms, 오류율 42.70%
  └─ 재학습 중 API가 사실상 마비 상태
```

5분 이후 latency 급등:
- 재학습 트리거 전 (0~5분): p50 ~100ms 수준
- 재학습 트리거 후 (5~25분): BERT fine-tuning이 0.5 vCPU를 독점
- 42.7% 오류는 CPU 포화로 인한 타임아웃 또는 503 응답

### Phase 3 PASS 원인

```
/model/retrain 호출
  └─ FastAPI → SQS 메시지 발행 (즉시 반환, ~10ms)
  └─ Worker ECS 태스크(독립 1 vCPU)가 SQS 롱폴링으로 수신
  └─ API ECS(0.5 vCPU)는 추론 전용 → latency 영향 없음
  └─ 재학습 중/후 p95=107ms 유지
```

Worker 분리 효과:
- API CPU를 추론에만 사용 → p95=107ms (재학습 중에도 동일)
- 재학습이 비동기로 처리되어 API 응답에 영향 없음
- 오류율 0%: 재학습 중 단 1건의 실패도 없음

---

## 결론

| 항목 | 결론 |
|------|------|
| CPU 경합 해소 | Stage 1: 재학습 시 0.5 vCPU 독점 → 추론 완전 마비 |
| Worker 분리 효과 | Phase 3: API/Worker CPU 독립 → 재학습 중에도 p95=107ms |
| 오류율 개선 | 42.70% → 0.00% (완전 해소) |
| p95 latency 개선 | 1,826ms → 107ms (**-94.1%**) |
| SLO 달성 | Stage 1 FAIL → Phase 3 **PASS** |

**Worker 분리(SQS + 별도 ECS)는 같은 vCPU 조건에서 재학습 동시 시나리오 SLO를 FAIL → PASS로 전환한 핵심 구조 개선이다.**

---

*테스트 날짜: 2026-03-26*
*테스터: 0206pdh*
*Stage 1 엔드포인트: http://localhost:8000*
*Phase 3 엔드포인트: https://2un7ms8dak.execute-api.ap-northeast-2.amazonaws.com*
