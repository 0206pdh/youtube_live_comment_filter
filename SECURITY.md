# SECURITY

이 문서는 현재 저장소와 AWS 배포 구조를 기준으로 인증, 권한, 비밀정보 관리, 키 회전 정책을 정의한다.

## 1. 보안 목표

목표:

- 공개 엔드포인트에 대한 무단 사용 방지
- GitHub Actions에서 장기 액세스 키 제거
- 최소 권한 원칙 적용
- API Key와 운영 비밀정보의 주기적 회전
- 향후 모델/데이터 저장소 분리 시에도 동일한 보안 원칙 유지

## 2. 현재 인증 구조

현재 앱 인증 요소:

- 클라이언트 인증: `X-API-Key`
- 서버 설정: `API_KEY`, `ENFORCE_AUTH`
- CORS 제한: `ALLOWED_ORIGINS`
- Chrome extension 제한: `ALLOWED_EXTENSION_IDS`

현재 인프라 인증 요소:

- GitHub Actions -> AWS: OIDC + IAM Role Assume
- ECS task secret 주입: SSM Parameter Store
- ALB 앞단 방어: AWS WAF

주의:

- 현재 API Key는 “클라이언트 공유 비밀키”에 가깝다.
- Chrome extension에 저장되는 값이므로 완전한 비밀로 가정하면 안 된다.
- 따라서 API Key는 무단 대량 사용 억제와 기본 접근 제어 수단으로 보고, rate limit/WAF/CORS와 함께 사용한다.

## 3. 인증 정책

### API 인증

정책:

- public 환경에서는 `ENFORCE_AUTH=true`를 기본으로 한다.
- 모든 운영 클라이언트 요청은 `X-API-Key` 헤더를 포함해야 한다.
- API Key가 없거나 불일치하면 401 또는 403으로 거절한다.

예외:

- 로컬 개발 환경에서만 인증 비활성화를 허용할 수 있다.
- dev라도 외부 공개 엔드포인트를 쓰는 경우 인증 비활성화는 금지한다.

### Origin 제한

정책:

- `ALLOWED_ORIGINS`는 최소 집합만 허용한다.
- `ALLOWED_EXTENSION_IDS`에는 운영에 필요한 extension ID만 등록한다.
- wildcard 허용은 금지한다.

### GitHub Actions 인증

정책:

- AWS 액세스 키를 GitHub Secrets에 저장하지 않는다.
- OIDC provider를 사용해 GitHub Actions가 IAM role을 assume한다.
- trust policy는 최소한 repository 단위로 제한한다.
- 추후 필요 시 branch/environment 조건으로 더 좁힌다.

## 4. 권한 정책

### 원칙

- 사람과 시스템 권한을 분리한다.
- Terraform role과 deploy role을 분리한다.
- ECS task execution role과 task role을 분리한다.
- 읽기 권한과 변경 권한을 분리한다.

### 현재 역할별 권한

Terraform role:

- 인프라 생성과 변경에 필요한 광범위 권한
- S3 state bucket, DynamoDB lock table 접근
- 추후 steady-state가 고정되면 점진적으로 축소

Deploy role:

- ECR push
- ECS service update
- 필요한 경우 SSM 읽기

ECS execution role:

- 이미지 pull
- CloudWatch logs write
- SSM parameter read

ECS task role:

- 애플리케이션 런타임에 필요한 최소 권한만 부여
- 현재는 거의 비워 두고, 기능이 생길 때만 추가

### 금지 사항

- `*` 권한을 일반 운영 사용자에게 부여 금지
- 장기 IAM access key를 CI에 저장 금지
- 비밀정보를 `terraform.tfvars.example`, 코드, README에 커밋 금지

## 5. 비밀정보 관리 정책

관리 대상:

- `API_KEY`
- 향후 DB 비밀번호
- 향후 외부 서비스 토큰
- 향후 모델 registry 자격증명

현재 저장 위치:

- AWS SSM Parameter Store: 운영 secret 저장
- GitHub Variables: 비밀값이 아닌 식별자/ARN/이름 저장

정책:

- 비밀값은 GitHub Variables가 아니라 SSM 또는 GitHub Secrets에 둔다.
- 현재 `terraform.tfvars`에 임시로 들어간 값은 bootstrap용으로만 사용한다.
- 실제 운영 전환 후에는 Terraform이 secret 평문을 직접 관리하지 않도록 이동한다.

## 6. 키 회전 정책

### API Key 회전 주기

권장 주기:

- 정기 회전: 90일
- 비정기 회전: 유출 의심, 인수인계, 외부 배포 범위 확대 시 즉시

### API Key 회전 절차

1. 새 API Key 생성
2. SSM Parameter Store에 새 값 저장
3. dev 환경에서 새 키로 먼저 검증
4. ECS 재배포로 새 secret 반영
5. extension 설정 또는 배포 채널에 새 키 반영
6. 이전 키가 더 이상 사용되지 않는지 확인
7. 이전 키 폐기

운영 안정성을 위해 권장되는 방식:

- 가능하면 “이전 키 + 새 키”를 짧은 겹침 기간 동안 동시에 허용하는 로직으로 발전시킨다.
- 현재 구현은 단일 키 기준이므로 회전 시 서버/클라이언트 반영 순서를 엄격히 맞춘다.

### OIDC/IAM 관련 회전

정책:

- OIDC는 액세스 키 회전 대신 trust policy와 role 권한 점검이 핵심이다.
- 분기별로 다음 항목 점검:
  - GitHub repository scope
  - 허용 environment
  - 불필요해진 role 제거

### 향후 DB 비밀번호 회전

향후 RDS 도입 시:

- Secrets Manager 사용을 기본으로 한다.
- 자동 회전 가능하면 활성화한다.

## 7. 보안 점검 체크리스트

배포 전:

- `ENFORCE_AUTH=true` 여부 확인
- `ALLOWED_EXTENSION_IDS` 최소 집합 확인
- `ALLOWED_ORIGINS` 최소 집합 확인
- `API_KEY` placeholder 제거 여부 확인
- GitHub Variables에 role ARN, cluster/service/repository 값 정확성 확인

월간 점검:

- IAM role unused 권한 검토
- WAF 차단 추이 확인
- 인증 실패 추이 확인
- SSM 파라미터 접근 정책 검토

사고 발생 시:

- API Key 즉시 교체
- role trust policy 검토
- 악성 호출 source/IP 패턴 추적
- CloudWatch 로그와 GitHub Actions 실행 이력 보관

## 8. 향후 강화 계획

README의 다음 단계에서 아래 보안 강화를 목표로 한다.

- ALB public 노출 제거 후 private integration/VPC Link 검토
- 데이터 저장소를 S3/RDS로 분리하고 세분화된 IAM 적용
- 모델/데이터 접근 권한 분리
- prod custom domain + ACM 기반 HTTPS 표준화
- CloudTrail, GuardDuty, 추가 탐지 정책 활성화

## 9. 공개 보고 정책

보안 취약점이 발견되면:

1. 공개 이슈로 상세 비밀정보를 남기지 않는다.
2. 영향 범위와 재현 절차를 내부 공유한다.
3. 비밀값 회전과 임시 차단을 먼저 수행한다.
4. 수정 배포 후 공개 가능한 범위만 정리한다.
