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

## 5. Phase 전환 기준 (부하 테스트 게이트)

Phase 전환은 인프라 구조가 바뀌는 이벤트다. 새 구조가 SLO를 만족하는지 사전에 검증하지 않으면, 전환 직후 프로덕션에서 성능 문제가 발견될 수 있다. 이를 방지하기 위해 Phase 전환 전 부하 테스트 통과를 필수 조건으로 정의한다.

### 정의

- 부하 테스트를 통과하지 못하면 Phase 전환을 진행하지 않는다.
- 세 가지 시나리오(Baseline, Spike, Soak)를 모두 통과해야 한다.
- 통과 기준은 해당 Phase에서 최종적으로 달성해야 하는 SLO 목표값보다 약간 완화된 "전환 게이트" 수준으로 설정한다.

### Phase 전환 기준 테이블

| Phase 전환 | 시나리오 | p95 Latency | 오류율 | 동시 사용자 | 필수 여부 |
|-----------|---------|-------------|--------|------------|---------|
| Phase 0 → 1 | Baseline (10 VU, 5분) | < 500ms | < 1% | 10 | 필수 |
| Phase 0 → 1 | Spike (0→100 VU) | < 2000ms | < 5% | 100 (피크) | 필수 |
| Phase 0 → 1 | Soak (30 VU, 30분) | < 800ms | < 1% | 30 | 필수 |
| Phase 1 → 2 | Baseline (10 VU, 5분) | < 300ms | < 0.5% | 10 | 필수 |
| Phase 1 → 2 | Spike (0→100 VU) | < 1500ms | < 3% | 100 (피크) | 필수 |
| Phase 1 → 2 | Soak (50 VU, 30분) | < 500ms | < 0.5% | 50 | 필수 |
| Phase 2 → 3 | Baseline (10 VU, 5분) | < 200ms | < 0.1% | 10 | 필수 |
| Phase 2 → 3 | Spike (0→100 VU) | < 1000ms | < 1% | 100 (피크) | 필수 |
| Phase 2 → 3 | Soak (100 VU, 30분) | < 300ms | < 0.1% | 100 | 필수 |

> Phase 2 → 3에서 기준이 크게 강화되는 이유: Training Worker 분리 후 추론 서비스가 학습 연산을 더 이상 담당하지 않으므로 CPU 여유가 늘어나 latency 개선이 당연히 따라와야 한다. 개선되지 않는다면 Worker 분리 효과가 없는 것이므로 설계를 재검토한다.

### 기준 미달 시 조치 사항

**p95 Latency 기준 미달:**
1. ECS 태스크 CPU/메모리 스펙 상향 검토
2. BERT 모델 경량화 또는 추론 배치 크기 조정
3. Phase 전환 보류, 원인 분석 후 재테스트

**오류율 기준 미달:**
1. 5xx가 많으면: ECS 로그에서 Stack Trace 확인, 코드 버그 수정 후 재배포
2. 429가 많으면: Rate Limiter 설정이 지나치게 빡빡한지 검토 (429는 서비스 방어 동작이므로 기준 초과가 아닐 수 있음)
3. Phase 전환 보류, 원인 수정 후 재테스트

**Soak에서 Latency가 시간에 따라 증가:**
1. ECS 메모리 사용량 30분 추이 확인 → 메모리 누수 의심
2. DB 연결 풀 고갈 확인
3. S3 I/O 누적 영향 확인
4. 메모리 누수 수정 또는 주기적 연결 초기화 코드 추가 후 재테스트

**모든 조치 후에도 기준 미달이면:**
1. 해당 Phase의 SLO 목표값 재검토 (현재 아키텍처의 한계를 목표에 반영)
2. 또는 아키텍처 변경 (다음 Phase에서 해결할 항목으로 이관)

### 부하 테스트 상세 절차

스크립트, 실행 방법, CloudWatch Logs Insights 쿼리, 결과 기록 양식은 [LOAD_TESTING.md](./LOAD_TESTING.md)를 참조한다.

---

## 6. 에러 버짓

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

## 7. 알람 기준

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

## 8. 측정 위치

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

## 9. 운영 해석 기준

지연시간만 높고 성공률은 정상이면:

- 성능 저하 이슈로 본다.
- noisy client, 배치 크기, 모델 크기, CPU/메모리 압박을 확인한다.

성공률도 함께 떨어지면:

- 장애 대응 모드로 전환한다.
- 최근 배포, task 재시작, secret 반영 실패를 우선 의심한다.

auth failure만 급증하면:

- 가용성 사고라기보다 인증/설정 사고일 가능성이 높다.
- API Key 회전 또는 extension 설정 불일치를 확인한다.

## 10. 향후 분리 계획

Phase 2 이후에는 SLO를 최소 3개로 분리한다.

- Inference API SLO
- Training pipeline SLO
- Model promotion/reload SLO

예시:

- inference latency/availability
- training job completion success rate
- model promotion lead time

## 11. 리뷰 주기

- 주간: 성능 추이 리뷰
- 월간: SLO 달성률 및 에러 버짓 리뷰
- 분기: 목표값 재설정

변경이 필요한 경우:

- 모델 크기나 런타임이 바뀔 때
- API Gateway/ALB/ECS 구조가 바뀔 때
- RDS/S3/SQS 등 신규 구성 요소가 추가될 때
