# SLO

이 문서는 현재 서비스의 목표 지표, 측정 방식, 에러 버짓 정책을 정의한다. 지금은 Phase 1 수준의 단일 추론 서비스 운영을 기준으로 하고, 이후 Phase 2+ 구조 확장 시 지표를 분리한다.

## 1. 목적

SLO의 목적:

- 사용자 체감 품질을 수치로 정의
- 장애와 성능 저하를 빠르게 감지
- 배포 속도와 안정성의 균형을 맞춤
- 에러 버짓 기반으로 변경 속도를 조절

## 2. 서비스 범위

현재 SLO 대상:

- public dev/prod 추론 API
- health check 엔드포인트
- extension이 호출하는 예측 경로

현재 핵심 사용자 경로:

1. Extension이 텍스트를 수집
2. `/predict` 또는 캐시 조회 API 호출
3. 서버가 모델 추론 결과를 반환
4. extension이 차단 규칙을 적용

따라서 현재 SLO는 “예측 요청이 성공적으로, 빠르게, 안정적으로 처리되는가”에 집중한다.

## 3. 지표 정의

### 가용성

정의:

- 유효한 클라이언트 요청 중 성공적으로 응답한 비율

성공 기준:

- `/predict`: 2xx
- `/health`, `/health/live`, `/health/ready`: 200

실패 기준:

- 5xx
- 타임아웃
- ALB/API Gateway/ECS 장애로 인한 응답 실패

인증 실패와 잘못된 요청:

- 4xx 중 인증 실패, 잘못된 요청은 기본 가용성 분모에서 제외할 수 있다.
- 다만 보안/구성 이상 탐지용 보조 지표로는 별도 추적한다.

### 지연시간

정의:

- `/predict` 요청의 end-to-end latency

우선 지표:

- p50 latency
- p95 latency
- p99 latency

### 오류율

정의:

- 전체 유효 요청 중 5xx 또는 내부 처리 실패 비율

### 품질 보조 지표

- auth failure rate
- rate limit rejection count
- ALB healthy target 수
- ECS task restart count

## 4. 목표값

현재 Phase 1 권장 SLO:

- Availability: 99.5% / 30일
- `/predict` p95 latency: 1000ms 이하
- `/predict` p99 latency: 2000ms 이하
- 5xx error rate: 1% 미만 / 1시간 롤링
- `/health/live`, `/health/ready` 성공률: 99.9% / 30일

이 수치는 현재 구조가 단일 모델 프로세스와 제한된 운영 자동화 수준임을 반영한 보수적 목표다.

향후 Phase 3~4 목표:

- Availability: 99.9%
- `/predict` p95 latency: 300ms 이하
- 5xx error rate: 0.5% 미만

## 5. 에러 버짓

### 계산

월간 availability SLO가 99.5%이면 허용 다운타임은 약 3시간 39분이다.

예시:

- 30일 기준 총 시간: 720시간
- 실패 허용률: 0.5%
- 허용 실패 시간: 약 3.6시간

### 에러 버짓 사용 정책

정상 범위:

- 버짓 사용량 25% 이하: 일반 배포 진행 가능

주의 범위:

- 버짓 사용량 25% 초과 50% 이하: 대형 변경 전 사전 검토

경고 범위:

- 버짓 사용량 50% 초과 75% 이하: 신규 기능보다 안정화 우선

중단 범위:

- 버짓 사용량 75% 초과: 프로덕션 신규 변경 동결, 안정화 작업 우선

## 6. 알람 기준

즉시 알람:

- `/health/ready` 실패 지속
- ALB healthy target 0
- ECS running task 0
- 5xx 급증
- p95 latency 급등

경고 알람:

- auth failure rate 급증
- WAF 차단 급증
- rate limit rejection 증가

## 7. 측정 위치

현재 측정 소스:

- API Gateway access logs
- CloudWatch logs
- FastAPI 구조화 로그
- ALB health check 상태
- ECS 서비스 상태

애플리케이션 로그에서 추적 가능한 값:

- 요청 수
- 응답 코드 분포
- latency
- 배치 크기
- 문자 수
- 라벨 분포
- auth failures
- rate limit rejections

## 8. 운영 해석 기준

지연시간만 높고 성공률은 정상이면:

- 성능 저하 이슈로 본다.
- noisy client, 배치 크기, 모델 크기, CPU/메모리 압박을 확인한다.

성공률도 함께 떨어지면:

- 장애 대응 모드로 전환한다.
- 최근 배포, task 재시작, secret 반영 실패를 우선 의심한다.

auth failure만 급증하면:

- 가용성 사고라기보다 인증/설정 사고일 가능성이 높다.
- API Key 회전 또는 extension 설정 불일치를 확인한다.

## 9. 향후 분리 계획

Phase 2 이후에는 SLO를 최소 3개로 분리한다.

- Inference API SLO
- Training pipeline SLO
- Model promotion/reload SLO

예시:

- inference latency/availability
- training job completion success rate
- model promotion lead time

## 10. 리뷰 주기

- 주간: 성능 추이 리뷰
- 월간: SLO 달성률 및 에러 버짓 리뷰
- 분기: 목표값 재설정

변경이 필요한 경우:

- 모델 크기나 런타임이 바뀔 때
- API Gateway/ALB/ECS 구조가 바뀔 때
- RDS/S3/SQS 등 신규 구성 요소가 추가될 때
