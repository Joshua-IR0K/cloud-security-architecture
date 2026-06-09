# Phase 4A.5 — 증분 1: 키 관리 + 시크릿 관리

> 이번 증분: KMS CMK 3개 + Secrets Manager (Okta 자격증명)
> 다음 증분: CI/CD 보안 (GitHub OIDC, Checkov/tfsec, Push Protection)


## 변경 요약

| 스택 | 파일 | 변경 |
|------|------|------|
| 02-security | `kms.tf` | ✨ 신규: CMK 3개 (logs/secrets/ebs) + Rotation |
| 02-security | `secrets.tf` | ✨ 신규: Secrets Manager (Okta) |
| 02-security | `ssm_outputs.tf` | ⚠ EBS 키 ARN + Okta 시크릿 ARN 발행 |
| 02-security | `vpc_flow_logs.tf` | ⚠ Flow Logs 버킷 KMS 암호화 |
| 02-security | `waf_log_bucket.tf` | ⚠ 리전 제약 주석 추가 (SSE-S3 유지) |
| 01-network | `ssm_outputs.tf` | ⚠ `igw_id` 제거 (dead reference 정리) |
| 03-workload | `data.tf` | ⚠ Secrets Manager + EBS 키 읽기, igw_id 제거 |
| 03-workload | `alb.tf` | ⚠ OIDC가 Secrets Manager 값 사용 |
| 03-workload | `ec2.tf` | ⚠ EBS를 EBS CMK로 암호화 |
| 03-workload | `variables.tf` | ⚠ Okta 변수 제거 |
| 03-workload | `terraform.tfvars` | ⚠ Okta 시크릿 제거 (핵심 보안 개선) |


## ⚠ 사용자가 직접 수정할 파일 (phase4a에서 복사한 것들)

`cloudtrail.tf`와 `config.tf`는 네가 phase4a에서 복사해 쓰는 파일이라, KMS 적용을 위해 S3 암호화 블록을 직접 수정해야 해.

### cloudtrail.tf — S3 암호화 블록 수정

```hcl
# 변경 전
resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 변경 후
resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.logs.arn
    }
    bucket_key_enabled = true
  }
}
```

⚠ CloudTrail은 KMS 암호화 버킷에 쓸 때 추가 권한이 필요해. `cloudtrail.tf`의 버킷 정책(`aws_s3_bucket_policy.cloudtrail`)에 KMS 관련 조건이 있는지 확인하고, 만약 apply 시 권한 에러가 나면 CloudTrail 트레일 리소스에 `kms_key_id = aws_kms_key.logs.arn`을 추가해야 할 수 있어. (트레일 자체의 로그 암호화)

### config.tf — S3 암호화 블록 수정

```hcl
# 변경 후
resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.logs.arn
    }
    bucket_key_enabled = true
  }
}
```


## 실행 순서 (중요 — 순서 지켜야 함)

### Step 1: 02-security apply (KMS + Secrets 생성)

```bash
cd 02-security
terraform plan    # KMS 키 3개, Secrets Manager, 버킷 암호화 변경 확인
terraform apply
```

이 시점에 Secrets Manager에는 **플레이스홀더 값**만 있음.

### Step 2: ★ Okta 실제 값 주입 (Step 3 전에 반드시!)

```bash
aws secretsmanager put-secret-value \
  --secret-id "dmz/okta/oidc" \
  --secret-string '{
    "issuer_url": "https://integrator-xxxxx.okta.com/oauth2/default",
    "client_id": "0oaXXXXXXXXXXXXX",
    "client_secret": "실제_시크릿_값"
  }' \
  --profile devsecops-admin --region ap-northeast-2
```

⚠ `secret-id`의 `dmz`는 네 `project_name`에 맞게.
⚠ 이 명령은 터미널 히스토리에 남아 — 실행 후 `Clear-History` 권장.
⚠ **이 단계를 건너뛰면 ALB가 플레이스홀더 값으로 설정되어 OIDC 로그인이 실패해.**

주입 확인:
```bash
aws secretsmanager get-secret-value --secret-id "dmz/okta/oidc" \
  --profile devsecops-admin --region ap-northeast-2 --query "SecretString" --output text
```

### Step 3: 03-workload apply (시크릿 참조)

```bash
cd ../03-workload
terraform plan    # ALB가 Secrets Manager에서 Okta 값 읽는지,
                  # EBS가 KMS 암호화되는지 확인
terraform apply
```


## 검증 체크리스트

- [ ] KMS 키 3개 생성 확인: 콘솔 → KMS → Customer managed keys에 logs/secrets/ebs alias
- [ ] Key Rotation 활성화 확인: 각 키 → Key rotation 탭 → Enabled
- [ ] Secrets Manager: 콘솔 → Secrets Manager → `dmz/okta/oidc` 존재 + KMS 암호화
- [ ] Secret 값 주입 확인: get-secret-value로 실제 Okta 값 확인
- [ ] Flow Logs 버킷 암호화: S3 → flow-logs 버킷 → Properties → Encryption: AWS-KMS
- [ ] EC2 EBS 암호화: EC2 → 인스턴스 → Storage → 볼륨 → KMS 키 ID 확인
- [ ] **end-to-end**: https://joshua-devsecops.com → Okta 로그인 → Walking Skeleton
      (tfvars에 Okta 값이 없어도 Secrets Manager에서 읽어 정상 동작하면 성공)


## 보안 개선 효과 (면접 포인트)

**변경 전**: Okta Client Secret이 `03-workload/terraform.tfvars`에 평문 저장
- 로컬 파일 유출 = 시크릿 유출
- Git 실수 커밋 위험 (`.gitignore` 의존)

**변경 후**: Secrets Manager에 KMS 암호화 저장
- tfvars에서 시크릿 완전 제거
- 워크로드는 IAM 권한으로 런타임에만 읽음
- KMS 키 정책으로 접근 통제 + CloudTrail로 접근 감사
- 키 자동 Rotation으로 장기 키 위험 감소

**Crypto-shredding 방지 실증**: KMS 키가 영속 스택(02)에 있어 워크로드 destroy로도 안 사라짐 → 암호화된 로그/시크릿 복호화 가능성 유지


## 다음 증분 예고 — CI/CD 보안

- GitHub Actions OIDC → AWS (장기 키 완전 제거)
- OIDC Role에 Secrets Manager 읽기 + KMS Decrypt 권한 부여
- Checkov / tfsec — IaC 보안 스캔 (이번에 만든 KMS/Secrets 설정도 스캔 대상)
- GitHub Secret Scanning + Push Protection
- Terraform Remote State Hardening
