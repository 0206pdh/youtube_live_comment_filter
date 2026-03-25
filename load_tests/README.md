# 부하 테스트 실행 가이드

## 순서 개요

```
Stage 1 (단일 Docker + 로컬) → Stage 2 (2개 Docker + nginx + 로컬) → Stage 3 (ECS Fargate + S3 + RDS)
```

각 Stage에서 동일한 3가지 시나리오(Baseline / Spike / Soak)를 실행하고 결과를 COMPARISON.md에 기록.

---

## 사전 준비

```bash
# k6 설치 (Windows)
choco install k6

# 설치 확인
k6 version
```

---

## Stage 1: 단일 Docker + 로컬 파일시스템

```bash
# 서버 시작
cd load_tests/stage1_local
docker compose up --build -d

# 서버 준비 확인 (ready 될 때까지 대기, 모델 로딩 1~2분 소요)
curl http://localhost:8000/health/ready

# k6 실행 (load_tests/ 루트에서)
cd ..
k6 run -e BASE_URL=http://localhost:8000 --out json=results/stage1_baseline.json scripts/baseline.js
k6 run -e BASE_URL=http://localhost:8000 --out json=results/stage1_spike.json    scripts/spike.js
k6 run -e BASE_URL=http://localhost:8000 --out json=results/stage1_soak.json     scripts/soak.js

# 서버 종료
cd stage1_local
docker compose down
```

---

## Stage 2: Docker 2개 + nginx + 로컬 파일시스템 (데이터 불일치 재현)

```bash
# 서버 2개 + nginx 시작
cd load_tests/stage2_multi_local
docker compose up --build -d

# 서버 준비 확인
curl http://localhost:8080/health/ready

# k6 실행
cd ..
k6 run -e BASE_URL=http://localhost:8080 --out json=results/stage2_baseline.json    scripts/baseline.js
k6 run -e BASE_URL=http://localhost:8080 --out json=results/stage2_spike.json       scripts/spike.js
k6 run -e BASE_URL=http://localhost:8080 --out json=results/stage2_soak.json        scripts/soak.js

# 핵심: 데이터 불일치 증명
k6 run -e BASE_URL=http://localhost:8080 --out json=results/stage2_consistency.json scripts/consistency_check.js

# 서버 종료
cd stage2_multi_local
docker compose down
```

---

## Stage 3: ECS Fargate + S3 + RDS

```bash
# terraform apply 완료 후 API Gateway URL 확인
cd infra/environments/dev
terraform output api_gateway_endpoint

# k6 실행 (API_KEY는 terraform.tfvars의 api_key_placeholder 값)
cd ../../..
API_URL="https://xxxxxxxxxx.execute-api.ap-northeast-2.amazonaws.com"
API_KEY="ylcf-api-key-change-me-592905556313"

k6 run -e BASE_URL=$API_URL -e API_KEY=$API_KEY --out json=load_tests/results/stage3_baseline.json load_tests/scripts/baseline.js
k6 run -e BASE_URL=$API_URL -e API_KEY=$API_KEY --out json=load_tests/results/stage3_spike.json    load_tests/scripts/spike.js
k6 run -e BASE_URL=$API_URL -e API_KEY=$API_KEY --out json=load_tests/results/stage3_soak.json     load_tests/scripts/soak.js

# Stage 3에서는 불일치율 0% 확인
k6 run -e BASE_URL=$API_URL -e API_KEY=$API_KEY --out json=load_tests/results/stage3_consistency.json load_tests/scripts/consistency_check.js
```

---

## 결과 기록

테스트 완료 후 `load_tests/COMPARISON.md` 의 `-` 값들을 실제 측정값으로 채운다.

측정해야 할 주요 지표:
- `http_req_duration` → p50, p95, p99
- `error_rate` → 오류율 %
- `http_reqs` → 총 요청 수, RPS
- `consistency_miss_rate` → 불일치율 (Stage 2, 3)
