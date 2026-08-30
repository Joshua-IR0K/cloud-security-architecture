# ============================================================
# 02-security/ecr_push_policy.tf — S6-A (신규)
# ============================================================
# S5 에서 "정책은 만들되 attach 는 하지 않는다"고 미뤄둔 그 정책이다.
#   S5: GitHub 이 아직 push 하지 않으므로 권한을 열지 않음
#   S6-A: CI 가 실제로 push 하므로 이제 attach
#   → 최소권한의 "시간축" — 사용하지 않는 권한을 한 스테이지 먼저 열지 않는다.
#
# 소유권 배치:
#   역할 자체        → 00-bootstrap (OIDC provider 와 한 몸)
#   ECR push 정책    → 02-security  (ECR 소유 스택이 그 권한을 정의)
#   역할 ARN 전달    → SSM (/bootstrap/github_build_role_arn)
#   ⚠ 참조 방향: 02(상위) → 00(토대) 읽기. 토대가 상위를 참조하지 않으므로
#     방향 원칙 위반이 아니다.
# ============================================================

data "aws_ssm_parameter" "github_build_role_arn" {
  name = "/${var.project_name}/bootstrap/github_build_role_arn"
}

data "aws_iam_policy_document" "ecr_push" {
  # ① 인증 토큰 — 리소스 수준 제한 미지원(AWS API 제약)
  #    GetAuthorizationToken 은 계정 단위로만 부여 가능하다.
  #    이 권한만으로는 어떤 리포지토리에도 쓸 수 없다(아래 ②가 실제 게이트).
  statement {
    sid       = "EcrAuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # ② 실제 push — 이 리포지토리 "하나"로 핀포인트
  #    계정의 다른 ECR 리포지토리에는 쓸 수 없다.
  #    (LB Controller 정책을 TG ARN 하나로 좁힌 D13 과 같은 철학)
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
      # SBOM 을 "레지스트리에 올라간 digest" 기준으로 생성하므로,
      # syft 가 registry 에서 레이어를 다시 읽을 수 있어야 한다.
      # (로컬 daemon 캐시로 해결될 수도 있으나 계약을 명시적으로 만든다)
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  # ③ SSM — ECR 리포지토리 URL 조회 (P0 추가)
  #   워크플로가 OIDC 수임 직후 이 파라미터를 읽어 리포지토리 URL 을 얻는다.
  #   이 권한이 없으면 "Resolve ECR repository" 스텝에서 AccessDenied 로
  #   **docker build 에 도달하기도 전에** 실패한다.
  #   ⚠ 프로젝트 경로 와일드카드가 아니라 **그 파라미터 하나**로 스코프.
  statement {
    sid       = "ReadEcrRepositoryUrlOnly"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.ecr_repository_url.arn]
  }

  # ⚠ KMS 권한을 두지 않는다 (판정 번복 기록):
  #   초안은 "ecr:PutImage(데이터) + kms:GenerateDataKey(키)의 이중 관문"이라는
  #   S4(Secrets Manager) 모델을 그대로 이식했으나 **ECR 은 다르다.**
  #   customer-managed key 로 암호화된 리포지토리는 생성 시 ECR 이 KMS grant 를
  #   받고, **ECR 서비스가** push 시 GenerateDataKey / pull 시 Decrypt 를 수행한다.
  #   AWS 공식 "이미지 푸시에 필요한 IAM 권한" 문서에도 KMS 액션이 없다.
  #   (kms:CreateGrant/RetireGrant/DescribeKey 는 **리포지토리 생성·삭제 주체**의
  #    권한이지 푸셔의 권한이 아니다 — 그건 02 의 Terraform 실행 주체가 갖는다)
  #
  #   교훈: 보안 패턴을 서비스 간에 일반화하기 전에 그 서비스의 KMS 통합 모델을
  #   확인해야 한다. 우리 프로젝트만 봐도 두 모델이 공존한다 —
  #     호출자가 키 권한 보유 : Secrets Manager (S4)
  #     서비스가 grant 로 대행 : ECR (여기), EBS (ASG SLR, 게이트 #1)

  # 의도적 부재:
  #   ecr:CreateRepository / DeleteRepository / SetRepositoryPolicy
  #     → 레지스트리 구조는 Terraform(02)이 소유한다. CI 는 이미지만 민다.
  #   ecr:BatchDeleteImage
  #     → IMMUTABLE 정책을 CI 가 우회할 수 없게 한다.
  #       (삭제로 태그를 비운 뒤 재푸시하면 사실상 덮어쓰기가 되기 때문)
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
