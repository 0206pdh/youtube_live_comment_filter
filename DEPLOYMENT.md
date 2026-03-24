# 배포 가이드

이 문서는 서버(FastAPI + BERT 모델)와 Chrome Extension의 전체 배포 절차를 단계별로 정리한다.

---

## 목차

1. [사전 준비](#1-사전-준비)
2. [인프라 배포 (Terraform)](#2-인프라-배포-terraform)
3. [서버 배포 (Docker → ECR → ECS)](#3-서버-배포-docker--ecr--ecs)
4. [서버 동작 확인](#4-서버-동작-확인)
5. [Chrome Extension 배포](#5-chrome-extension-배포)
6. [Extension + 서버 연동 확인](#6-extension--서버-연동-확인)
7. [GitHub Actions 자동 배포 설정](#7-github-actions-자동-배포-설정)
8. [배포 롤백](#8-배포-롤백)
9. [자주 발생하는 오류](#9-자주-발생하는-오류)

---

## 1. 사전 준비

### 필수 도구 설치 확인

```powershell
# AWS CLI
aws --version
# 출력 예: aws-cli/2.x.x

# Docker
docker --version
# 출력 예: Docker version 26.x.x

# Terraform
terraform version
# 출력 예: Terraform v1.8.x

# GitHub CLI (선택, 자동 배포 설정 시 필요)
gh --version
```

### AWS 자격증명 확인

```powershell
aws sts get-caller-identity
```

정상 출력:
```json
{
  "UserId": "...",
  "Account": "039384756894",
  "Arn": "arn:aws:iam::039384756894:user/..."
}
```

오류 시: `C:\Users\DGSO1\.aws\credentials` 파일에 Access Key가 설정되어 있는지 확인.

---

## 2. 인프라 배포 (Terraform)

> 이미 `terraform apply`가 완료된 상태라면 이 섹션은 건너뛴다.
> destroy 후 재배포하거나 처음 배포할 때 실행.

### 2-1. terraform.tfvars 확인

`infra/environments/dev/terraform.tfvars` 파일에서 실제 값이 채워져 있는지 확인:

```hcl
aws_region                 = "ap-northeast-2"
project_name               = "ylcf-dev"
github_repository          = "0206pdh/youtube_live_comment_filter"
allowed_extension_ids      = []           # Chrome Extension ID (나중에 채움)
api_key_placeholder        = "..."        # 실제 API Key
oidc_provider_arn          = "arn:aws:iam::039384756894:oidc-provider/token.actions.githubusercontent.com"
terraform_state_bucket_arn = "arn:aws:s3:::youtube-live-comment-filter-tfstate"
terraform_lock_table_arn   = "arn:aws:dynamodb:ap-northeast-2:039384756894:table/youtube-live-comment-filter-tf-lock"
db_password                = "..."        # 강한 패스워드로 변경 필수
```

### 2-2. Terraform 실행

```powershell
cd infra/environments/dev

# 초기화 (처음 한 번 또는 모듈 추가 후)
terraform init -backend-config backend.hcl

# 변경 내용 미리 확인
terraform plan -var-file=terraform.tfvars

# 실제 적용
terraform apply -var-file=terraform.tfvars
# "yes" 입력
```

### 2-3. 배포 결과 확인

apply 완료 후 출력값 기록 (이후 단계에서 사용):

```
alb_dns_name           = "ylcf-dev-alb-xxxxxxxxxx.ap-northeast-2.elb.amazonaws.com"
api_gateway_endpoint   = "https://xxxxxxxxxx.execute-api.ap-northeast-2.amazonaws.com/"
ecr_repository_url     = "039384756894.dkr.ecr.ap-northeast-2.amazonaws.com/ylcf-dev-api"
ecs_cluster_name       = "ylcf-dev-cluster"
ecs_service_name       = "ylcf-dev-service"
training_data_bucket   = "ylcf-dev-training-data"
training_queue_url     = "https://sqs.ap-northeast-2.amazonaws.com/039384756894/ylcf-dev-training-queue"
rds_endpoint           = "ylcf-dev-db.xxxxxxxxxx.ap-northeast-2.rds.amazonaws.com:5432"
deploy_role_arn        = "arn:aws:iam::039384756894:role/ylcf-dev-deploy-role"
terraform_role_arn     = "arn:aws:iam::039384756894:role/ylcf-dev-terraform-role"
```

---

## 3. 서버 배포 (Docker → ECR → ECS)

### 3-1. ECR 로그인

```powershell
aws ecr get-login-password --region ap-northeast-2 `
  | docker login --username AWS --password-stdin `
    039384756894.dkr.ecr.ap-northeast-2.amazonaws.com
```

성공 시: `Login Succeeded`

### 3-2. Docker 이미지 빌드

프로젝트 루트(`youtube_live_comment_filter/`)에서 실행:

```powershell
docker build -f server/Dockerfile -t ylcf-dev-api .
```

빌드 시간: 모델 파일 포함으로 5~15분 소요 (첫 빌드 기준).

빌드 완료 확인:
```powershell
docker images | findstr ylcf-dev-api
```

### 3-3. 이미지 태깅

```powershell
$ECR = "039384756894.dkr.ecr.ap-northeast-2.amazonaws.com/ylcf-dev-api"

docker tag ylcf-dev-api:latest $ECR:latest
```

### 3-4. ECR에 Push

```powershell
docker push $ECR:latest
```

Push 완료 후 ECR 콘솔에서 확인:
- AWS Console → ECR → `ylcf-dev-api` → Images

### 3-5. ECS 서비스 재배포

이미지가 ECR에 올라가면 ECS가 새 태스크를 자동으로 시작한다.
수동으로 즉시 강제 재배포하려면:

```powershell
aws ecs update-service `
  --cluster ylcf-dev-cluster `
  --service ylcf-dev-service `
  --force-new-deployment `
  --region ap-northeast-2
```

### 3-6. ECS 태스크 기동 대기

태스크가 RUNNING 상태가 될 때까지 대기 (보통 1~3분):

```powershell
aws ecs wait services-stable `
  --cluster ylcf-dev-cluster `
  --services ylcf-dev-service `
  --region ap-northeast-2

echo "ECS 서비스 안정화 완료"
```

또는 콘솔에서 확인:
- AWS Console → ECS → `ylcf-dev-cluster` → `ylcf-dev-service` → Tasks

---

## 4. 서버 동작 확인

### 4-1. Liveness 확인

```powershell
$API = "https://<api_gateway_endpoint에서 확인한 URL>"

# Liveness (프로세스 살아있는지)
Invoke-RestMethod "$API/health/live"
# 기대 출력: {"status":"alive"}
```

### 4-2. Readiness 확인 (모델 로드 완료 여부)

```powershell
Invoke-RestMethod "$API/health/ready"
# 기대 출력: {"status":"ready","device":"cpu","model_dir":"..."}
```

모델 로딩 중이면 503 반환 → 30초~1분 후 재시도.

### 4-3. 추론 API 테스트

```powershell
$headers = @{ "X-API-Key" = "<terraform.tfvars의 api_key_placeholder 값>" }
$body = @{ texts = @("테스트 댓글입니다", "나쁜 댓글 예제") } | ConvertTo-Json

Invoke-RestMethod "$API/predict" -Method POST -Headers $headers `
  -ContentType "application/json" -Body $body
```

기대 출력:
```json
{
  "labels": [0, 2],
  "probs": [[0.95, 0.03, 0.02], [0.05, 0.10, 0.85]],
  "label_names": {"0": "normal", "1": "borderline_abusive", "2": "abusive"}
}
```

### 4-4. 학습 데이터 저장 테스트

```powershell
$body = @{
  text  = "테스트 댓글"
  label = 0
  user_id = "test_user"
} | ConvertTo-Json

Invoke-RestMethod "$API/training-data" -Method POST -Headers $headers `
  -ContentType "application/json" -Body $body
# 기대 출력: {"success":true,"message":"Training data saved successfully"}
```

S3 저장 확인:
```powershell
aws s3 ls s3://ylcf-dev-training-data/training-data/ --region ap-northeast-2
```

### 4-5. 트래픽 메트릭 확인

```powershell
Invoke-RestMethod "$API/metrics/live" -Headers $headers
```

---

## 5. Chrome Extension 배포

### 5-1. 로컬 개발용 설치 (Unpacked)

개발 중에는 Chrome에 직접 폴더를 로드한다.

1. Chrome 주소창에 `chrome://extensions` 입력
2. 우측 상단 **개발자 모드** 활성화
3. **압축해제된 확장 프로그램을 로드합니다** 클릭
4. `youtube_live_comment_filter/extension/` 폴더 선택
5. 확장 프로그램 카드에서 ID 복사 (32자 문자열)

### 5-2. Extension ID를 Terraform에 등록

Extension ID가 확정되면 `terraform.tfvars`에 등록:

```hcl
allowed_extension_ids = ["abcdefghijklmnopabcdefghijklmnop"]
```

이후 `terraform apply`로 CORS 허용 목록 업데이트.

### 5-3. Extension에 서버 URL 설정

1. Chrome에서 확장 프로그램 아이콘 우클릭 → **옵션**
2. 서버 URL 입력: `https://<api_gateway_endpoint>/`
3. API Key 입력: terraform.tfvars의 `api_key_placeholder` 값
4. 저장

### 5-4. manifest.json host_permissions 업데이트

현재 manifest.json은 localhost만 허용. API Gateway URL을 추가해야 한다:

```json
"host_permissions": [
  "https://www.youtube.com/*",
  "https://<api_gateway_id>.execute-api.ap-northeast-2.amazonaws.com/*",
  "http://localhost:8000/*",
  "http://127.0.0.1:8000/*"
]
```

수정 후 `chrome://extensions`에서 **새로고침** 클릭.

### 5-5. Chrome Web Store 배포 (정식 배포 시)

1. [Chrome Web Store 개발자 대시보드](https://chrome.google.com/webstore/devconsole) 접속
2. extension/ 폴더를 zip으로 압축
   ```powershell
   Compress-Archive -Path extension/* -DestinationPath extension.zip
   ```
3. 대시보드에서 새 항목 추가 → zip 업로드
4. 스토어 등록 정보 작성 (스크린샷, 설명 등)
5. 제출 → 검토 후 게시 (보통 1~3 영업일 소요)
6. 게시 후 스토어 Extension ID로 `terraform.tfvars` 업데이트 (로컬 Unpacked ID와 다름)

---

## 6. Extension + 서버 연동 확인

1. YouTube Live 채팅이 있는 방송 접속
2. 확장 프로그램 아이콘 클릭 → 상태가 **연결됨** 표시되는지 확인
3. 채팅창에서 댓글이 분류되고 있는지 확인
4. 서버 로그 확인:
   ```powershell
   aws logs tail /ecs/ylcf-dev --follow --region ap-northeast-2
   ```
   `PREDICT_METRIC` 로그가 실시간으로 찍히면 정상.

---

## 7. GitHub Actions 자동 배포 설정

이 설정을 완료하면 이후 `git push`만으로 자동 배포된다.

### 7-1. GitHub Repository Variables 등록

```powershell
gh variable set DEV_TERRAFORM_ROLE_ARN `
  --body "arn:aws:iam::039384756894:role/ylcf-dev-terraform-role"

gh variable set DEV_DEPLOY_ROLE_ARN `
  --body "arn:aws:iam::039384756894:role/ylcf-dev-deploy-role"

gh variable set DEV_ECR_REPOSITORY --body "ylcf-dev-api"
gh variable set DEV_ECS_CLUSTER    --body "ylcf-dev-cluster"
gh variable set DEV_ECS_SERVICE    --body "ylcf-dev-service"
gh variable set AWS_REGION         --body "ap-northeast-2"
```

등록 확인:
```powershell
gh variable list
```

### 7-2. 자동 배포 트리거 조건

| 워크플로우 | 트리거 조건 | 동작 |
|-----------|------------|------|
| `terraform-infra` | `infra/**` 변경 후 push | `terraform apply` 자동 실행 |
| `deploy-app` | `server/**` 변경 후 push | Docker 빌드 → ECR push → ECS 재배포 |

### 7-3. 워크플로우 실행 확인

```powershell
gh run list --limit 5
gh run view <run-id>   # 특정 run 상세 확인
```

### 7-4. 수동 배포 (workflow_dispatch)

특정 환경에만 배포하고 싶을 때:

```powershell
# dev에 수동 배포
gh workflow run deploy-app.yml -f target_environment=dev

# prod에 수동 배포
gh workflow run deploy-app.yml -f target_environment=prod
```

---

## 8. 배포 롤백

### 서버 롤백 (이전 이미지로)

```powershell
# ECR에서 이미지 목록 확인
aws ecr list-images --repository-name ylcf-dev-api --region ap-northeast-2

# 특정 SHA 태그로 ECS task definition 업데이트 후 배포
# (현재 dev는 :latest 사용, SHA 태그로 고정하려면 task definition 직접 수정)

# 빠른 롤백: 이전 task definition revision으로 서비스 업데이트
aws ecs update-service `
  --cluster ylcf-dev-cluster `
  --service ylcf-dev-service `
  --task-definition ylcf-dev-task:<이전_revision_번호> `
  --region ap-northeast-2
```

### 인프라 롤백 (terraform)

```powershell
# 이전 커밋으로 코드를 되돌린 후
git checkout <이전_커밋_해시> -- infra/

terraform apply -var-file=terraform.tfvars
```

### 전체 인프라 삭제

```powershell
cd infra/environments/dev
terraform destroy -var-file=terraform.tfvars
# "yes" 입력
```

주의: S3 버킷에 데이터가 있으면 `force_destroy = true` 설정 확인. 현재 dev는 true로 설정되어 있음.

---

## 9. 자주 발생하는 오류

### ECS 태스크가 계속 PENDING 상태

원인: ECR에 이미지가 없음.

확인:
```powershell
aws ecr list-images --repository-name ylcf-dev-api --region ap-northeast-2
```

해결: 3단계 (Docker 빌드 → ECR push) 실행.

---

### ECS 태스크가 시작 후 바로 종료됨

원인: 모델 로딩 실패 또는 앱 크래시.

확인:
```powershell
aws logs tail /ecs/ylcf-dev --region ap-northeast-2
```

주요 원인:
- `model/` 디렉터리가 비어있음 → Docker 빌드 시 모델 파일 포함 여부 확인
- SSM Parameter Store 접근 실패 → execution role 권한 확인
- 환경변수 누락 → ECS task definition 확인

---

### `/health/ready` 503 반환

원인: 모델 로딩 중이거나 실패.

대기 후 재시도:
```powershell
Start-Sleep -Seconds 60
Invoke-RestMethod "$API/health/ready"
```

계속 503이면 ECS 로그에서 오류 메시지 확인.

---

### GitHub Actions `Credentials could not be loaded`

원인: GitHub Repository Variables 미등록.

해결: 7-1단계 Variables 등록 실행.

---

### docker push 실패 `no basic auth credentials`

원인: ECR 로그인 만료 (토큰 유효기간 12시간).

해결: 3-1단계 ECR 로그인 재실행.

---

### Extension에서 서버 연결 실패

확인 순서:
1. `manifest.json`의 `host_permissions`에 API Gateway URL 포함 여부
2. Extension 옵션에서 서버 URL 끝에 `/` 포함 여부
3. CORS: `terraform.tfvars`의 `allowed_extension_ids`에 Extension ID 등록 여부
4. API Key가 서버와 Extension에서 동일한 값인지 확인

---

## 배포 체크리스트

### 최초 배포

- [ ] AWS CLI 자격증명 확인 (`aws sts get-caller-identity`)
- [ ] `terraform.tfvars` 실제 값으로 채움 (특히 `db_password`)
- [ ] `terraform init -backend-config backend.hcl`
- [ ] `terraform apply -var-file=terraform.tfvars`
- [ ] ECR 로그인
- [ ] Docker 이미지 빌드
- [ ] ECR push
- [ ] ECS 태스크 RUNNING 확인
- [ ] `/health/ready` 200 확인
- [ ] `/predict` 정상 응답 확인
- [ ] Extension 설치 및 서버 URL/API Key 설정
- [ ] YouTube Live에서 댓글 필터링 동작 확인
- [ ] GitHub Variables 등록 (자동 배포용)

### 코드 변경 후 재배포 (자동)

- [ ] `git push origin main`
- [ ] GitHub Actions `deploy-app` 워크플로우 성공 확인
- [ ] ECS 새 태스크 RUNNING 확인
- [ ] `/health/ready` 200 확인

### 인프라 변경 후 재배포 (자동)

- [ ] `infra/` 코드 변경 후 `git push origin main`
- [ ] GitHub Actions `terraform-infra` 워크플로우 성공 확인
- [ ] 변경된 리소스 AWS 콘솔에서 확인
