/**
 * 데이터 일관성 검증 스크립트 (Stage 2 전용)
 *
 * 목적:
 *   nginx 라운드로빈 뒤에서 server_a / server_b가 각자 다른 로컬 스토리지를 쓸 때
 *   "A에 저장한 데이터를 B에서 조회 → 없음" 을 수치로 증명
 *
 * 방법:
 *   1. /training-data에 데이터 저장 (어느 서버가 받을지 모름)
 *   2. 같은 데이터를 /lookup 으로 여러 번 조회
 *   3. X-Upstream-Addr 헤더를 보고 어느 서버가 응답했는지 추적
 *   4. 저장한 서버 ≠ 조회한 서버인 경우 "miss" 카운트
 *
 * 사용법:
 *   k6 run -e BASE_URL=http://localhost:8080 --out json=../results/stage2_consistency.json scripts/consistency_check.js
 */
import http from "k6/http";
import { check, sleep } from "k6";
import { Counter, Rate } from "k6/metrics";
import { BASE_URL, authHeaders } from "./config.js";

const consistencyMiss = new Counter("consistency_miss");   // 다른 서버에서 데이터 못 찾은 횟수
const consistencyHit  = new Counter("consistency_hit");    // 같은 데이터를 찾은 횟수
const missRate        = new Rate("consistency_miss_rate"); // 불일치율

export const options = {
  vus:      5,
  duration: "3m",
  thresholds: {
    // 포트폴리오 핵심: miss rate가 0이 아님을 증명하는 게 목적
    // Stage 2에서는 이 threshold가 FAIL나야 정상 (문제점 재현 성공)
    consistency_miss_rate: ["rate<0.01"], // 의도적으로 빡빡하게 → FAIL 유도
  },
};

export default function () {
  const comment = `consistency-test-${__VU}-${__ITER}-${Date.now()}`;

  // 1. 학습 데이터 저장 (어느 서버가 받을지 모름, nginx가 분산)
  const saveRes = http.post(
    `${BASE_URL}/training-data`,
    JSON.stringify({ text: comment, label: 1, user_id: `vu-${__VU}` }),
    { headers: authHeaders(), timeout: "5s" }
  );

  const savedToServer = saveRes.headers["X-Upstream-Addr"] || "unknown";

  check(saveRes, { "save 200": (r) => r.status === 200 || r.status === 201 });

  sleep(0.2);

  // 2. 같은 텍스트를 5번 조회 → 다른 서버가 응답할 확률 높음
  let miss = false;
  for (let i = 0; i < 5; i++) {
    const lookupRes = http.get(
      `${BASE_URL}/lookup?text=${encodeURIComponent(comment)}`,
      { headers: authHeaders(), timeout: "5s" }
    );

    const respondedServer = lookupRes.headers["X-Upstream-Addr"] || "unknown";
    const found = lookupRes.status === 200;

    if (!found && respondedServer !== savedToServer) {
      // 저장한 서버와 다른 서버가 응답했고, 데이터를 못 찾음 → 불일치
      miss = true;
      consistencyMiss.add(1);
    } else if (found) {
      consistencyHit.add(1);
    }

    sleep(0.1);
  }

  missRate.add(miss);
  sleep(0.5);
}

export function handleSummary(data) {
  const missCount = data.metrics.consistency_miss?.values?.count || 0;
  const hitCount  = data.metrics.consistency_hit?.values?.count  || 0;
  const total     = missCount + hitCount;
  const missRateVal = total > 0 ? ((missCount / total) * 100).toFixed(1) : "0";

  const summary = `
=== Stage 2 데이터 일관성 검증 결과 ===

총 조회: ${total}회
  일치(hit):  ${hitCount}회
  불일치(miss): ${missCount}회
  불일치율: ${missRateVal}%

→ 불일치율이 0%보다 높으면 로컬 스토리지 기반 스케일아웃의 문제점 재현 성공
→ ECS Fargate + S3/RDS 환경에서는 이 수치가 0%가 되어야 함
`;

  return {
    stdout: summary,
    "../results/stage2_consistency.json": JSON.stringify(data, null, 2),
  };
}
