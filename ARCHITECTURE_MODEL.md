# 아키텍처 — 모델 (Model)

유튜브 라이브 채팅 텍스트를 3단계 악성도로 분류하는 한국어 BERT 계열 모델과,
그 모델을 서빙 · 재학습 · 무중단 교체하는 파이프라인을 정리한다.

관련 소스: `server/app.py`, `server/worker.py`, `server/train.py`, `model/`,
`test/backtranslate_ko.py`

---

## 1. 모델 개요

| 항목 | 값 |
|---|---|
| 베이스 모델 | `beomi/KcELECTRA-base-v2022` (`server/run.bat`의 `HF_MODEL_ID` 기본값) |
| 아키텍처 | `ElectraForSequenceClassification` (hidden 768, layer 12, head 12) |
| 어휘 | 한국어 특화 vocab 54,343 tokens (`vocab.txt`) |
| 출력 | 3-class 분류 |
| 추론 디바이스 | CPU (`torch`, CUDA 있으면 자동 사용) |
| 최대 시퀀스 길이 | 256 tokens (`predict`, `train.py` 공통) |
| 가중치 파일 | `model/model.safetensors` (약 440 MB) |

### 라벨 정의 (`server/app.py` `LABEL_NAMES`)

| label | 이름 | 확장 프로그램 표기 | 의미 |
|---|---|---|---|
| 0 | `normal` | 정상 | 일반 댓글 |
| 1 | `borderline_abusive` | 약간 악성 | 경계성 표현 |
| 2 | `abusive` | 악성 | 명백한 욕설/혐오 |

---

## 2. 추론 (Inference)

### 2.1 모델 로드

`server/app.py`의 `_load_model()`이 프로세스 시작 시 **한 번만** 토크나이저/모델을
메모리에 적재하고 `model.eval()` 상태로 고정한다. 매 요청마다 로드하지 않으므로
콜드스타트 이후에는 상시 상주 메모리에서 즉시 응답한다.

- 로드 완료 여부는 `MODEL_READY` 플래그로 관리되고 `GET /health/ready`에 반영된다.
  → ALB / ECS는 모델이 올라온 태스크에만 트래픽을 보낸다.

### 2.2 예측 경로 `POST /predict`

```
texts[] → tokenizer(padding, truncation, max_length=256)
        → model(**encoded)  (torch.no_grad)
        → softmax(logits)   → probs
        → argmax            → labels(0/1/2)
        → PredictResponse { labels, probs, label_names }
```

- **배치 처리**: 확장 프로그램이 여러 댓글을 한 번에 보내고 서버는 배치로 토크나이즈·추론한다.
  요청 오버헤드를 줄이고 컨테이너 처리량을 높인다.
- 요청마다 `PREDICT_METRIC` 로그(배치 크기, 문자 수, latency, 라벨 분포)를 남겨
  before/after 부하 분석의 원자료로 사용한다. (`TrafficMetrics`)

### 2.3 모델 버전 선택 (기동 시)

`server/app.py`의 `_sync_promoted_model()`:

1. S3 `models/latest.json` 포인터를 읽는다.
2. 포인터가 있으면 `models/{version}/` 아티팩트를 `user_data/model/`로 내려받고 이를 사용한다.
3. 포인터가 없거나 다운로드 실패 시 **이미지에 번들된 `/app/model`**로 폴백한다.
4. `version` 문자열은 화이트리스트 문자만 허용(경로 조작 방지).

즉 서비스는 항상 "승격된 최신 모델 or 번들 기본 모델" 중 하나로 안전하게 뜬다.

---

## 3. 학습 데이터 (Training Data)

### 3.1 수집

확장 프로그램의 **학습 모드**에서 사용자가 댓글을 클릭 → 라벨(0/1/2) 선택 →
`POST /training-data` → 서버가 일자별 JSONL 파일에 append.

| 저장소 | 경로 | 용도 |
|---|---|---|
| S3 (클라우드) | `training-data/training_data_YYYY-MM-DD.jsonl` | 영구 학습 데이터 |
| S3 (클라우드) | `training-temp/...` | 캐시성 임시 라벨 (`?temp=1`) |
| 로컬 | `user_data/training_data/`, `user_data/training_temp/` | 로컬 모드 |

레코드 형식: `{"text", "label", "user_id", "timestamp"}`

- `POST /training-data/lookup`: 이미 라벨된 텍스트는 모델 호출 없이 캐시 라벨을 반환.
- `/training-data/stats*`, `/training-data/files*`: 확장 프로그램 팝업에서 데이터 조회·삭제.
- S3 라이프사이클으로 `training-data/` 접두사는 일정 기간 후 만료(dev/prod 상이).

### 3.2 증강

- `server/train.py`의 `load_training_data(augment_factor=3000)`: 각 원본 샘플을
  그대로 복제해 데이터 양을 늘리는 단순 증강. 소량 라벨로 학습 파이프라인을 돌리기 위한 장치.
- `test/backtranslate_ko.py`: MarianMT 역번역(ko→en→ko) 기반 문장 다양화 스크립트(오프라인 도구).

---

## 4. 학습 (Fine-tuning) — `server/train.py`

HuggingFace `Trainer` 기반 추가 학습(기존 모델 위에 이어서 학습).

| 하이퍼파라미터 | 값 |
|---|---|
| epochs | 3 |
| batch size | 16 (train/eval) |
| learning rate | 2e-5 |
| warmup steps | 100 |
| weight decay | 0.01 |
| max length | 256 |
| train/val split | 80 / 20 (`random_split`) |
| eval / save strategy | steps (eval 50, save 100) |
| best model 기준 | `f1` (weighted), `load_best_model_at_end` |
| early stopping | patience 3 |
| 로깅 | `report_to=None` (wandb 비활성) |

`compute_metrics`로 accuracy / f1 / precision / recall(weighted) 계산.
완료 시 `trainer.save_model()` + `tokenizer.save_pretrained()`로 산출물 저장.

---

## 5. 비동기 재학습 & 무중단 모델 교체 (MLOps)

### 5.1 문제 정의

기존(Stage 1)에는 `/model/retrain`이 API 프로세스 내부 **백그라운드 스레드**로
BERT fine-tuning을 돌렸다. → 같은 CPU를 추론과 학습이 경합 → 재학습 중 추론 오류율 약 50%.
vCPU를 늘려도 해소되지 않는 **구조적** 문제였다. 해결책은 학습을 별도 프로세스/컨테이너로 격리.

### 5.2 재학습 트리거 — `POST /model/retrain` (`server/app.py`)

```
1. TRAINING_STATUS.is_training 중복 체크
2. 현재 학습 샘플 수 카운트
3. RDS training_runs 테이블에 'queued' 레코드 INSERT → run_id 획득
4. SQS 큐에 {action:"retrain", run_id, sample_count, triggered_at} 발행
5. 즉시 200 반환 (호출자 대기 없음)
   └ TRAINING_QUEUE_URL 미설정 시: 로컬 BackgroundTasks 스레드로 폴백
```

### 5.3 학습 Worker — `server/worker.py`

API와 **동일한 Docker 이미지**를 쓰되 CMD를 `python /app/server/worker.py`로 override.
ALB 없이 SQS 롱폴링(`WaitTimeSeconds=20`)만 수행하는 단일 Fargate 태스크.

처리 흐름 (`process()`):

| 단계 | 내용 |
|---|---|
| 1 | 메시지 수신 → `run_id` 파싱 |
| 2 | `claim_run()`: `training_runs` 상태를 `queued/failed → running` (조건부 UPDATE). 이미 처리된 run_id면 메시지만 삭제하고 무시 → **at-least-once 중복 방지** |
| 3 | S3 `training-data/*.jsonl` 전량 다운로드 (없으면 실패) |
| 4 | `models/latest.json`이 가리키는 현재 활성 모델을 base로 다운로드 + `validate_model()`(라벨 3개 검증) → 이어서 학습 |
| 5 | `train.train_model()` 호출 |
| 6 | 산출물 `validate_model()` 재검증 (`num_labels == 3`) |
| 7 | `version = {UTC timestamp}-{run_id}` 생성, `models/{version}/`로 S3 업로드 |
| 8 | `promote_model()` — 아래 5.4 |
| 9 | `finish_run()`: `training_runs` → `success`(+model_version) 또는 `failed`(+error_message) |
| 10 | SQS 메시지 삭제 |

**긴 학습 보호 장치**:
- `visibility_heartbeat`: 백그라운드 스레드가 주기적으로 `ChangeMessageVisibility`(3600s)를
  연장 → 15~30분 학습 중 메시지가 다시 보이게 되어 중복 실행되는 것을 방지.
- 실패 시 `training_runs`에 에러 기록, 메시지는 삭제하지 않음 → SQS 재시도 → `maxReceiveCount`
  초과 시 DLQ로 이동(CloudWatch 알람).

### 5.4 무중단 모델 교체 — `promote_model()`

```
1. 현재 포인터(previous) 백업
2. S3 models/latest.json 을 새 version 으로 갱신
3. ECS API 서비스 update_service(forceNewDeployment=true) — 롤링 배포
4. get_waiter("services_stable") 로 새 태스크가 안정화될 때까지 대기
5. deployments[0].rolloutState == FAILED 이면 예외
   └ 예외 시: 포인터를 previous 로 복원 → 다시 롤링 배포 → 재대기 (자동 롤백)
```

- 새 API 태스크는 기동 시 `_sync_promoted_model()`로 새 모델을 받고,
  `/health/ready` 통과 후에만 ALB 타깃에 편입된다.
- ECS 배포에 `deployment_circuit_breaker { rollback = true }`가 걸려 있어
  Worker 로직과 ECS 양쪽에서 실패 배포가 회수된다.
- 결과: **잘못된 모델이 정상 트래픽을 받지 않는다.**

### 5.5 상태 조회

- `GET /model/training-status` — 확장 프로그램 팝업이 폴링(2초).
- `POST /model/reload` — 로컬/단일 인스턴스에서 최신 모델 재적재.
- RDS `training_runs` — 재학습 이력 감사 로그(created/started/completed, status, model_version, error).

---

## 6. 전체 데이터 흐름

```
[확장 프로그램] --POST /predict--------> [ECS API: KcELECTRA 추론] --probs/labels-->
[확장 프로그램] --POST /training-data--> [ECS API] --append--> [S3 training-data/*.jsonl]
[확장 프로그램] --POST /model/retrain--> [ECS API] --INSERT--> [RDS training_runs]
                                              |
                                              +--publish {run_id}--> [SQS queue]
                                                                        |
                                    [ECS Worker] <--long-poll-----------+
                                          |  download data + active model (S3)
                                          |  train.py (HF Trainer)
                                          |  validate (num_labels==3)
                                          +--upload--> [S3 models/{version}/]
                                          +--put-----> [S3 models/latest.json]
                                          +--forceNewDeployment--> [ECS API 롤링 교체]
                                          +--실패 시 이전 포인터 복원 + 재배포 (롤백)
```

---

## 7. 정량 효과 (동일 4 vCPU, 구조 변경 순수 효과)

| 지표 | Stage 1 (스레드) | Worker 분리 | 개선 |
|---|---:|---:|---:|
| 재학습 중 추론 p95 | 866 ms | 107 ms | -87.6% |
| 재학습 중 추론 오류율 | 49.93% | 0.00% | 완전 해소 |

상세: `finalresult.md`, `docs/PROJECT_OVERVIEW.md`, `load_tests/COMPARISON.md`
