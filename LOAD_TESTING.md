# 부하 테스트 가이드

이 문서는 `youtube_live_comment_filter` 서비스의 각 Phase 전환 전 수행하는 부하 테스트 절차를 정의한다. 성능 기준을 사전에 검증해 프로덕션 사고를 예방하는 것이 목적이다.

---

## 목차

1. [목적과 원칙](#1-목적과-원칙)
2. [테스트 도구 선택](#2-테스트-도구-선택)
3. [테스트 시나리오](#3-테스트-시나리오)
4. [k6 스크립트](#4-k6-스크립트)
5. [Phase별 통과 기준](#5-phase별-통과-기준)
6. [CloudWatch Logs Insights 분석](#6-cloudwatch-logs-insights-분석)
7. [결과 기록 양식](#7-결과-기록-양식)
8. [흔한 실패 원인과 대응](#8-흔한-실패-원인과-대응)

---

## 1. 목적과 원칙

### 왜 Phase 전환 전에 부하 테스트를 수행하는가

Phase 전환은 인프라 구조가 바뀌는 시점이다. 예를 들어:
- Phase 0 → 1: 로컬 실행에서 ECS Fargate + ALB + API Gateway로 전환
- Phase 1 → 2: S3/SQS/RDS 연동이 추가되어 I/O 경로가 늘어남
- Phase 2 → 3: Training Worker 분리, Redis Rate Limiter 도입

구조가 바뀌면 병목 지점도 달라진다. 코드 리뷰나 단위 테스트만으로는 실제 트래픽 하에서의 병목을 발견할 수 없다. 부하 테스트는 "이 구조가 예상 트래픽을 버티는가"를 객관적 수치로 검증하는 유일한 방법이다.

### 원칙

- 부하 테스트는 dev 환경에서 수행한다. prod 환경에서는 실제 사용자 트래픽과 겹치므로 금지.
- 테스트 전후 CloudWatch 로그와 ALB/ECS 메트릭을 반드시 확인한다.
- 통과 기준 미달 시 Phase 전환을 중단하고 원인을 분석한다.
- 테스트 결과는 [7. 결과 기록 양식](#7-결과-기록-양식)에 기록하고 커밋한다.

---

## 2. 테스트 도구 선택

### 권장 도구: k6

k6(https://k6.io)를 권장한다. 이유:

| 항목 | k6 | Locust | Apache JMeter |
|------|-----|--------|---------------|
| 스크립트 언어 | JavaScript (ES6) | Python | XML/GUI |
| 실행 방식 | 단일 바이너리 | Python 런타임 필요 | JVM 필요 |
| CloudWatch 연동 | 직접 지원 (k6 cloud / Grafana) | 별도 설정 필요 | 별도 설정 필요 |
| 학습 곡선 | 낮음 | 낮음 | 높음 |
| 포트폴리오 가시성 | 높음 (HTML report, Grafana) | 중간 | 낮음 |

k6는 JavaScript로 테스트 시나리오를 작성하고, 실행 결과를 터미널에 출력하거나 JSON으로 저장할 수 있다. `k6 run --out json=result.json script.js` 한 줄로 결과를 파일로 저장해 커밋에 포함할 수 있다.

### 대안: Locust

Python 기반 팀이라면 Locust도 좋은 선택이다. FastAPI와 같은 Python 생태계를 쓰므로 재사용성이 높다.

```bash
pip install locust
locust -f locustfile.py --host=https://<api-gateway-url> --users 50 --spawn-rate 5
```

단, Locust는 분산 실행이 필요할 때 master/worker 구조를 별도로 구성해야 해서 k6보다 초기 설정이 복잡하다.

### 설치 (k6)

```bash
# macOS
brew install k6

# Windows (Chocolatey)
choco install k6

# Linux
sudo gpg -k
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update && sudo apt-get install k6
```

---

## 3. 테스트 시나리오

세 가지 시나리오를 정의한다. 각 Phase 전환 전에 세 시나리오를 모두 통과해야 한다.

### 시나리오 1: Baseline (기준 트래픽)

**목적:** 정상적인 일상 트래픽 수준에서 지연시간과 오류율이 기준을 만족하는지 확인한다.

| 항목 | 값 |
|------|-----|
| 가상 사용자 (VU) | 10 |
| 지속 시간 | 5분 |
| 요청 패턴 | 균일한 속도 |
| 테스트 대상 | `/predict`, `/health/ready` |

```
10 VU ──────────────────────────── (5분) ──────── 종료
```

**기대 결과:** p95 latency가 낮고 오류율이 0에 가까워야 한다. 이것이 통과 기준의 베이스라인이다.

---

### 시나리오 2: Spike (트래픽 급증)

**목적:** YouTube 라이브 방송 시작, 유명인 방문 등으로 트래픽이 갑자기 폭증하는 상황을 재현한다. 시스템이 스파이크를 버티고 정상으로 회복하는지 확인한다.

| 항목 | 값 |
|------|-----|
| 가상 사용자 (VU) | 0 → 100 (30초 안에) |
| 지속 시간 | 총 3분 (30초 램프업 + 1분 유지 + 90초 램프다운) |
| 요청 패턴 | 급격한 상승 후 정상화 |
| 테스트 대상 | `/predict` |

```
100 VU       ████
             ████
          ▄▄▄████▄▄▄
0 VU  ▄▄▄▄               ▄▄▄▄ 종료
      0s  30s  90s  150s  180s
```

**기대 결과:** 스파이크 중 오류율이 기준 이하를 유지하고, 스파이크 종료 후 latency가 기준 이하로 복귀해야 한다.

---

### 시나리오 3: Soak (장시간 안정성)

**목적:** 메모리 누수, 연결 고갈, 로그 I/O 누적 등 시간이 지날수록 나타나는 문제를 탐지한다.

| 항목 | 값 |
|------|-----|
| 가상 사용자 (VU) | 30 |
| 지속 시간 | 30분 |
| 요청 패턴 | 균일한 속도 |
| 테스트 대상 | `/predict`, `/training-data` |

```
30 VU  ────────────────────────────────────── (30분) ─── 종료
```

**기대 결과:** 30분간 p95 latency가 점진적으로 증가하지 않아야 한다. 증가한다면 메모리 누수 또는 연결 고갈을 의심한다.

---

## 4. k6 스크립트

### 기본 설정 파일 (`load_tests/config.js`)

```javascript
// load_tests/config.js
export const BASE_URL = __ENV.BASE_URL || "http://localhost:8000";
export const API_KEY = __ENV.API_KEY || "dev-test-key";

// 테스트용 댓글 샘플 (실제 YouTube 라이브 댓글 패턴)
export const SAMPLE_COMMENTS = [
  "이 방송 너무 재밌다ㅋㅋㅋ",
  "저 ㅂㅅ같은 놈 꺼져라",
  "와 진짜 대박이다",
  "니가 뭔데 이런 방송 봄?",
  "항상 응원합니다!",
  "쓰레기 같은 방송이네",
  "오늘도 좋은 방송 감사해요",
  "이런 거 보는 애들 다 병신",
  "너무 웃겨 ㅋㅋㅋㅋ",
  "닥쳐 ㅡㅡ",
];
```

---

### 시나리오 1: Baseline 스크립트 (`load_tests/baseline.js`)

```javascript
import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";
import { BASE_URL, API_KEY, SAMPLE_COMMENTS } from "./config.js";

// 커스텀 메트릭
const errorRate = new Rate("error_rate");
const predictLatency = new Trend("predict_latency_ms", true);

export const options = {
  // Baseline: 10 VU, 5분
  vus: 10,
  duration: "5m",

  thresholds: {
    // 통과 기준: p95 < 500ms, 오류율 < 1%
    http_req_duration: ["p(95)<500"],
    error_rate: ["rate<0.01"],
  },
};

export default function () {
  // 랜덤 댓글 선택
  const comment = SAMPLE_COMMENTS[Math.floor(Math.random() * SAMPLE_COMMENTS.length)];

  // /predict 요청
  const predictRes = http.post(
    `${BASE_URL}/predict`,
    JSON.stringify({
      comments: [{ text: comment, comment_id: `test-${__VU}-${__ITER}` }],
    }),
    {
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": API_KEY,
      },
      timeout: "10s",
    }
  );

  // 성공 기준 확인
  const success = check(predictRes, {
    "status is 200": (r) => r.status === 200,
    "response has results": (r) => {
      try {
        const body = JSON.parse(r.body);
        return body.results !== undefined && body.results.length > 0;
      } catch {
        return false;
      }
    },
    "latency < 500ms": (r) => r.timings.duration < 500,
  });

  errorRate.add(!success);
  predictLatency.add(predictRes.timings.duration);

  // 실제 사용자 동작 모방: 요청 간 0.5~1.5초 대기
  sleep(Math.random() + 0.5);
}

export function handleSummary(data) {
  return {
    "load_tests/results/baseline_result.json": JSON.stringify(data, null, 2),
  };
}
```

---

### 시나리오 2: Spike 스크립트 (`load_tests/spike.js`)

```javascript
import http from "k6/http";
import { check, sleep } from "k6";
import { Rate } from "k6/metrics";
import { BASE_URL, API_KEY, SAMPLE_COMMENTS } from "./config.js";

const errorRate = new Rate("error_rate");

export const options = {
  // Spike: 0 → 100 VU (30초), 1분 유지, 90초 램프다운
  stages: [
    { duration: "30s", target: 100 }, // 급격한 트래픽 급증
    { duration: "60s", target: 100 }, // 피크 유지
    { duration: "90s", target: 0 },   // 정상화
  ],

  thresholds: {
    // 스파이크 중 오류율 < 5% (평시보다 완화)
    error_rate: ["rate<0.05"],
    // 스파이크 중 p95 < 2000ms (응답 자체는 보장)
    http_req_duration: ["p(95)<2000"],
  },
};

export default function () {
  const comment = SAMPLE_COMMENTS[Math.floor(Math.random() * SAMPLE_COMMENTS.length)];

  const res = http.post(
    `${BASE_URL}/predict`,
    JSON.stringify({
      comments: [{ text: comment, comment_id: `spike-${__VU}-${__ITER}` }],
    }),
    {
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": API_KEY,
      },
      timeout: "15s",
    }
  );

  const success = check(res, {
    "status is 200 or 429": (r) => r.status === 200 || r.status === 429,
    "not a 5xx error": (r) => r.status < 500,
  });

  errorRate.add(!success);
  sleep(0.1); // 스파이크 시나리오에서는 짧은 대기
}

export function handleSummary(data) {
  return {
    "load_tests/results/spike_result.json": JSON.stringify(data, null, 2),
  };
}
```

---

### 시나리오 3: Soak 스크립트 (`load_tests/soak.js`)

```javascript
import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";
import { BASE_URL, API_KEY, SAMPLE_COMMENTS } from "./config.js";

const errorRate = new Rate("error_rate");
const predictLatency = new Trend("predict_latency_ms", true);

export const options = {
  // Soak: 30 VU, 30분
  vus: 30,
  duration: "30m",

  thresholds: {
    // 30분 내내 p95 < 800ms (평시보다 약간 완화)
    http_req_duration: ["p(95)<800"],
    error_rate: ["rate<0.01"],
  },
};

export default function () {
  const comment = SAMPLE_COMMENTS[Math.floor(Math.random() * SAMPLE_COMMENTS.length)];

  // /predict 요청
  const predictRes = http.post(
    `${BASE_URL}/predict`,
    JSON.stringify({
      comments: [{ text: comment, comment_id: `soak-${__VU}-${__ITER}` }],
    }),
    {
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": API_KEY,
      },
      timeout: "10s",
    }
  );

  check(predictRes, {
    "status is 200": (r) => r.status === 200,
    "no server error": (r) => r.status < 500,
  });

  errorRate.add(predictRes.status >= 500 || predictRes.status === 0);
  predictLatency.add(predictRes.timings.duration);

  // 학습 데이터 저장도 주기적으로 포함 (10번 중 1번)
  if (__ITER % 10 === 0) {
    const trainingRes = http.post(
      `${BASE_URL}/training-data`,
      JSON.stringify({
        text: comment,
        label: Math.random() > 0.5 ? 1 : 0,
        user_id: `soak-user-${__VU}`,
      }),
      {
        headers: {
          "Content-Type": "application/json",
          "X-API-Key": API_KEY,
        },
        timeout: "10s",
      }
    );

    check(trainingRes, {
      "training-data accepted": (r) => r.status === 200 || r.status === 201,
    });
  }

  sleep(Math.random() * 0.5 + 0.5); // 0.5~1.0초 대기
}

export function handleSummary(data) {
  return {
    "load_tests/results/soak_result.json": JSON.stringify(data, null, 2),
  };
}
```

---

### 실행 방법

```bash
# 환경변수 설정
export BASE_URL="https://<api-gateway-id>.execute-api.ap-northeast-2.amazonaws.com"
export API_KEY="your-api-key-here"

# 결과 저장 디렉토리 생성
mkdir -p load_tests/results

# 시나리오별 실행
k6 run -e BASE_URL=$BASE_URL -e API_KEY=$API_KEY load_tests/baseline.js
k6 run -e BASE_URL=$BASE_URL -e API_KEY=$API_KEY load_tests/spike.js
k6 run -e BASE_URL=$BASE_URL -e API_KEY=$API_KEY load_tests/soak.js

# HTML 리포트 생성 (k6-reporter 플러그인 사용)
k6 run --out json=load_tests/results/raw.json -e BASE_URL=$BASE_URL -e API_KEY=$API_KEY load_tests/baseline.js
```

---

## 5. Phase별 통과 기준

Phase 전환 전 아래 기준을 모두 통과해야 한다. 하나라도 미달이면 전환 중단 후 원인 분석.

### Phase 0 → 1: 로컬 → AWS ECS 전환 기준

ECS Fargate + ALB + API Gateway 구조에서 기본 트래픽을 처리할 수 있는지 검증한다.

| 시나리오 | p95 Latency | 오류율 | 동시 사용자 | 비고 |
|---------|-------------|--------|------------|------|
| Baseline | < 500ms | < 1% | 10 VU, 5분 | 필수 통과 |
| Spike | < 2000ms | < 5% | 0→100 VU | 필수 통과 |
| Soak | < 800ms | < 1% | 30 VU, 30분 | 필수 통과 |

### Phase 1 → 2: S3/SQS/RDS 연동 추가 기준

I/O 경로가 늘어난 후에도 추론 성능이 유지되는지 검증한다.

| 시나리오 | p95 Latency | 오류율 | 동시 사용자 | 비고 |
|---------|-------------|--------|------------|------|
| Baseline | < 300ms | < 0.5% | 10 VU, 5분 | 필수 통과 |
| Spike | < 1500ms | < 3% | 0→100 VU | 필수 통과 |
| Soak | < 500ms | < 0.5% | 50 VU, 30분 | 필수 통과 |

> S3 저장과 SQS 발행이 `/predict` latency에 영향을 주지 않는지 특히 확인한다. training-data 저장은 비동기로 처리되어야 한다.

### Phase 2 → 3: Training Worker 분리, Redis Rate Limiter 도입 기준

추론과 학습이 완전히 분리된 후의 추론 성능을 검증한다.

| 시나리오 | p95 Latency | 오류율 | 동시 사용자 | 비고 |
|---------|-------------|--------|------------|------|
| Baseline | < 200ms | < 0.1% | 10 VU, 5분 | 필수 통과 |
| Spike | < 1000ms | < 1% | 0→100 VU | 필수 통과 |
| Soak | < 300ms | < 0.1% | 100 VU, 30분 | 필수 통과 |

> Training Worker 분리 후 추론 서비스의 CPU/메모리 여유가 늘어나므로 이 단계에서 기준이 대폭 강화된다.

---

## 6. CloudWatch Logs Insights 분석

부하 테스트 실행 중, 그리고 완료 직후에 CloudWatch Logs Insights 쿼리로 서버 측 관점을 확인한다.

### 6-1. p95 Latency 확인

```
fields @timestamp, latency_ms
| filter event_type = "PREDICT_METRIC"
| stats
    count() as total_requests,
    avg(latency_ms) as avg_ms,
    pct(latency_ms, 50) as p50_ms,
    pct(latency_ms, 95) as p95_ms,
    pct(latency_ms, 99) as p99_ms
| sort @timestamp desc
```

### 6-2. 오류율 확인

```
fields @timestamp, status_code, event_type
| filter event_type = "PREDICT_METRIC"
| stats
    count() as total,
    sum(status_code >= 500) as server_errors,
    sum(status_code = 429) as rate_limited,
    sum(status_code = 401) as auth_failed
| sort @timestamp desc
```

### 6-3. 배치 크기 분포 확인 (추론 부하 파악)

```
fields @timestamp, batch_size, latency_ms
| filter event_type = "PREDICT_METRIC"
| stats
    avg(batch_size) as avg_batch,
    max(batch_size) as max_batch,
    avg(latency_ms) as avg_latency,
    pct(latency_ms, 95) as p95_latency
| sort @timestamp desc
```

### 6-4. Rate Limit 거절 현황

```
fields @timestamp, client_id, path
| filter event_type = "RATE_LIMIT_REJECTED"
| stats count() as rejected_count by client_id, path
| sort rejected_count desc
| limit 20
```

### 6-5. 인증 실패 현황

```
fields @timestamp, source_ip, path
| filter status_code = 401 or status_code = 403
| stats count() as failure_count by source_ip
| sort failure_count desc
| limit 20
```

### 6-6. 시간대별 TPS (처리량) 추이

```
fields @timestamp, event_type
| filter event_type = "PREDICT_METRIC"
| stats count() as requests_per_minute by bin(1m)
| sort @timestamp asc
```

### 사용 방법

1. AWS 콘솔 → CloudWatch → Logs Insights
2. Log Group: `/ecs/ylcf-dev` (또는 환경에 맞는 이름)
3. 시간 범위: 부하 테스트 시작 전 5분 ~ 종료 후 5분
4. 위 쿼리 중 필요한 것을 붙여넣고 실행

---

## 7. 결과 기록 양식

부하 테스트 완료 후 아래 테이블을 채워 `load_tests/results/YYYY-MM-DD_phase_X_to_Y.md`로 저장하고 커밋한다.

### 기록 파일 예시: `load_tests/results/2026-03-23_phase1_to_2.md`

```markdown
# 부하 테스트 결과: Phase 1 → 2 전환 검증

## 테스트 환경

| 항목 | 값 |
|------|-----|
| 테스트 날짜 | 2026-03-23 |
| 테스트 환경 | dev (ap-northeast-2) |
| ECS 태스크 수 | 1 |
| ECS 태스크 스펙 | 512 CPU / 1024 MiB |
| Phase 전환 방향 | Phase 1 → Phase 2 |
| 테스터 | (이름) |
| API Gateway URL | https://xxxx.execute-api.ap-northeast-2.amazonaws.com |

## 시나리오별 결과

### Baseline (10 VU, 5분)

| 지표 | 측정값 | 통과 기준 | 결과 |
|------|--------|----------|------|
| p50 Latency | ? ms | - | - |
| p95 Latency | ? ms | < 300ms | PASS / FAIL |
| p99 Latency | ? ms | - | - |
| 오류율 | ?% | < 0.5% | PASS / FAIL |
| 총 요청 수 | ? | - | - |
| RPS | ? | - | - |

### Spike (0→100 VU, 3분)

| 지표 | 측정값 | 통과 기준 | 결과 |
|------|--------|----------|------|
| p95 Latency (피크) | ? ms | < 1500ms | PASS / FAIL |
| 오류율 (피크) | ?% | < 3% | PASS / FAIL |
| Rate Limit 거절 수 | ? | - | - |
| 5xx 발생 수 | ? | 0 권장 | - |

### Soak (50 VU, 30분)

| 지표 | 시작 10분 | 중간 10분 | 마지막 10분 | 통과 기준 | 결과 |
|------|---------|---------|----------|----------|------|
| p95 Latency | ? ms | ? ms | ? ms | < 500ms | PASS / FAIL |
| 오류율 | ?% | ?% | ?% | < 0.5% | PASS / FAIL |
| ECS 메모리 사용량 | ? MiB | ? MiB | ? MiB | 증가 없음 | PASS / FAIL |

## CloudWatch 관찰 사항

- ECS 태스크 재시작: 없음 / 있음 (이유: ?)
- S3 저장 성공률: ?%
- SQS 발행 지연: 없음 / 있음
- RDS 연결 오류: 없음 / 있음

## 전체 판정

- [ ] Baseline PASS
- [ ] Spike PASS
- [ ] Soak PASS

**Phase 전환 가능 여부:** PASS / FAIL

## 특이사항 및 다음 액션

(테스트 중 발견된 문제, 개선 필요 사항 등)
```

---

## 8. 흔한 실패 원인과 대응

### 8-1. Baseline에서 p95 Latency 초과

**증상:** 10 VU만으로도 p95가 500ms를 넘는다.

**원인 후보:**
- BERT 모델 추론 자체가 느림 (CPU 기반의 한계)
- ECS 태스크 CPU 할당이 너무 낮음 (256 CPU units)
- 첫 요청에서 모델 warm-up이 일어남 (cold start)

**대응:**
1. ECS 태스크 CPU를 512 → 1024로 높인다 (`infra/environments/dev/terraform.tfvars`에서 `task_cpu` 수정)
2. `/health/ready`가 200을 반환한 후 테스트를 시작해 cold start를 제거한다
3. 배치 크기를 줄여 단일 요청 크기를 축소한다

---

### 8-2. Spike에서 5xx 급증

**증상:** 100 VU가 몰리는 순간 5xx 오류가 급증한다.

**원인 후보:**
- Rate Limiter가 너무 빡빡하게 설정됨 (정상 트래픽도 429)
- ECS 태스크 1개가 동시 요청을 처리하지 못해 큐 초과
- ALB healthy target 부족 (스케일아웃 미설정)

**대응:**
1. Rate Limiter 설정을 확인하고 `RATE_LIMIT_PER_MINUTE`을 상향 조정
2. ECS `desired_count`를 2로 올려서 테스트
3. ALB 헬스체크 설정에서 `deregistration_delay`가 너무 길면 단축
4. 스파이크 기준 자체를 완화 (429는 서비스 실패가 아니라 정상 방어 동작)

---

### 8-3. Soak에서 Latency가 시간이 지날수록 증가

**증상:** 초반 10분은 p95 200ms인데 30분 후에는 p95 600ms로 증가한다.

**원인 후보:**
- 메모리 누수 (ECS 메모리 사용량이 계속 오름)
- S3 get+put 반복으로 오늘 날짜 파일 크기가 커지면서 S3 I/O 증가
- DB 연결 풀 고갈 (psycopg2 커넥션을 닫지 않음)

**대응:**
1. CloudWatch ECS 메모리 메트릭을 30분간 추적 → 지속 상승이면 메모리 누수 디버깅
2. S3 파일 크기가 커지는 문제라면 training-data 저장 로직에서 날짜별 파일 분리가 제대로 되었는지 확인
3. psycopg2 연결은 요청마다 새로 열고 닫거나 connection pool 설정 확인

---

### 8-4. 인증 오류 (401) 급증

**증상:** API_KEY를 넣었는데 401이 대량 발생한다.

**원인 후보:**
- `ENFORCE_AUTH=true`인데 k6 스크립트에서 API_KEY 헤더가 누락
- ECS 환경변수 `API_KEY`가 SSM에서 제대로 주입되지 않음
- Rate Limiter 제한에 걸려 429가 401로 오인됨

**대응:**
1. k6 스크립트의 headers 블록에서 `"X-API-Key": API_KEY` 확인
2. `curl -H "X-API-Key: <key>" <url>/health`로 단발 테스트
3. ECS 태스크 정의에서 SSM 파라미터 주입이 됐는지 콘솔 확인

---

### 8-5. CloudWatch에서 로그가 보이지 않음

**증상:** 부하 테스트를 돌렸는데 Logs Insights에서 아무 로그가 없다.

**원인 후보:**
- 로그 그룹 이름을 잘못 선택
- ECS 태스크가 실행은 되지만 CloudWatch로 로그를 못 보냄 (execution role 권한 부족)
- 시간 범위 설정 오류

**대응:**
1. ECS 콘솔 → 서비스 → 태스크 → 로그 탭에서 직접 확인
2. `execution role`에 `logs:CreateLogStream`, `logs:PutLogEvents` 권한 확인
3. CloudWatch Logs Insights 시간 범위를 테스트 전/후로 충분히 넓게 설정

---

*최종 업데이트: 2026-03-23*
