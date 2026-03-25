/**
 * Soak 시나리오: 30 VU, 30분
 * 목적: 시간이 지날수록 latency가 증가하는지 (메모리 누수, 연결 고갈) 확인
 * 사용법:
 *   k6 run -e BASE_URL=http://localhost:8000 --out json=../results/stage1_soak.json scripts/soak.js
 */
import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";
import { BASE_URL, authHeaders, randomComment } from "./config.js";

const errorRate      = new Rate("error_rate");
const predictLatency = new Trend("predict_latency_ms", true);

export const options = {
  vus:      30,
  duration: "30m",
  thresholds: {
    http_req_duration: ["p(95)<800"],
    error_rate:        ["rate<0.01"],
  },
};

export default function () {
  // 90%: predict, 10%: training-data 저장 (혼합 시나리오)
  if (Math.random() < 0.9) {
    const res = http.post(
      `${BASE_URL}/predict`,
      JSON.stringify({ texts: [randomComment()] }),
      { headers: authHeaders(), timeout: "10s" }
    );

    const ok = check(res, {
      "status 200": (r) => r.status === 200,
      "no 5xx":     (r) => r.status < 500,
    });

    errorRate.add(!ok);
    predictLatency.add(res.timings.duration);
  } else {
    const res = http.post(
      `${BASE_URL}/training-data`,
      JSON.stringify({
        text:    randomComment(),
        label:   Math.random() > 0.5 ? 1 : 0,
        user_id: `soak-vu-${__VU}`,
      }),
      { headers: authHeaders(), timeout: "10s" }
    );

    check(res, { "training saved": (r) => r.status === 200 || r.status === 201 });
  }

  sleep(Math.random() * 0.5 + 0.5); // 0.5~1.0초
}

export function handleSummary(data) {
  return { stdout: JSON.stringify(data.metrics, null, 2) };
}
