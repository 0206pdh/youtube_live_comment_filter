import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";

const targetVUs = Math.min(Number(__ENV.TARGET_VUS || 1000), 10000);
const apiUrl = (__ENV.API_URL || "").replace(/\/$/, "");
const apiKey = __ENV.API_KEY || "";
const batchSize = Math.max(1, Number(__ENV.BATCH_SIZE || 5));

if (!apiUrl) {
  throw new Error("API_URL is required");
}

const inferenceLatency = new Trend("inference_latency", true);
const applicationErrors = new Rate("application_errors");

export const options = {
  scenarios: {
    scale_ramp: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "2m", target: Math.max(10, Math.floor(targetVUs * 0.01)) },
        { duration: "3m", target: Math.max(50, Math.floor(targetVUs * 0.05)) },
        { duration: "5m", target: Math.max(100, Math.floor(targetVUs * 0.1)) },
        { duration: "10m", target: targetVUs },
        { duration: "10m", target: targetVUs },
        { duration: "5m", target: 0 },
      ],
      gracefulRampDown: "2m",
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.01"],
    application_errors: ["rate<0.01"],
    inference_latency: ["p(95)<2000"],
  },
  discardResponseBodies: false,
};

const sampleTexts = [
  "오늘 방송 정말 재미있어요",
  "설명이 이해하기 쉽습니다",
  "이 댓글은 분류 테스트용입니다",
  "다음 방송도 기대할게요",
  "채팅 흐름이 아주 빠르네요",
];

export default function () {
  const texts = Array.from({ length: batchSize }, (_, i) => sampleTexts[i % sampleTexts.length]);
  const response = http.post(
    `${apiUrl}/predict`,
    JSON.stringify({ texts }),
    {
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": apiKey,
      },
      timeout: "30s",
      tags: { endpoint: "predict" },
    },
  );

  inferenceLatency.add(response.timings.duration);
  const ok = check(response, {
    "predict status is 200": (r) => r.status === 200,
    "predict response has results": (r) => {
      if (r.status !== 200) return false;
      try {
        return Array.isArray(r.json("results"));
      } catch (_) {
        return false;
      }
    },
  });
  applicationErrors.add(!ok);
  sleep(Number(__ENV.THINK_TIME_SECONDS || 1));
}

