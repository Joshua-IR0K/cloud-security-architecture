variable "github_repo" {
  description = "GitHub 레포 (owner/repo 형식)"
  type        = string
  default     = "Joshua-IR0K/cloud-security-architecture"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS는 GitHub OIDC를 자체 신뢰 CA로 검증해서 이 값을 쓰지 않는다. 값 하나면 충분하고 인증서가 바뀌어도 안 끊긴다(provider 5.x 필수 필드).
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    Name = "${var.project_name}-github-oidc"
  }

  # 영속 리소스라 실수로 destroy되지 않게 막는다(지우면 CI/CD 전체가 멈춘다).
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

    # pull_request만 신뢰한다(StringEquals). 안 쓰는 ref는 신뢰에서 뺐다.
    # Environment로 sub를 고정하지 않는다. 비공개+Free 플랜에서는 보호 규칙이 없어서 고정해도 통제가 안 생긴다. 공개로 바꾸면 environment 고정과 required reviewer를 건다.
    # 포크 PR은 id-token 권한이 없어서 OIDC 토큰을 못 받는다.
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
  max_session_duration = 3600  # AWS 최소값(IAM Role은 3600~43200만 허용)

  tags = {
    Name    = "${var.project_name}-github-actions-plan"
    Purpose = "ci-terraform-plan-only"
  }

  lifecycle {
    prevent_destroy = true
  }
}

data "aws_iam_policy_document" "plan_permissions" {
  # 읽기 권한은 CI가 plan하는 01·02가 실제로 쓰는 서비스만 준다. Describe/List는 대부분 리소스 수준 제한이 없어서 "*".
  # 조회 API라도 비밀을 돌려줄 수 있는 건 뺐다: cloudfront Get/ListDistributions·elb DescribeRules(오리진 헤더 값), wafv2 GetSampledRequests(요청 헤더), config Get*(설정 이력).
  # logs는 메타데이터와 저장 쿼리 정의 조회만 준다. 로그 내용(GetLogEvents·FilterLogEvents·StartQuery)은 빼고, 가드가 확인한다.

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
      # 02의 aws_cloudwatch_log_group refresh용(메타데이터만, 내용 읽기 권한은 아님)
      "logs:DescribeLogGroups",
      "logs:ListTagsForResource",
      "logs:ListTagsLogGroup",
      # 02의 aws_cloudwatch_query_definition refresh용(저장 쿼리 정의만, 실행 권한 StartQuery는 없음)
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
      "config:Describe*",  # recorder·channel·status 조회(설정 이력 내용을 돌려주는 Get*는 뺐다)
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
      # 02-security ECR repository/lifecycle refresh용
      "ecr:DescribeRepositories",
      "ecr:DescribeImages",
      "ecr:GetLifecyclePolicy",
      "ecr:GetRepositoryPolicy",
      "ecr:GetRegistryScanningConfiguration",
      "ecr:ListTagsForResource",
      # 02-security CodeBuild project/webhook refresh용
      "codebuild:BatchGetProjects",
      "codebuild:ListProjects"
    ]
    resources = ["*"]
  }

  # 02의 서명 공개키 조회(GetPublicKey). 공개키라 민감하지 않다.
  statement {
    sid       = "KmsGetPublicKeyForDataSource"
    effect    = "Allow"
    actions   = ["kms:GetPublicKey"]
    resources = ["arn:aws:kms:${var.aws_region}:${data.aws_caller_identity.current.account_id}:key/*"]
  }

  # SSM은 프로젝트 경로만. SecureString 파라미터는 없다.
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
    resources = ["*"]  # DescribeParameters는 리소스 제한을 지원하지 않는다
  }

  # S3 버킷 구성 조회는 프로젝트 버킷 패턴으로만 묶는다. 객체 읽기는 state 두 파일뿐이다.
  # 이 statement에 ListBucket을 넣지 않는다. 넣으면 state 버킷 전체 목록까지 열린다(statement끼리는 OR로 합쳐진다).
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

  # 02 로그 버킷 존재 확인. aws_s3_bucket refresh의 HeadBucket이 s3:ListBucket을 요구한다. 범위는 로그 버킷 4개와 Athena 결과 버킷.
  # 이게 없으면 plan이 실패하지 않고 버킷을 "없음"으로 보고 다시 만들려고 한다. 에러 없이 틀린 plan이 나온다.
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

  # Athena 조사 계층 refresh용. provider 5.100.0이 실제로 부르는 Get*만 준다(Glue 데이터베이스·테이블, Athena 워크그룹·저장 쿼리).
  # 쿼리 실행, 결과 조회, 결과 버킷 GetObject는 없다. 가드가 확인한다.
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

  # State는 01·02만 읽는다. 03은 Okta 시크릿과 Origin 헤더 값이 들어 있어서 막았고(plan은 로컬에서만),
  # 04·05는 임시 스택이라 CI plan 대상이 아니다. 00은 로컬 state다.

  # State 객체 읽기. 01·02 두 파일만
  statement {
    sid       = "StateObjectReadPersistentStacks"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [for k in local.plan_state_keys : "${aws_s3_bucket.terraform_state.arn}/${k}"]
  }

  # 버킷 목록은 워크스페이스 접두어(env:/)만 연다. S3 백엔드가 init·plan 때 조회한다. 그 외 목록은 거부.
  # 부작용: ListBucket이 없으면 없는 객체도 404가 아니라 403이 온다. 거부 확인은 정책 시뮬레이터로 한다.
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

  # 잠금 테이블. CI plan은 -lock=false라 쓰지 않는다. state 다이제스트(<버킷>/<키>-md5) GetItem만, 01·02 항목으로 묶는다.
  # Null=false를 짝으로 둔다. ForAllValues는 키가 없으면 참으로 판정하기 때문이다.
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
    actions   = ["dynamodb:DescribeTable"]  # 테이블 상태 확인(간헐 실패 방지)
    resources = [aws_dynamodb_table.terraform_lock.arn]
  }

  # 시크릿 권한은 일부러 안 줬다. GetSecretValue·kms:Decrypt가 있으면 PR 코드가 지금 시크릿 값을 읽을 수 있다.
  # 그래서 03은 CI plan에서 빼고, 02는 시크릿 그릇만 관리한다. 필요해 보이면 그 plan은 로컬에서 한다.
}

# CI plan이 읽을 수 있는 state. 영속 스택 중 시크릿이 없는 01·02만
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
