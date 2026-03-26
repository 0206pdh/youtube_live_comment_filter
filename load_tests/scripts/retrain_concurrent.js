/**
 * 재학습 + 추론 동시 시나리오 (Phase 3 Worker 분리 검증)
 *
 * 목적:
 *   Worker 분리 후 /model/retrain 이 SQS → 별도 ECS 태스크에서 실행될 때
 *   /predict latency 가 재학습 중에도 안정적으로 유지되는지 측정한다.
 *
 *   분리 전 (Stage 3):
 *     /model/retrain → FastAPI background thread (API 프로세스 내)
 *     → BERT fine-tuning 이 API 와 0.5 vCPU 공유 → latency 급등
 *
 *   분리 후 (Phase 3 / Stage 3B):
 *     /model/retrain → SQS 발행 (즉시 반환) → Worker ECS 태스크 (독립 CPU)
 *     → API CPU 는 추론 전용 → latency 안정 유지
 *
 * 시나리오:
 *   - 0~4분: /predict 10 VU (사전 기준선 측정)
 *   - 5분:   /model/retrain 트리거 (Worker 재학습 시작)
 *   - 5~25분: /predict 10 VU (재학습 중 latency 모니터링)
 *   총 25분 — Worker 재학습(약 15~20분) 동안 추론 latency 안정성 확인
 *
 * 사용법:
 *   k6 run -e BASE_URL=https://... -e API_KEY=xxx scripts/retrain_concurrent.js
 */
import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend, Counter } from "k6/metrics";
import { BASE_URL, authHeaders, randomComment } from "./config.js";

export const options = {
  scenarios: {
    // 10 VU: 전체 25분 동안 지속 추론
    predict_load: {
      executor: "constant-vus",
      vus: 10,
      duration: "25m",
      gracefulStop: "30s",
      exec: "predictLoad",
    },
    // 1 VU: 5분 시점에 retrain 1회 트리거
    retrain_ctrl: {
      executor: "shared-iterations",
      vus: 1,
      iterations: 1,
      maxDuration: "25m",
      exec: "retrainCtrl",
      startTime: "5m", // 5분 후 retrain 트리거
    },
  },
  thresholds: {
    // 재학습 중에도 p95 < 500ms → Worker 분리 효과 증명
    "predict_latency_ms": ["p(95)<500"],
    "predict_error_rate": ["rate<0.01"],
  },
};

const predictLatency = new Trend("predict_latency_ms", true);
const predictError   = new Rate("predict_error_rate");
const retrainCount   = new Counter("retrain_triggers");

// ─── 추론 (전 구간) ────────────────────────────────────────────────────────────

export function predictLoad() {
  const res = http.post(
    `${BASE_URL}/predict`,
    JSON.stringify({ texts: [randomComment()] }),
    { headers: authHeaders(), timeout: "10s" }
  );

  const ok = check(res, {
    "status 200": (r) => r.status === 200,
    "has labels": (r) => {
      try { return JSON.parse(r.body).labels !== undefined; } catch { return false; }
    },
  });

  predictError.add(!ok);
  predictLatency.add(res.timings.duration);
  sleep(Math.random() * 0.5 + 0.5);
}

// ─── 재학습 트리거 (5분 시점, 1회) ────────────────────────────────────────────

export function retrainCtrl() {
  const res = http.post(
    `${BASE_URL}/model/retrain`,
    null,
    { headers: authHeaders(), timeout: "10s" }
  );

  const ok = check(res, {
    "retrain accepted": (r) => {
      try { return JSON.parse(r.body).success === true; } catch { return false; }
    },
  });

  if (ok) {
    retrainCount.add(1);
    console.log(`[retrain_ctrl] Retrain triggered at ${new Date().toISOString()}`);
    console.log(`[retrain_ctrl] Response: ${res.body}`);
  } else {
    console.log(`[retrain_ctrl] Retrain FAILED: ${res.status} ${res.body}`);
  }
  // 트리거 후 종료 — Worker가 나머지를 처리
}

// ─── 요약 ──────────────────────────────────────────────────────────────────────

export function handleSummary(data) {
  const p  = data.metrics["predict_latency_ms"]?.values ?? {};
  const er = data.metrics["predict_error_rate"]?.values ?? {};
  const rt = data.metrics["retrain_triggers"]?.values ?? {};
  const hd = data.metrics["http_req_duration"]?.values ?? {};
  const reqs = data.metrics["http_reqs"]?.values ?? {};

  const p95 = (p["p(95)"] || 0).toFixed(0);
  const pass = parseFloat(p95) < 500;

  return {
    stdout: `
=== 재학습 + 추론 동시 시나리오 결과 (Phase 3 — Worker 분리) ===

테스트 구성
  - predict_load : 10 VU, 25분 (재학습 전/중/후 전 구간)
  - retrain_ctrl : 5분 시점에 /model/retrain 1회 트리거

[추론 Predict — 전 구간]
  p50:  ${(p["med"]   || 0).toFixed(0)} ms
  p95:  ${p95} ms   (목표: < 500ms) → ${pass ? "PASS ✓" : "FAIL ✗"}
  avg:  ${(p["avg"]   || 0).toFixed(0)} ms
  max:  ${(p["max"]   || 0).toFixed(0)} ms
  오류율: ${((er["rate"] || 0) * 100).toFixed(2)}%
  총 요청: ${reqs["count"] || 0}건

[재학습 트리거]
  트리거 횟수: ${rt["count"] || 0}회

결론:
${pass
  ? "→ 재학습 중에도 predict p95 < 500ms 유지 = Worker 분리 효과 증명 완료"
  : "→ predict p95 > 500ms = 재학습과 CPU 경합 가능성 존재 (재검토 필요)"}
`,
  };
}
