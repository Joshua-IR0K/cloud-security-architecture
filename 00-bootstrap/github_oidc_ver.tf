# ============================================================
# 00-bootstrap/github_oidc_ver.tf — GitHub Actions OIDC, plan 역할 (장기 키 제거)
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
#   - [A-1, 2026-10] plan 역할 최소권한 재설계 — 멘토 피드백 ②
#       · 신뢰: pull_request 만 (main 제거 — 미사용 + 측면 이동 경로)
#       · state: 01·02 두 파일만 읽기 / 목록은 env:/ 접두어만 / 잠금 테이블은 다이제스트 읽기만
#       · 시크릿 경로 제거: Okta GetSecretValue · KMS Decrypt
#         + 같은 값을 '설정 조회'로 돌려주는 서비스 제거: CloudFront · ELB · WAF
#       · 01·02 가 쓰지 않는 서비스 제거: logs / 설정 이력(config:Get*)
#       · 추가: kms:GetPublicKey — 02 의 aws_kms_public_key 데이터 소스용 (공개키, 비민감, 누락으로 02 plan 실패 확인)
#       · 추가: 02 로그 버킷 4개의 s3:ListBucket — 버킷 존재 확인용 (없으면 CI 가 '삭제됨'으로 오판)
#   - [멘토 ⑤, 2026-10] 02 에 EKS 컨트롤플레인 로그 그룹 추가 → 로그 그룹 '메타데이터' 조회만 다시 허용
#       · logs:DescribeLogGroups · ListTagsForResource · ListTagsLogGroup (로그 내용을 읽는 Get*·Filter* 는 계속 제외)
#   - [멘토 ③, 2026-10] 02 에 Athena 조사 계층 추가 → 카탈로그·워크그룹 '메타데이터' 조회만 허용
#       · glue: GetDatabase · GetTable · GetPartitionIndexes · GetTags (security_logs DB 로 한정)
#       · athena: GetWorkGroup · GetNamedQuery · ListTagsForResource (보안 워크그룹으로 한정)
#       · 결과 버킷 s3:ListBucket (존재 확인용). 쿼리 실행·결과 읽기는 계속 제외 — 가드가 쿼리 실행 거부를 확인
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

    # ★ pull_request 만 신뢰한다 (StringEquals — 와일드카드 없음)
    #
    # [A-1] main ref 를 지운 이유 — 쓰이지 않는데 위험한 경로였다
    #   이 역할을 쓰는 워크플로는 terraform-plan.yml 하나이고 pull_request 에서만 돈다.
    #   신뢰에 main 이 남아 있으면 main 에서 도는 다른 잡(예: build-deploy 의 build 잡)도
    #   이 역할을 수임할 수 있다. id-token 권한이 있는 잡에서는 어떤 스텝이든(서드파티 액션
    #   포함) OIDC 토큰을 새로 받아 sub 가 맞는 역할을 수임할 수 있기 때문이다.
    #
    # [A-1] GitHub Environment 로 sub 를 핀하지 않은 이유
    #   비공개 레포 + Free 요금제에서는 Environment 의 보호 기능(required reviewers,
    #   deployment branches)이 제공되지 않는다. 보호 규칙 없는 Environment 는 아무 브랜치의
    #   잡이나 선언할 수 있으므로 sub 를 environment 로 바꿔도 통제가 생기지 않는다.
    #   → 승인 게이트 대신 "이 역할이 무엇을 읽을 수 있는가"를 줄이는 권한 분리로 방어한다.
    #   레포 공개 시 적용할 설계: A1 문서 §6 (environment:ci-plan 핀 + required reviewer).
    #
    # [Fork PR] 비공개 레포라 외부인이 fork 할 수 없고, fork PR 은 id-token 권한이
    #   없어 OIDC 토큰을 받지 못한다.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:pull_request"]
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
  # [A-1] checkov 예외(skip) 없음 — 이전의 CKV_AWS_356(kms:Decrypt 를 "*" 에 허용)·
  #   CKV_AWS_108 예외가 권한 정리로 불필요해졌다. 예외를 등록하는 대신 없앴다.

  # 읽기 — plan 은 현재 상태를 읽어 코드와 비교
  # ※ 대부분의 Describe/List API 는 리소스 수준 제한을 지원하지 않아 resources=["*"] 가 불가피
  #
  # [A-1] 포함 기준 — "CI 가 plan 하는 01·02 가 실제로 쓰는 서비스만"
  #   이전 주석은 "읽기 전용이라 시크릿 값 노출 없음"이었으나 틀렸다.
  #   조회 API 도 응답에 비밀을 담을 수 있다:
  #     cloudfront:GetDistribution(Config)·ListDistributions → 오리진 헤더 X-Origin-Verify 값
  #     elasticloadbalancing:DescribeRules                   → ALB 규칙 조건의 같은 헤더 값
  #     wafv2:GetSampledRequests                             → 실제 요청 헤더(세션 쿠키 포함 가능)
  #   셋 다 03 이 소유한 서비스라 01·02 plan 에는 필요 없다 → 제거.
  #   config:Get*(설정 이력 내용)도 같은 기준으로 제거.
  #   logs: 02 에 EKS 컨트롤플레인 로그 그룹이 생겨 메타데이터 조회만 허용한다.
  #     + 저장 쿼리 정의 조회(DescribeQueryDefinitions) — 이름·쿼리 문자열뿐이고 로그 내용이 아니다.
  #     로그 내용(GetLogEvents·FilterLogEvents·StartQuery)은 감사 기록 자체라 계속 제외 — 가드가 확인.
  statement {
    sid    = "ReadOnlyForPlan"
    effect = "Allow"
    actions = [
      "sts:GetCallerIdentity",
      "ec2:Describe*",
      "ec2:GetManagedPrefixListEntries",
      "ec2:GetManagedPrefixListAssociations",
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
      # 02 의 aws_cloudwatch_log_group refresh (메타데이터만 — 내용 읽기 권한 아님)
      "logs:DescribeLogGroups",
      "logs:ListTagsForResource",
      "logs:ListTagsLogGroup",
      # 02 의 aws_cloudwatch_query_definition refresh (저장 쿼리 정의 — 실행 권한 StartQuery 는 없음)
      "logs:DescribeQueryDefinitions",
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
      "config:Describe*", # recorder·channel·status 조회 (설정 이력 내용을 돌려주는 Get* 는 제외)
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
      "tag:GetResources",
      # Stage 5: 02-security ECR repository/lifecycle refresh
      "ecr:DescribeRepositories",
      "ecr:DescribeImages",
      "ecr:GetLifecyclePolicy",
      "ecr:GetRepositoryPolicy",
      "ecr:GetRegistryScanningConfiguration",
      "ecr:ListTagsForResource",
      # Stage 6: 02-security CodeBuild project/webhook refresh
      "codebuild:BatchGetProjects",
      "codebuild:ListProjects"
    ]
    resources = ["*"]
  }

  # [A-1] 02 의 data "aws_kms_public_key"(서명 공개키 → SSM 발행)가 GetPublicKey 를 호출한다.
  #   기존 정책에 없어 02 plan 이 이 지점에서 실패했다 — AccessDeniedException on
  #   kms:GetPublicKey (2026-10-06 CI 로그). continue-on-error 때문에 체크는 초록이었다.
  #   공개키라 비민감.
  statement {
    sid       = "KmsGetPublicKeyForDataSource"
    effect    = "Allow"
    actions   = ["kms:GetPublicKey"]
    resources = ["arn:aws:kms:${var.aws_region}:${data.aws_caller_identity.current.account_id}:key/*"]
  }

  # SSM 파라미터 — 프로젝트 경로만 (스택 간 참조값 읽기)
  #   SecureString 파라미터 없음 (2026-10 확인) → 이 경로로 새는 비밀 없음
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
  # 객체 읽기(GetObject)는 state 두 파일만, 목록(ListBucket)은 아래 두 statement 에서 따로 한정
  #   ⚠ 이 statement 에 ListBucket 을 넣지 않는다 — resources 가 state 버킷까지 포함해
  #     state 버킷 전체 목록이 열린다 (statement 는 OR 로 합쳐진다)
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

  # 02 로그 버킷 존재 확인 — s3:ListBucket (A-1, 2026-10-12)
  #   aws_s3_bucket 의 refresh 는 HeadBucket 으로 버킷 존재를 확인하고, HeadBucket 은
  #   s3:ListBucket 권한을 요구한다. 이 권한이 없을 때 CI plan 은 실패하지 않고 4개 버킷을
  #   "없음"으로 보고 재생성 + 딸린 리소스 15개 교체를 계획했다 (23 add / 4 change / 19 destroy,
  #   로컬 plan 은 No changes). 에러 없이 틀린 plan — 실패보다 위험하다.
  #   범위: 로그 버킷 4개 + Athena 결과 버킷(멘토 ③). 객체 이름 목록만 보이고 내용(GetObject)은 여전히 막혀 있다.
  statement {
    sid     = "LogBucketExistenceForPlan"
    effect  = "Allow"
    actions = ["s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.project_name}-cloudtrail-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::${var.project_name}-config-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::${var.project_name}-flow-logs-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::aws-waf-logs-${var.project_name}-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::${var.project_name}-athena-results-${data.aws_caller_identity.current.account_id}",
    ]
  }

  # Athena 조사 계층 (02 athena.tf) refresh — 메타데이터만 (멘토 ③, 2026-10)
  #   provider 5.100.0 의 refresh 가 실제로 부르는 API 만 넣었다:
  #     glue_catalog_database = GetDatabase + GetTags / glue_catalog_table = GetTable + GetPartitionIndexes
  #     athena_workgroup = GetWorkGroup + ListTagsForResource / athena_named_query = GetNamedQuery
  #   로그 내용에 닿는 경로(StartQueryExecution·GetQueryResults, 결과 버킷 GetObject)는 없다 — 가드가 쿼리 실행 거부를 확인.
  statement {
    sid    = "AthenaCatalogMetadataForPlan"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetTable",
      "glue:GetPartitionIndexes",
      "glue:GetTags",
    ]
    resources = [
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/security_logs",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/security_logs/*",
    ]
  }

  statement {
    sid    = "AthenaWorkgroupMetadataForPlan"
    effect = "Allow"
    actions = [
      "athena:GetWorkGroup",
      "athena:GetNamedQuery",
      "athena:ListTagsForResource",
    ]
    resources = [
      "arn:aws:athena:${var.aws_region}:${data.aws_caller_identity.current.account_id}:workgroup/${var.project_name}-security",
    ]
  }

  # ── State 접근 — CI plan 에 필요한 만큼만 (A-1) ──────────────
  #
  # 스택별 state 민감도 (2026-10 평가):
  #   00  로컬 state (버킷에 없음)                          → 해당 없음
  #   01  민감정보 없음                                      → 허용
  #   02  시크릿 값 리소스를 Terraform 관리에서 뺀 뒤 없음   → 허용
  #   03  Okta 시크릿 2곳 + X-Origin-Verify 3곳             → 차단 (plan 은 로컬에서만)
  #   04·05  민감정보 없음, 임시 스택이라 CI plan 대상 아님  → 차단 (불필요)

  # State 객체 읽기 — 01·02 두 파일만
  statement {
    sid       = "StateObjectReadPersistentStacks"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [for k in local.plan_state_keys : "${aws_s3_bucket.terraform_state.arn}/${k}"]
  }

  # 버킷 목록 조회 — 워크스페이스 접두어(env:/)만
  #   Terraform S3 백엔드는 init·plan 때 워크스페이스 목록을 "env:/" 접두어로 조회한다.
  #   그 외 접두어(예: stacks/03-workload/)와 전체 목록은 거부된다.
  #   ⚠ 부수 효과: 없는 객체를 GetObject/HeadObject 하면 404 가 아니라 403 이 온다
  #     (ListBucket 이 없으면 S3 가 존재 여부를 숨긴다). 거부 증명은 정책 시뮬레이터로 한다.
  statement {
    sid       = "StateBucketListWorkspacePrefixOnly"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.terraform_state.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["env:/*"]
    }
  }

  # 잠금 테이블 — 무결성 다이제스트 읽기만
  #   CI plan 은 -lock=false 로 돈다 → 잠금 항목을 쓰지 않는다 (PutItem/DeleteItem 없음).
  #   S3 백엔드는 state 를 읽을 때 "<버킷>/<키>-md5" 다이제스트를 대조하므로 GetItem 만
  #   필요하고, 그것도 01·02 다이제스트 항목으로만 한정한다.
  #   Null=false: ForAllValues 는 키가 아예 없으면 참으로 판정되므로, 키가 반드시
  #   있어야 하도록 짝으로 둔다 (AWS 권장 패턴).
  statement {
    sid       = "StateDigestReadPersistentStacks"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem"]
    resources = [aws_dynamodb_table.terraform_lock.arn]
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "dynamodb:LeadingKeys"
      values   = [for k in local.plan_state_keys : "${aws_s3_bucket.terraform_state.bucket}/${k}-md5"]
    }
    condition {
      test     = "Null"
      variable = "dynamodb:LeadingKeys"
      values   = ["false"]
    }
  }

  statement {
    sid       = "StateLockTableDescribe"
    effect    = "Allow"
    actions   = ["dynamodb:DescribeTable"] # 테이블 상태 확인 (간헐 실패 방지)
    resources = [aws_dynamodb_table.terraform_lock.arn]
  }

  # ── 시크릿 — 의도적 부재 (A-1) ──────────────────────────────
  # 이전에는 secretsmanager:GetSecretValue(Okta) + kms:Decrypt(SM 경유)가 있었다.
  #   · 03 plan 의 데이터 소스, 02 plan 의 시크릿 버전 refresh 가 이 권한을 썼다.
  #   · 이 권한이 있는 한 PR 에 들어간 코드가 실제 현재 값을 바로 읽을 수 있다.
  # → 03 을 CI plan 에서 빼고, 02 는 시크릿 "그릇"만 관리하게 바꿔 권한 자체를 없앴다.
  #   다시 필요해 보이면 그 plan 을 CI 가 아니라 로컬에서 하는 게 맞다.
}

# CI plan 이 읽을 수 있는 state — 영속 스택 중 시크릿을 품지 않는 01·02 만 (A-1)
locals {
  plan_state_keys = [
    "stacks/01-network/terraform.tfstate",
    "stacks/02-security/terraform.tfstate",
  ]
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
