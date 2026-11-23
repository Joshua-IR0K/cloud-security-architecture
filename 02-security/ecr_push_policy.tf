# build 역할은 00에서 만들고, ECR push 정책은 ECR을 가진 02가 정의해서 붙인다(역할 ARN은 SSM으로 받는다).

data "aws_ssm_parameter" "github_build_role_arn" {
  name = "/${var.project_name}/bootstrap/github_build_role_arn"
}

data "aws_iam_policy_document" "ecr_push" {
  #checkov:skip=CKV_AWS_107:ecr-public 인증 토큰 — 이 역할에 ECR Public 쓰기 권한이 없어 토큰으로 할 수 있는 일은 공개 이미지 pull 뿐
  # 인증 토큰. 리소스 수준 제한이 없어서 "*". 이것만으로는 어느 리포지토리에도 쓸 수 없다.
  statement {
    sid       = "EcrAuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # 실제 push. 이 리포지토리 하나로만 묶는다.
  statement {
    sid    = "PushToAppRepositoryOnly"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      # 아래 3개는 push 전 존재 확인과 digest 조회에 필요하다(SBOM 기준점).
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:BatchGetImage",
      # SBOM을 레지스트리에 올라간 digest 기준으로 만들어서, syft가 레지스트리에서 레이어를 다시 읽는다.
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  # 워크플로가 역할을 받자마자 이 파라미터 하나로 리포지토리 URL을 얻는다. 없으면 빌드 전에 AccessDenied가 난다.
  statement {
    sid       = "ReadEcrRepositoryUrlOnly"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.ecr_repository_url.arn]
  }

  # ECR Public 인증 토큰. 베이스 이미지를 인증된 pull로 받는다. GitHub 러너는 IP를 같이 써서 익명 pull 한도에 막힐 수 있다
  # ("toomanyrequests: Data limit exceeded"). 토큰 발급뿐이고 리소스 수준 제한이 없어서 "*"다.
  statement {
    sid       = "EcrPublicAuthTokenForBasePull"
    effect    = "Allow"
    actions   = ["ecr-public:GetAuthorizationToken", "sts:GetServiceBearerToken"]
    resources = ["*"]
  }

  # KMS 권한은 안 둔다. CMK 리포지토리도 ECR 서비스가 grant로 암복호화하니까 푸셔한테는 필요 없다.
  # (Secrets Manager처럼 호출자가 키 권한을 가져야 하는 방식과 다르다)

  # 일부러 안 준 권한:
  #   ecr:Create/DeleteRepository, SetRepositoryPolicy: 레지스트리 구조는 Terraform이 관리한다
  #   ecr:BatchDeleteImage: 지우고 다시 올리는 식으로 IMMUTABLE을 우회하지 못하게
  #   ecr-public 쓰기: 공개 레지스트리에는 안 올린다
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
