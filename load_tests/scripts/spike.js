/**
 * Spike 시나리오: 0 → 100 VU (30초), 1분 유지, 90초 감소
 * 목적: 트래픽 급증 시 오류율 및 복구 시간 측정
 * 사용법:
 *   k6 run -e BASE_URL=http://localhost:8000 --out json=../results/stage1_spike.json scripts/spike.js
 */
import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";
import { BASE_URL, authHeaders, randomComment } from "./config.js";

const errorRate      = new Rate("error_rate");
const predictLatency = new Trend("predict_latency_ms", true);

export const options = {
  stages: [
    { duration: "30s", target: 100 }, // 급격한 트래픽 급증
    { duration: "60s", target: 100 }, // 피크 유지
    { duration: "90s", target: 0   }, // 정상화
  ],
  thresholds: {
    http_req_duration: ["p(95)<2000"],
    error_rate:        ["rate<0.05"],
  },
};

export default function () {
  const res = http.post(
    `${BASE_URL}/predict`,
    JSON.stringify({ texts: [randomComment()] }),
    { headers: authHeaders(), timeout: "15s" }
  );

  const ok = check(res, {
    "not 5xx":           (r) => r.status < 500,
    "200 or 429":        (r) => r.status === 200 || r.status === 429,
  });

  errorRate.add(!ok);
  predictLatency.add(res.timings.duration);

  sleep(0.1);
}

export function handleSummary(data) {
  return { stdout: JSON.stringify(data.metrics, null, 2) };
}
