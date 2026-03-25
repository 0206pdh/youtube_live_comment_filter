/**
 * Baseline 시나리오: 10 VU, 5분
 * 목적: 정상 트래픽에서의 기준 지표 측정
 * 사용법:
 *   k6 run -e BASE_URL=http://localhost:8000 --out json=../results/stage1_baseline.json scripts/baseline.js
 */
import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";
import { BASE_URL, authHeaders, randomComment } from "./config.js";

const errorRate      = new Rate("error_rate");
const predictLatency = new Trend("predict_latency_ms", true);

export const options = {
  vus:      10,
  duration: "5m",
  thresholds: {
    http_req_duration: ["p(95)<500"],
    error_rate:        ["rate<0.01"],
  },
};

export default function () {
  const res = http.post(
    `${BASE_URL}/predict`,
    JSON.stringify({ texts: [randomComment()] }),
    { headers: authHeaders(), timeout: "10s" }
  );

  const ok = check(res, {
    "status 200":    (r) => r.status === 200,
    "has labels":    (r) => { try { return JSON.parse(r.body).labels !== undefined; } catch { return false; } },
    "latency<500ms": (r) => r.timings.duration < 500,
  });

  errorRate.add(!ok);
  predictLatency.add(res.timings.duration);

  sleep(Math.random() + 0.5); // 0.5~1.5초 대기 (실제 사용자 모방)
}

export function handleSummary(data) {
  return { stdout: JSON.stringify(data.metrics, null, 2) };
}
