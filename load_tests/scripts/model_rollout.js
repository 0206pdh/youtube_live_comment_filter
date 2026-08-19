import http from "k6/http";
import { check, sleep } from "k6";
import exec from "k6/execution";
import { Trend } from "k6/metrics";

const apiUrl = (__ENV.API_URL || "").replace(/\/$/, "");
const apiKey = __ENV.API_KEY || "";
const expectedVersion = __ENV.EXPECTED_MODEL_VERSION || "";
const rolloutSeconds = new Trend("model_rollout_seconds", true);

export const options = {
  scenarios: {
    trigger: { executor: "shared-iterations", vus: 1, iterations: 1, exec: "trigger", maxDuration: "1m" },
    observe: { executor: "constant-vus", vus: 1, duration: "45m", exec: "observe", startTime: "2s" },
    predict: { executor: "constant-vus", vus: Number(__ENV.PREDICT_VUS || 10), duration: "45m", exec: "predict", startTime: "2s" },
  },
  thresholds: {
    http_req_failed: ["rate<0.01"],
    http_req_duration: ["p(95)<500"],
  },
};

const headers = { headers: { "Content-Type": "application/json", "X-API-Key": apiKey }, timeout: "30s" };

export function trigger() {
  const response = http.post(`${apiUrl}/model/retrain`, "{}", headers);
  check(response, { "retrain accepted": (r) => r.status >= 200 && r.status < 300 });
}

export function observe() {
  const startedAt = Date.now();
  while (Date.now() - startedAt < 45 * 60 * 1000) {
    const response = http.get(`${apiUrl}/health/ready`, headers);
    if (response.status === 200) {
      const version = response.json("model_version");
      if (version && version !== "bundled" && (!expectedVersion || version === expectedVersion)) {
        rolloutSeconds.add((Date.now() - startedAt) / 1000);
        exec.test.abort(`Model rollout completed: ${version}`);
      }
    }
    sleep(5);
  }
}

export function predict() {
  const response = http.post(`${apiUrl}/predict`, JSON.stringify({ texts: ["모델 교체 중 추론 연속성 확인"] }), headers);
  check(response, { "predict remains available": (r) => r.status === 200 });
  sleep(1);
}

