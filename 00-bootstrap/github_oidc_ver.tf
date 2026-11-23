variable "github_repo" {
  description = "GitHub 레포 (owner/repo 형식)"
  type        = string
  default     = "Joshua-IR0K/cloud-security-architecture"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS 는 GitHub OIDC 를 자체 신뢰 CA 로 검증해 이 값을 쓰지 않는다 — 단일 값이면 충분하고 인증서가 바뀌어도 끊기지 않음 (provider 5.x 필수 필드)
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    Name = "${var.project_name}-github-oidc"
  }

  # 영속 리소스 — 실수 destroy 방지 (CI/CD 전체 중단 방지)
  lifecycle {
    prevent_destroy = true
  }
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # pull_request 만 신뢰한다 (StringEquals). 쓰지 않는 ref 는 신뢰에서 뺐다.
    # Environment 로 sub 를 핀하지 않는다 — 비공개+Free 에서는 보호 규칙이 없어 통제가 생기지 않는다. 공개 전환 시 environment 핀 + required reviewer.
    # 포크 PR 은 id-token 권한이 없어 OIDC 토큰을 받지 못함
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:pull_request"]
    }
  }
}

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

data "aws_iam_policy_document" "plan_permissions" {
  # 읽기 — CI 가 plan 하는 01·02 가 실제로 쓰는 서비스만. Describe/List 는 대부분 리소스 수준 제한이 없어 "*".
  # 조회 API 도 비밀을 돌려줄 수 있어 뺐다: cloudfront Get/ListDistributions·elb DescribeRules(오리진 헤더 값), wafv2 GetSampledRequests(요청 헤더), config Get*(설정 이력).
  # logs 는 메타데이터와 저장 쿼리 정의 조회만 — 로그 내용(GetLogEvents·FilterLogEvents·StartQuery)은 제외하고 가드가 확인함.

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
      # 02-security ECR repository/lifecycle refresh
      "ecr:DescribeRepositories",
      "ecr:DescribeImages",
      "ecr:GetLifecyclePolicy",
      "ecr:GetRepositoryPolicy",
      "ecr:GetRegistryScanningConfiguration",
      "ecr:ListTagsForResource",
      # 02-security CodeBuild project/webhook refresh
      "codebuild:BatchGetProjects",
      "codebuild:ListProjects"
    ]
    resources = ["*"]
  }

  # 02 의 서명 공개키 조회(GetPublicKey) — 공개키라 민감하진 않음
  statement {
    sid       = "KmsGetPublicKeyForDataSource"
    effect    = "Allow"
    actions   = ["kms:GetPublicKey"]
    resources = ["arn:aws:kms:${var.aws_region}:${data.aws_caller_identity.current.account_id}:key/*"]
  }

  # SSM — 프로젝트 경로만. SecureString 파라미터는 없음
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

  # S3 버킷 구성 조회 — 프로젝트 버킷 패턴으로 한정. 객체 읽기는 state 두 파일만.
  # 이 statement 에 ListBucket 을 넣지 않는다 — state 버킷 전체 목록까지 열림(statement 는 OR 로 합쳐짐)
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

  # 02 로그 버킷 존재 확인 — aws_s3_bucket refresh 의 HeadBucket 은 s3:ListBucket 을 요구한다. 범위: 로그 버킷 4개 + Athena 결과 버킷.
  # 없으면 plan 이 실패하지 않고 버킷을 "없음"으로 보고 재생성을 계획한다 — 에러 없이 틀린 plan.
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

  # Athena 조사 계층 refresh — provider 5.100.0 이 실제로 부르는 Get* 만 (Glue 데이터베이스·테이블, Athena 워크그룹·저장 쿼리).
  # 쿼리 실행·결과 조회·결과 버킷 GetObject 는 없다 — 가드가 확인함
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

  # State — 01·02 만 읽는다. 03 은 Okta 시크릿과 Origin 헤더 값이 들어 있어 차단(plan 은 로컬에서만),
  # 04·05 는 임시 스택이라 CI plan 대상이 아니다. 00 은 로컬 state

  # State 객체 읽기 — 01·02 두 파일만
  statement {
    sid       = "StateObjectReadPersistentStacks"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [for k in local.plan_state_keys : "${aws_s3_bucket.terraform_state.arn}/${k}"]
  }

  # 버킷 목록은 워크스페이스 접두어(env:/)만 — S3 백엔드가 init·plan 때 조회한다. 그 외 목록은 거부.
  # 부수 효과: ListBucket 이 없으면 없는 객체도 404 가 아니라 403 이 온다. 거부 확인은 정책 시뮬레이터로.
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

  # 잠금 테이블 — CI plan 은 -lock=false 라 쓰지 않는다. state 다이제스트(<버킷>/<키>-md5) GetItem 만, 01·02 항목으로 한정.
  # Null=false 를 짝으로 둔다 — ForAllValues 는 키가 없으면 참으로 판정됨
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

  # 시크릿 — 의도적 부재. GetSecretValue·kms:Decrypt 가 있으면 PR 코드가 현재 시크릿 값을 읽을 수 있음
  # 그래서 03 은 CI plan 에서 빼고 02 는 시크릿 그릇만 관리한다. 필요해 보이면 그 plan 은 로컬에서 한다.
}

# CI plan 이 읽을 수 있는 state — 영속 스택 중 시크릿을 품지 않는 01·02 만
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

output "github_actions_role_arn" {
  description = "GitHub Actions 워크플로우에 넣을 Role ARN"
  value       = aws_iam_role.github_actions_plan.arn
}
