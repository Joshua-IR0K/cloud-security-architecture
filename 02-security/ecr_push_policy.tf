# build 역할은 00 소유, ECR push 정책은 ECR 을 가진 02 가 정의해 붙인다 (역할 ARN 은 SSM 으로 받는다)

data "aws_ssm_parameter" "github_build_role_arn" {
  name = "/${var.project_name}/bootstrap/github_build_role_arn"
}

data "aws_iam_policy_document" "ecr_push" {
  #checkov:skip=CKV_AWS_107:ecr-public 인증 토큰 — 이 역할에 ECR Public 쓰기 권한이 없어 토큰으로 할 수 있는 일은 공개 이미지 pull 뿐
  # 인증 토큰 — 리소스 수준 제한이 없어 "*". 이것만으로는 어느 리포지토리에도 쓸 수 없다
  statement {
    sid       = "EcrAuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # 실제 push — 이 리포지토리 하나로 한정
  statement {
    sid    = "PushToAppRepositoryOnly"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      # 아래 3개는 push 전 존재 확인·digest 조회에 필요 (SBOM 기준점 획득)
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:BatchGetImage",
      # SBOM 을 레지스트리에 올라간 digest 기준으로 만들어서, syft 가 레지스트리에서 레이어를 다시 읽는다
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  # 워크플로가 수임 직후 이 파라미터 하나로 리포지토리 URL 을 얻는다 — 없으면 빌드 전에 AccessDenied
  statement {
    sid       = "ReadEcrRepositoryUrlOnly"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.ecr_repository_url.arn]
  }

  # ECR Public 인증 토큰 — 베이스 이미지를 인증된 pull 로 받는다. GitHub 러너는 IP 를 공유해 익명 pull 한도에 막힐 수 있다
  # ("toomanyrequests: Data limit exceeded"). 토큰 발급뿐이고 리소스 수준 제한이 없어 "*" 다.
  statement {
    sid       = "EcrPublicAuthTokenForBasePull"
    effect    = "Allow"
    actions   = ["ecr-public:GetAuthorizationToken", "sts:GetServiceBearerToken"]
    resources = ["*"]
  }

  # KMS 권한은 두지 않는다 — CMK 리포지토리도 ECR 서비스가 grant 로 암복호화하므로 푸셔에게는 필요 없다.
  # (Secrets Manager 처럼 호출자가 키 권한을 가져야 하는 모델과 다르다)

  # 의도적 부재:
  #   ecr:Create/DeleteRepository, SetRepositoryPolicy — 레지스트리 구조는 Terraform 이 소유
  #   ecr:BatchDeleteImage — 지우고 다시 올리는 방식으로 IMMUTABLE 을 우회하지 못하게
  #   ecr-public 쓰기 — 공개 레지스트리에는 올리지 않는다
}

resource "aws_iam_policy" "ecr_push" {
  name        = "${var.project_name}-ecr-push"
  description = "Push images to the app repository only (S6-A)"
  policy      = data.aws_iam_policy_document.ecr_push.json
}

resource "aws_iam_role_policy_attachment" "github_build_ecr_push" {
  role       = element(split("/", nonsensitive(data.aws_ssm_parameter.github_build_role_arn.value)), 1)
  policy_arn = aws_iam_policy.ecr_push.arn
}
