# MLOPS

이 문서는 현재 프로젝트의 데이터셋 관리, 모델 학습, 검증, 승격 기준을 정의한다. 현재 구현은 단일 서비스 내부의 간단한 재학습 흐름이지만, 향후 S3/RDS/SQS/Model Registry 기반 구조로 확장하는 것을 전제로 작성한다.

## 1. 현재 상태 요약

현재 모델 운영 방식:

- 기본 모델은 저장소의 `model/` 디렉터리에 포함
- 서비스는 시작 시 기본 모델 또는 `user_data/model/`의 갱신 모델을 로드
- extension과 서버가 수집한 라벨 데이터는 `user_data/training_data/` 및 `user_data/training_temp/`에 저장
- 서버 API를 통해 재학습과 모델 reload를 트리거 가능

현재 구조의 장점:

- 빠르게 실험 가능
- 단일 서버에서 수집, 재학습, 재적재까지 연결 가능

현재 구조의 한계:

- 인스턴스 로컬 상태 의존
- 데이터셋 버전 관리 미흡
- 실험 재현성 부족
- 모델 승격 기준이 코드/문서로 강제되지 않음

## 2. 목표

목표:

- 데이터셋과 모델을 버전 단위로 관리
- 학습 성공만으로 배포하지 않고 검증 기준을 통과해야 승격
- 운영 모델과 실험 모델을 구분
- 롤백 가능한 배포 구조 확보

## 3. 데이터셋 정의

데이터셋의 기본 단위는 “텍스트 + 라벨 + 수집 메타데이터”다.

최소 필드:

- `text`
- `label`
- `user_id` 또는 수집 주체 식별자
- `created_at`
- `source`
- `dataset_version`

현재 라벨 체계:

- `0`: normal
- `1`: borderline_abusive
- `2`: abusive

## 4. 데이터셋 품질 기준

학습 데이터로 승격되기 전 최소 기준:

- 비어 있는 텍스트 제거
- 지나치게 짧은 텍스트 제거 규칙 검토
- 중복 데이터 제거 또는 중복 비율 측정
- 라벨 값 범위 검증
- 손상된 JSONL 레코드 제거

권장 품질 점검:

- 클래스 분포 편향 확인
- 특정 사용자/소스에 과도하게 치우친 데이터 확인
- 욕설 사전 기반 rule-only 데이터가 과대표집되지 않았는지 확인

## 5. 데이터셋 버전 정책

현재 임시 규칙:

- 로컬 파일 기준으로 날짜 단위 또는 학습 배치 단위 버전 부여

향후 표준 규칙:

- `dataset_version = YYYYMMDD-N`
- raw, cleaned, train, validation, test 분리

향후 S3 구조 예시:

- `raw/training/yyyy/mm/dd/*.jsonl`
- `processed/dataset/{dataset_version}/train.jsonl`
- `processed/dataset/{dataset_version}/validation.jsonl`
- `processed/dataset/{dataset_version}/test.jsonl`

## 6. 학습 정책

현재 정책:

- 서버 내부에서 재학습 job을 시작
- 완료 후 갱신 모델을 `user_data/model/`에 반영

향후 정책:

- 학습은 추론 API와 분리된 worker 또는 전용 job에서 수행
- 학습 실행 시 다음 메타데이터를 남긴다:
  - `dataset_version`
  - `base_model_version`
  - `training_code_version`
  - `hyperparameters`
  - `metrics`
  - `artifact_location`

## 7. 모델 검증 기준

새 모델이 승격되기 위한 최소 기준:

- validation set에서 이전 운영 모델 대비 성능이 유지 또는 개선
- abusive 클래스 recall이 기준 이하로 하락하지 않을 것
- overall F1이 기준 이하로 하락하지 않을 것
- 추론 latency가 운영 허용 범위를 크게 벗어나지 않을 것
- 샘플 기반 수동 검토에서 명백한 회귀가 없을 것

현재 권장 숫자 기준:

- macro F1: 이전 운영 모델 대비 `-0.02` 초과 하락 금지
- abusive recall: 이전 운영 모델 대비 `-0.03` 초과 하락 금지
- borderline_abusive precision: 이전 운영 모델 대비 `-0.05` 초과 하락 금지
- p95 inference latency: 운영 기준 대비 20% 초과 악화 금지

이 숫자는 초기 가이드라인이며, 실제 데이터 축적 후 조정한다.

## 8. 모델 승격 단계

### Stage 1. Experimental

조건:

- 데이터셋 생성 완료
- 학습 job 성공
- 기본 메트릭 산출 완료

용도:

- 개발자 실험
- 로컬 검증

### Stage 2. Candidate

조건:

- validation/test 메트릭 통과
- 기준 샘플셋 수동 검토 통과
- 성능 회귀 없음

용도:

- dev 환경 배포 후보

### Stage 3. Staging or Dev Approved

조건:

- dev 환경 실트래픽 또는 준실트래픽 검증 통과
- `/predict` latency, 5xx, 로그 이상 없음
- auth/rate limit/CORS와 함께 정상 동작 확인

용도:

- prod 승격 직전 상태

### Stage 4. Production

조건:

- 운영 승인
- 배포 전 롤백 버전 지정
- 배포 후 health/latency/오류율 기준 충족

## 9. 모델 승격 게이트

prod 승격 전 반드시 충족:

1. 데이터셋 버전 고정
2. 학습 코드 버전 고정
3. 메트릭 리포트 저장
4. 비교 대상 운영 모델 지정
5. 최소 수동 샘플 리뷰 완료
6. dev 환경 배포 검증 완료
7. 롤백 가능 버전 확보

## 10. 롤백 정책

즉시 롤백 조건:

- 5xx 증가
- latency 급증
- abusive 분류 성능 회귀가 사용자 피드백으로 확인
- 정상 댓글 오탐 급증

롤백 방법:

- 이전 production 모델 아티팩트를 다시 활성화
- ECS 재배포 또는 model reload로 이전 버전 복귀

향후 model registry 도입 시:

- `production -> previous production` 전환 절차를 표준화

## 11. 평가 지표

필수 지표:

- accuracy
- macro precision
- macro recall
- macro F1
- class-wise precision/recall/F1
- confusion matrix

운영 지표:

- p50/p95 inference latency
- error rate
- request volume
- label distribution drift

향후 추가 지표:

- false positive review rate
- false negative review rate
- data drift score
- concept drift indicators

## 12. 수동 리뷰 기준

자동 메트릭만으로 승격하지 않는다. 다음 샘플셋을 검토한다.

- 명백한 욕설
- 경계성 표현
- 정상 대화
- 은어/변형 표현
- 반복 스팸

리뷰 시 확인:

- 정상 댓글 오탐 증가 여부
- borderline_abusive가 과도하게 normal 또는 abusive로 쏠리지 않는지
- 최근 유행 표현에 대한 대응력

## 13. 향후 목표 아키텍처

README 기준 목표 구조:

- raw 데이터: S3
- 메타데이터: RDS PostgreSQL
- 비동기 수집/전처리: SQS + worker
- 학습/배치 작업: ECS one-off task 또는 SageMaker job
- 모델 저장/승격: Model Registry 또는 MLflow

향후 표준 흐름:

1. raw data 수집
2. 정제 및 데이터셋 생성
3. 학습
4. 검증
5. candidate 등록
6. dev 승격
7. prod 승격
8. 모니터링
9. 필요 시 롤백

## 14. 문서화와 감사 추적

모든 학습/승격 이벤트는 아래 정보를 남긴다.

- 실행 시각
- 실행자 또는 workflow
- dataset version
- model version
- metrics summary
- 배포 환경
- rollback target

현재는 수동 기록 비중이 크지만, 향후 CI/CD와 registry에서 자동 수집하도록 확장한다.
