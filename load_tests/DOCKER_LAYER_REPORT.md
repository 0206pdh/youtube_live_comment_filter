# Docker 이미지 레이어 구성 리포트
## 부하 테스트 전 구간 컨테이너 빌드 전략

**작성일:** 2026-03-26
**작성자:** 0206pdh
**참조 파일:** `server/Dockerfile`, `load_tests/stage1_local/docker-compose.yml`, `load_tests/stage2_multi_local/docker-compose.yml`

---

## 목차

1. [Dockerfile 전문](#1-dockerfile-전문)
2. [레이어별 상세 설명](#2-레이어별-상세-설명)
3. [이미지 크기 분석](#3-이미지-크기-분석)
4. [레이어 캐싱 전략](#4-레이어-캐싱-전략)
5. [Phase별 컨테이너 구성 차이](#5-phase별-컨테이너-구성-차이)
6. [모델 번들 전략 (런타임 다운로드 vs 이미지 내 포함)](#6-모델-번들-전략)
7. [현재 구성의 한계와 개선 포인트](#7-현재-구성의-한계와-개선-포인트)

---

## 1. Dockerfile 전문

```dockerfile
FROM python:3.11-slim

# Python runtime defaults:
# - no .pyc files to keep image noise down
# - unbuffered logs so container logs appear immediately in CloudWatch/docker
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

# Install Python dependencies first so Docker layer caching is effective when
# only application code changes.
COPY server/requirements.txt /app/server/requirements.txt
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r /app/server/requirements.txt

# Copy application source and bundled base model.
COPY server /app/server
COPY model /app/model

EXPOSE 8000

ENV HOST=0.0.0.0
ENV PORT=8000

CMD ["python", "-m", "uvicorn", "app:app", "--app-dir", "/app/server", \
     "--host", "0.0.0.0", "--port", "8000"]
```

---

## 2. 레이어별 상세 설명

Docker는 `Dockerfile`의 각 명령어를 독립적인 레이어로 저장한다. 레이어는 **읽기 전용**이며 변경이 없으면 캐시를 재사용한다.

### 레이어 구조 한눈에 보기

```
┌─────────────────────────────────────────────────────┐
│  Layer 7  CMD / EXPOSE / ENV (메타데이터)            │  < 1 KB
├─────────────────────────────────────────────────────┤
│  Layer 6  COPY model /app/model                     │  ~440 MB
│           (모델 가중치 + 토크나이저 번들)               │
├─────────────────────────────────────────────────────┤
│  Layer 5  COPY server /app/server                   │  ~수 KB
│           (애플리케이션 소스코드)                      │
├─────────────────────────────────────────────────────┤
│  Layer 4  RUN pip install                           │  ~1,800 MB  ← 최대 레이어
│           (torch, transformers, fastapi 등)          │
├─────────────────────────────────────────────────────┤
│  Layer 3  COPY requirements.txt                     │  < 1 KB
├─────────────────────────────────────────────────────┤
│  Layer 2  WORKDIR /app                              │  < 1 KB
├─────────────────────────────────────────────────────┤
│  Layer 1  ENV PYTHONDONTWRITEBYTECODE / UNBUFFERED  │  < 1 KB
├─────────────────────────────────────────────────────┤
│  Layer 0  python:3.11-slim (베이스 이미지)            │  ~130 MB
└─────────────────────────────────────────────────────┘
                                          합계 ~2.4 GB
```

---

### Layer 0 — `python:3.11-slim` (베이스 이미지, ~130 MB)

`python:3.11` full 이미지(~920 MB) 대신 `slim` 변형을 선택했다.

| 이미지 | 크기 | 포함 내용 |
|--------|------|---------|
| `python:3.11` (full) | ~920 MB | gcc, g++, make, libssl-dev 등 빌드 도구 포함 |
| `python:3.11-slim` | ~130 MB | Python 런타임만. 빌드 도구 없음 |
| `python:3.11-alpine` | ~55 MB | musl libc 기반. wheel 호환성 문제 잦음 |

**slim을 선택한 이유:**
- `torch`, `psycopg2-binary`, `transformers` 모두 미리 컴파일된 wheel(`.whl`)로 제공된다. C 컴파일러(`gcc`)가 없어도 pip install이 가능하다.
- alpine은 musl libc 기반이라 PyTorch wheel과 호환 안 되는 경우가 많아 제외.

---

### Layer 1 — ENV 환경변수 (< 1 KB)

```dockerfile
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
```

| 변수 | 역할 |
|------|------|
| `PYTHONDONTWRITEBYTECODE=1` | `.pyc` 바이트코드 파일을 생성하지 않음. 이미지 크기 노이즈 방지. |
| `PYTHONUNBUFFERED=1` | stdout/stderr 출력 버퍼를 끔. 컨테이너 로그가 CloudWatch/docker logs에 즉시 나타남. 부하 테스트 중 실시간 로그 확인에 필수. |

---

### Layer 2 — `WORKDIR /app` (< 1 KB)

이후 모든 `COPY`, `RUN`, `CMD` 명령의 기준 경로를 `/app`으로 설정. 별도 레이어를 소비하지만 크기는 무시할 수준이다.

---

### Layer 3 — `COPY requirements.txt` (< 1 KB)

```dockerfile
COPY server/requirements.txt /app/server/requirements.txt
```

**소스 코드 전체(`COPY server`)가 아닌 `requirements.txt` 파일만 먼저 복사한다.**
이것이 레이어 캐싱 전략의 핵심이다. ([4장 레이어 캐싱 전략](#4-레이어-캐싱-전략) 참조)

---

### Layer 4 — `RUN pip install` (~1,800 MB, 최대 레이어)

```dockerfile
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r /app/server/requirements.txt
```

`requirements.txt` 설치 대상:

| 패키지 | 버전 | 역할 | 설치 크기(추정) |
|--------|------|------|--------------|
| `torch` | >=2.0.0 | BERT/ELECTRA 추론 엔진 | ~1,500 MB (CPU wheel) |
| `transformers` | ==4.41.2 | HuggingFace 모델 유틸리티 | ~300 MB |
| `fastapi` | ==0.111.0 | API 서버 프레임워크 | ~10 MB |
| `uvicorn[standard]` | ==0.30.1 | ASGI 서버 (WebSocket 지원 포함) | ~5 MB |
| `safetensors` | >=0.4.3 | 모델 가중치 포맷 로드 | ~1 MB |
| `pydantic` | >=2.6.0 | 요청/응답 스키마 검증 | ~10 MB |
| `scikit-learn` | >=1.3.0 | 재학습 유틸리티 | ~30 MB |
| `numpy` | >=1.24.0 | 행렬 연산 | ~20 MB |
| `boto3` | >=1.34.0 | AWS S3/SQS/SSM 연동 | ~15 MB |
| `psycopg2-binary` | >=2.9.9 | RDS PostgreSQL 연결 | ~5 MB |

**`--no-cache-dir` 플래그:**
pip가 다운로드한 wheel 파일을 캐시 디렉토리(`~/.cache/pip`)에 남기지 않는다. 이 캐시는 컨테이너 실행 중에는 사용되지 않으므로 레이어 크기만 늘릴 뿐이다. 이 옵션 하나로 레이어 크기를 수백 MB 절약한다.

**`&&`로 명령어 연결:**
`RUN pip install ... && pip install ...` 처럼 한 `RUN` 명령으로 묶으면 중간 상태가 레이어로 남지 않는다. 두 줄로 분리하면 업그레이드된 pip가 별도 레이어로 쌓여 최종 이미지 크기가 늘어난다.

---

### Layer 5 — `COPY server /app/server` (~수 KB)

```dockerfile
COPY server /app/server
```

포함 파일:

```
server/
  app.py          ← FastAPI 라우터, 추론 엔드포인트
  train.py        ← 재학습 로직 (scikit-learn + transformers)
  worker.py       ← SQS consumer (Phase 3B Training Worker)
  requirements.txt
```

코드 변경 시 이 레이어부터 이후 레이어의 캐시가 모두 무효화된다. Layer 4(pip install)는 앞에 있으므로 영향을 받지 않는다.

---

### Layer 6 — `COPY model /app/model` (~440 MB)

```dockerfile
COPY model /app/model
```

포함 파일:

```
model/
  model.safetensors     ← 학습된 가중치 파일 (~440 MB)
  config.json           ← beomi/KcELECTRA-base-v2022 아키텍처 설정
  tokenizer_config.json ← 토크나이저 설정
  vocab.txt             ← 한국어 어휘사전 (54,343 tokens)
  special_tokens_map.json
  training_args.bin
```

**모델 아키텍처:** `ElectraForSequenceClassification` (KcELECTRA-base-v2022)
- hidden_size: 768, num_attention_heads: 12, num_hidden_layers: 12
- 출력 클래스: 3개 (LABEL_0 / LABEL_1 / LABEL_2)
- vocab_size: 54,343 (한국어 특화)

모델 파일은 이미지 빌드 시점에 번들된다. 컨테이너 기동 시 HuggingFace Hub에서 다운로드하지 않는다. ([6장 모델 번들 전략](#6-모델-번들-전략) 참조)

---

### Layer 7 — ENV / EXPOSE / CMD (메타데이터)

```dockerfile
EXPOSE 8000
ENV HOST=0.0.0.0
ENV PORT=8000
CMD ["python", "-m", "uvicorn", "app:app", "--app-dir", "/app/server",
     "--host", "0.0.0.0", "--port", "8000"]
```

`CMD`는 레이어를 생성하지 않는다. 이미지 메타데이터에만 기록된다. docker-compose나 ECS Task Definition에서 오버라이드 가능하다.

---

## 3. 이미지 크기 분석

### 레이어별 크기

| 레이어 | 명령 | 크기 (추정) | 변경 빈도 |
|--------|------|------------|---------|
| 0 | `FROM python:3.11-slim` | ~130 MB | 거의 없음 |
| 1 | `ENV` | < 1 KB | 거의 없음 |
| 2 | `WORKDIR` | < 1 KB | 없음 |
| 3 | `COPY requirements.txt` | < 1 KB | 패키지 추가 시 |
| 4 | `RUN pip install` | ~1,800 MB | 패키지 추가 시 |
| 5 | `COPY server` | ~수 KB | 코드 수정마다 |
| 6 | `COPY model` | ~440 MB | 모델 재학습 시 |
| 7 | `ENV` / `EXPOSE` / `CMD` | < 1 KB | 거의 없음 |
| **합계** | | **~2.4 GB** | |

### 크기 비중

```
torch + transformers  ████████████████████████████████████████████████████████████ 75%  (~1,800 MB)
model 파일            ████████████████████ 18%  (~440 MB)
python:3.11-slim      █████ 5%   (~130 MB)
기타                  █ 2%   (~50 MB)
```

torch가 이미지 크기의 75%를 차지한다. CPU 전용 빌드(`torch+cpu`)를 명시하면 ~700MB로 줄일 수 있지만, GPU 전환 시 재빌드가 필요하다.

---

## 4. 레이어 캐싱 전략

### 핵심 원칙: 변경 빈도 낮은 레이어를 앞에

Docker는 레이어를 순서대로 빌드하다가 파일이 바뀐 시점부터 이후 레이어를 전부 재빌드한다. 따라서 **자주 바뀌는 레이어를 뒤로** 배치하는 것이 핵심이다.

```
변경 빈도:
  베이스 이미지      ← 거의 없음  (앞)
  패키지 목록        ← 드물게
  pip install       ← 드물게
  모델 파일          ← 재학습 시
  소스 코드          ← 자주         (뒤)
```

### 캐시 HIT/MISS 시나리오

#### 시나리오 A: 소스 코드만 수정 (가장 빈번한 케이스)

```
Layer 0  python:3.11-slim   → HIT  (변경 없음)
Layer 1  ENV                → HIT
Layer 2  WORKDIR            → HIT
Layer 3  COPY requirements  → HIT  (requirements.txt 변경 없음)
Layer 4  RUN pip install    → HIT  ← 1.8GB 재설치 생략 ✓
Layer 5  COPY server        → MISS (소스 변경 감지 → 재빌드 시작)
Layer 6  COPY model         → MISS (Layer 5 뒤라서 자동 무효화)
Layer 7  ENV/CMD            → MISS

총 재빌드 시간: ~10초 (Layer 5, 6 복사만)
캐시가 없을 경우: ~15~20분 (pip install 포함)
```

#### 시나리오 B: 패키지 추가 (requirements.txt 변경)

```
Layer 0~2   → HIT
Layer 3  COPY requirements  → MISS (파일 변경 감지)
Layer 4  RUN pip install    → MISS ← 전체 재설치 (~15분)
Layer 5~7   → MISS (자동 무효화)

총 재빌드 시간: ~15~20분
```

#### 시나리오 C: 모델 재학습 후 반영

```
Layer 0~4   → HIT
Layer 5  COPY server        → HIT  (코드 변경 없으면)
Layer 6  COPY model         → MISS (가중치 파일 변경 감지)
Layer 7   → MISS

총 재빌드 시간: ~30초 (440MB 파일 복사)
```

### `requirements.txt`를 코드보다 먼저 복사하는 이유

```dockerfile
# 현재 구조 (올바른 순서):
COPY server/requirements.txt ...   ← requirements만 먼저
RUN pip install ...                ← 캐시됨 (코드가 바뀌어도 영향 없음)
COPY server /app/server            ← 코드 전체 복사

# 잘못된 순서 (비효율):
COPY server /app/server            ← 코드 한 줄이라도 바뀌면
RUN pip install ...                ← 1.8GB pip install 전부 재실행 (매번 15분)
```

requirements.txt를 따로 분리해 먼저 COPY하는 것 하나만으로 코드 수정 시 빌드 시간이 **15분 → 10초** 로 줄어든다.

---

## 5. Phase별 컨테이너 구성 차이

동일한 `server/Dockerfile` 하나로 전 Phase를 커버한다. 환경 차이는 전부 `docker-compose.yml`과 환경변수로 분리했다.

### Phase 1 (Stage 1) — 단일 컨테이너

```yaml
# load_tests/stage1_local/docker-compose.yml

services:
  server:
    build:
      context: ../..
      dockerfile: server/Dockerfile   # 공통 Dockerfile
    ports:
      - "8000:8000"
    volumes:
      - server_data:/app/user_data    # 로컬 Docker Volume
    environment:
      ENFORCE_AUTH: "false"
      ENABLE_RATE_LIMIT: "true"
      # TRAINING_DATA_BUCKET 없음 → 로컬 파일시스템 폴백
      # DB_HOST 없음 → RDS 미사용
```

```
[클라이언트] → :8000 → [server 컨테이너]
                              │
                        [Docker Volume]  (server_data)
                        user_data/ 로컬 파일
```

- 컨테이너 1개
- 스토리지: Docker Named Volume (컨테이너 재시작 시 데이터 유지, 삭제 시 소실)
- 이미지: 로컬 빌드 (`docker compose build`)

---

### Phase 2 (Stage 2) — 2개 컨테이너 + nginx

```yaml
# load_tests/stage2_multi_local/docker-compose.yml

services:
  nginx:
    image: nginx:alpine               # 별도 이미지 (빌드 불필요)
    ports:
      - "8080:80"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro

  server_a:
    build:
      context: ../..
      dockerfile: server/Dockerfile   # server와 동일 Dockerfile
    volumes:
      - server_a_data:/app/user_data  # server_a 전용 Volume

  server_b:
    build:
      context: ../..
      dockerfile: server/Dockerfile   # 동일 이미지, 별도 컨테이너
    volumes:
      - server_b_data:/app/user_data  # server_b 전용 Volume (격리)
```

```
[클라이언트] → :8080 → [nginx:alpine]
                            │ 라운드로빈
               ┌────────────┴────────────┐
          [server_a]               [server_b]
               │                        │
        [server_a_data]          [server_b_data]   ← 완전 격리된 Volume
```

- 컨테이너 3개 (nginx + server_a + server_b)
- `server_a`, `server_b`는 **동일한 이미지**를 사용하지만 서로 다른 Volume을 마운트
- nginx는 `nginx:alpine` 공개 이미지 (Dockerfile 빌드 없음)
- 이 구성에서 데이터 불일치율 100% 실증

**레이어 캐싱 효과:** `server_a`와 `server_b`는 같은 이미지이므로 `docker compose build` 시 한 번만 빌드된다. `docker compose up --scale` 형태가 아니라 명시적으로 두 서비스로 분리한 이유는 `INSTANCE_ID` 환경변수로 어느 서버가 응답했는지 추적하기 위해서다.

---

### Phase 3A (ECS EC2/Fargate) — 클라우드 배포

```
로컬 빌드 → ECR(Elastic Container Registry) push → ECS Task 실행

docker build -t ylcf-server .
docker tag ylcf-server:latest <account>.dkr.ecr.ap-northeast-2.amazonaws.com/ylcf-dev:latest
docker push <account>.dkr.ecr.ap-northeast-2.amazonaws.com/ylcf-dev:latest
```

```
[클라이언트]
    │
[API Gateway]
    │
[ALB (Application Load Balancer)]
    │
[ECS Task — ylcf-server 컨테이너]
    ├── 환경변수: TRAINING_DATA_BUCKET, DB_HOST 등 (SSM → ECS 주입)
    ├── 스토리지: S3 버킷 (로컬 파일시스템 없음)
    └── DB: RDS PostgreSQL
```

- docker-compose 없음. ECS Task Definition으로 대체.
- 이미지 출처: ECR (로컬 Docker daemon이 아님)
- 환경변수는 SSM Parameter Store → ECS Task 실행 시 주입
- `TRAINING_DATA_BUCKET` 환경변수가 있으면 S3로, 없으면 로컬 파일로 자동 폴백하도록 코드 분기

---

### Phase 3B (ECS) — Training Worker 분리

```
[API Task]          [Worker Task]
  image: ylcf-server  image: ylcf-server   ← 동일 이미지
  CMD: uvicorn app:app  CMD: python worker.py  ← 다른 CMD
  CPU: 512 units      CPU: 1024 units
  역할: 추론 전용     역할: 재학습 전용 (SQS consumer)
```

두 Task가 **동일한 이미지**를 사용하고 실행 명령(`CMD`)만 다르다. Worker Task는 `worker.py`를 실행해 SQS 메시지를 polling하며 재학습을 처리한다. 이미지를 분리하지 않아도 되므로 ECR에 이미지 하나만 유지하면 된다.

---

## 6. 모델 번들 전략

### 선택: 이미지에 번들 (Runtime 다운로드 대신)

| 방식 | 설명 | 장점 | 단점 |
|------|------|------|------|
| **이미지 번들** (현재) | `COPY model /app/model` → 이미지에 포함 | Cold start 없음, 네트워크 독립적 | 이미지 크기 +440MB, ECR push 느림 |
| Runtime 다운로드 | 컨테이너 시작 시 HuggingFace Hub에서 다운로드 | 이미지 경량 | Cold start ~30~60초, 네트워크 의존 |
| S3 마운트 | 컨테이너 시작 시 S3에서 다운로드 | 이미지 경량, 버전 관리 용이 | Cold start ~5~15초, S3 비용 |

**이미지 번들을 선택한 이유:**
1. ECS 태스크가 시작될 때 모델을 다운로드하지 않아도 된다 → cold start 없음
2. HuggingFace Hub 장애나 네트워크 문제와 무관하게 서비스 가동 가능
3. `snunlp/KR-FinBert-SC` 또는 `beomi/KcELECTRA-base-v2022` 모델은 재학습으로 가중치가 바뀌므로, 어차피 커스텀 파일을 포함해야 함

---

## 7. 현재 구성의 한계와 개선 포인트

### 한계 1: 레이어 순서 최적화 여지

현재:
```dockerfile
COPY server /app/server   ← Layer 5: 코드 (자주 바뀜)
COPY model /app/model     ← Layer 6: 모델 (드물게 바뀜)
```

코드를 수정하면 Layer 5 캐시가 깨지면서 Layer 6(440MB) 도 **덩달아 재복사**된다.

개선:
```dockerfile
COPY model /app/model     ← 모델 먼저 (코드 변경에 영향받지 않음)
COPY server /app/server   ← 코드 나중에
```

이 순서라면 코드만 바뀔 때 모델 레이어는 캐시 HIT → 코드 변경 시 빌드 시간 추가 단축.
단, ECR에 push된 레이어는 이미 콘텐츠 해시 기반으로 캐시되므로 ECS 배포 시 실질적 차이는 제한적이다.

---

### 한계 2: 이미지 크기 (~2.4 GB)

torch CPU 빌드가 ~1.5GB로 이미지의 절반 이상을 차지한다.

| 개선 방법 | 예상 효과 | 비고 |
|---------|---------|------|
| `torch+cpu` 명시 설치 | ~700MB 절약 (GPU 빌드 제외) | GPU 전환 시 재빌드 필요 |
| ONNX Runtime으로 전환 | torch 불필요 → ~1.5GB 절약 | 추론 전용, 재학습 별도 처리 필요 |
| Multi-stage build | 빌드용 도구를 최종 이미지에서 제외 | 현재 slim이라 효과 제한적 |

---

### 한계 3: `.dockerignore` 미확인

빌드 컨텍스트(`context: ../..`)가 프로젝트 루트이므로, `.dockerignore`가 없으면 `load_tests/`, `infra/`, `.git/` 등 불필요한 파일이 빌드 컨텍스트에 포함되어 `docker build` 전송 시간이 늘어난다.

권장 `.dockerignore`:
```
.git/
.github/
load_tests/
infra/
test/
*.md
*.pyc
__pycache__/
.env
```

---

### 요약

| 항목 | 선택 | 이유 |
|------|------|------|
| 베이스 이미지 | `python:3.11-slim` | full 대비 790MB 절약, wheel 호환 |
| pip 캐시 | `--no-cache-dir` | 레이어 크기 수백 MB 절약 |
| 레이어 순서 | requirements → 코드 → 모델 | pip install 캐시 HIT 유지 |
| 모델 배포 | 이미지 번들 | Cold start 없음, 네트워크 독립 |
| 환경 분리 | 환경변수 + docker-compose | Dockerfile 하나로 전 Phase 커버 |
| nginx | `nginx:alpine` (별도 이미지) | 빌드 불필요, 경량 |
| Worker 분리 | 동일 이미지 + CMD 변경 | ECR 이미지 하나로 API + Worker 모두 운영 |

---

*작성일: 2026-03-26*
*작성자: 0206pdh*
