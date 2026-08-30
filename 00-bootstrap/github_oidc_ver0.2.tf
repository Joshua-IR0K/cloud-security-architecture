# ============================================================
# 00-bootstrap/github_oidc.tf — GitHub Actions OIDC (장기 키 제거)
# ============================================================
#
# 목적: GitHub Actions가 AWS에 접근할 때 장기 Access Key 없이
#       OIDC 기반 임시 자격증명을 사용 ("일회용 방문증" 방식)
#
# 왜 bootstrap에 두는가:
#   - 계정 전역 + 영속 리소스 (CI/CD가 모든 스택을 plan)
#   - 03-workload에 두면 destroy 시 CI/CD가 죽음
#
# 방향 A (plan 전용): apply는 로컬 수동, CI는 검증만 → 최소 권한
#
# [코드리뷰 반영 이력]
#   - Trust: StringLike → StringEquals (와일드카드 불필요, 의도 명확화)
#   - 권한: secretsmanager:GetSecretValue를 특정 시크릿 ARN으로 제한
#   - 권한: kms:Decrypt를 ViaService 조건으로 제한 (모든 키 → SM 경유만)
#   - max_session_duration: 3600 유지 (AWS IAM Role 최소값이 3600초)
#   - prevent_destroy 추가 (영속 리소스 보호)
#   - plan에 실제 필요한 권한 보강 (events, inspector2, sts, s3 read 등)
#   - thumbprint: 단일 유지 (AWS가 GitHub thumbprint 무시 → 추가 불필요)
#
# ============================================================

variable "github_repo" {
  description = "GitHub 레포 (owner/repo 형식)"
  type        = string
  default     = "Joshua-IR0K/cloud-security-architecture"
}

# ── ① OIDC Identity Provider ──────────────────────────────
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # GitHub thumbprint — AWS는 GitHub OIDC에 대해 이 값을 검증에 쓰지 않고
  # 자체 신뢰 CA 라이브러리로 검증함(2023.7~). 따라서 단일 값으로 충분하며
  # 인증서 교체 시에도 중단 없음. (provider 5.x는 이 필드가 필수)
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    Name = "${var.project_name}-github-oidc"
  }

  # 영속 리소스 — 실수 destroy 방지 (CI/CD 전체 중단 방지)
  lifecycle {
    prevent_destroy = true
  }
}

# ── ② Trust Policy ────────────────────────────────────────
data "aws_iam_policy_document" "github_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # 청중(audience) 검증
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # ★ 레포 + 이벤트 정확 일치 (StringEquals — 와일드카드 없음)
    #   - PR 이벤트: plan-on-PR 동작에 필요
    #   - main ref: merge 후 동작에 필요
    #
    # [Fork PR 보안 메모]
    #   pull_request 이벤트는 이론상 fork에서도 발생 가능하나:
    #   1) 이 레포는 Private → 외부인이 fork 불가
    #   2) fork PR은 기본적으로 id-token:write 권한이 없어 OIDC 토큰 발급 불가
    #   → 현재 환경에서 fork PR 공격 벡터는 실질적으로 차단됨
    #   ⚠ 향후 Public 전환 시: GitHub Environment(보호 규칙)로 sub를
    #      "repo:OWNER/REPO:environment:plan"으로 핀하는 강화 권장
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:pull_request",
        "repo:${var.github_repo}:ref:refs/heads/main"
      ]
    }
  }
}

# ── ③ IAM Role ────────────────────────────────────────────
resource "aws_iam_role" "github_actions_plan" {
  name                 = "${var.project_name}-github-actions-plan"
  assume_role_policy   = data.aws_iam_policy_document.github_assume.json
  max_session_duration = 3600 # AWS 최소값 (IAM Role은 3600~43200 범위만 허용)

  tags = {
    Name    = "${var.project_name}-github-actions-plan"
    Purpose = "ci-terraform-plan-only"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# ── ④ Plan 전용 권한 정책 ─────────────────────────────────
data "aws_iam_policy_document" "plan_permissions" {
  #checkov:skip=CKV_AWS_356:Describe*/List* 류 읽기 API는 리소스 수준 제한 미지원 — 와일드카드 불가피. 쓰기/시크릿 접근은 별도 statement에서 ARN 한정
  #checkov:skip=CKV_AWS_108:GetSecretValue는 Okta 시크릿 ARN 한정, KMS Decrypt는 ViaService 조건, S3 GetObject는 state 버킷 한정 — 유출 경로 통제됨

  # 읽기 — plan은 현재 상태를 읽어 코드와 비교
  # ※ 대부분의 Describe/List API는 리소스 수준 제한을 지원하지 않아
  #    resources=["*"]가 불가피 (읽기 전용이라 시크릿 값 노출 없음)
  statement {
    sid    = "ReadOnlyForPlan"
    effect = "Allow"
    actions = [
      "sts:GetCallerIdentity",
      "ec2:Describe*",
      "ec2:GetManagedPrefixListEntries",
      "ec2:GetManagedPrefixListAssociations",
      "elasticloadbalancing:Describe*",
      "cloudfront:Get*",
      "cloudfront:List*",
      "wafv2:Get*",
      "wafv2:List*",
      "route53:Get*",
      "route53:List*",
      "acm:Describe*",
      "acm:List*",
      "acm:GetCertificate",
      "iam:Get*",
      "iam:List*",
      "kms:Describe*",
      "kms:List*",
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:ListResourceTags",
      "logs:Describe*",
      "logs:Get*",
      "logs:List*",
      "logs:ListTagsForResource",
      "cloudtrail:Describe*",
      "cloudtrail:Get*",
      "cloudtrail:List*",
      "cloudtrail:ListTags",
      "guardduty:Get*",
      "guardduty:List*",
      "securityhub:Get*",
      "securityhub:Describe*",
      "securityhub:ListTagsForResource",
      "securityhub:ListEnabledProductsForImport",
      "securityhub:GetEnabledStandards",
      "config:Describe*",
      "config:Get*",
      "config:ListTagsForResource",
      "inspector2:List*",
      "inspector2:Get*",
      "inspector2:BatchGetAccountStatus",
      "events:Describe*",
      "events:List*",
      "events:ListTagsForResource",
      "sns:Get*",
      "sns:List*",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecrets",
      "secretsmanager:GetResourcePolicy",
      "wafv2:ListTagsForResource",
      "elasticloadbalancing:DescribeTags",
      "tag:GetResources",
      # Stage 5: 02-security ECR repository/lifecycle refresh
      "ecr:DescribeRepositories",
      "ecr:DescribeImages",
      "ecr:GetLifecyclePolicy",
      "ecr:GetRepositoryPolicy",
      "ecr:GetRegistryScanningConfiguration",
      "ecr:ListTagsForResource"
    ]
    resources = ["*"]
  }

  # SSM 파라미터 — 프로젝트 경로만 (스택 간 참조값 읽기)
  statement {
    sid    = "SSMProjectScoped"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:ListTagsForResource"
    ]
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/*"
    ]
  }

  statement {
    sid       = "SSMDescribe"
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"] # DescribeParameters는 리소스 제한 미지원
  }

  # S3 — 로그/State 버킷 구성 조회 (plan이 버킷 속성을 읽음)
  # 프로젝트 버킷 패턴으로 범위 한정 (CKV_AWS_108 대응)
  # GetObject/ListBucket은 아래 StateBucketRead에서 state 버킷만 허용
  statement {
    sid    = "S3ReadForPlan"
    effect = "Allow"
    actions = [
      "s3:GetBucketPolicy",
      "s3:GetEncryptionConfiguration",
      "s3:GetBucketVersioning",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketAcl",
      "s3:GetBucketTagging",
      "s3:GetBucketCORS",
      "s3:GetBucketWebsite",
      "s3:GetBucketLogging",
      "s3:GetBucketNotification",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetBucketRequestPayment",
      "s3:GetAccelerateConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetBucketOwnershipControls"
    ]
    resources = [
      "arn:aws:s3:::${var.project_name}-*",
      "arn:aws:s3:::aws-waf-logs-${var.project_name}-*"
    ]
  }

  # State 객체 읽기 — terraform init/plan이 state 파일을 읽음 (GetObject)
  # ※ S3ReadForPlan에서 GetObject/ListBucket을 분리한 이유:
  #   객체 읽기는 state 버킷으로만 한정해 데이터 유출 표면 축소 (CKV_AWS_108)
  statement {
    sid    = "StateBucketRead"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.terraform_state.arn,
      "${aws_s3_bucket.terraform_state.arn}/*"
    ]
  }

  # State Lock — plan도 lock을 잡으므로 DynamoDB 쓰기 필요
  statement {
    sid    = "StateLock"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable" # 테이블 상태 확인 (간헐 실패 방지)
    ]
    resources = [aws_dynamodb_table.terraform_lock.arn]
  }

  # ── 시크릿 복호화 — ★ 최소 권한으로 제한 (코드리뷰 핵심 반영) ──
  # 03-workload plan 시 data source가 Okta 시크릿을 읽음
  # 변경 전: resources=["*"] → 계정 모든 시크릿 읽기 가능 (위험)
  # 변경 후: 프로젝트 Okta 시크릿 ARN으로 한정
  statement {
    sid    = "GetOktaSecretOnly"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}/okta/*"
    ]
  }

  # KMS Decrypt — Secrets Manager 경유로만 허용 (ViaService 조건)
  # 변경 전: resources=["*"] → 모든 키로 모든 데이터 복호화 가능 (위험)
  # 변경 후: Secrets Manager를 통한 복호화만 허용 (로그 키 등은 불가)
  statement {
    sid    = "DecryptViaSecretsManagerOnly"
    effect = "Allow"
    actions = [
      "kms:Decrypt"
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "plan_permissions" {
  name   = "${var.project_name}-plan-permissions"
  role   = aws_iam_role.github_actions_plan.id
  policy = data.aws_iam_policy_document.plan_permissions.json
}

# ── 출력 ──────────────────────────────────────────────────
output "github_actions_role_arn" {
  description = "GitHub Actions 워크플로우에 넣을 Role ARN"
  value       = aws_iam_role.github_actions_plan.arn
}
