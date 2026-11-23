# 서명 역할 — 현재 워크플로에는 연결하지 않았다 (README 다음 단계 "이미지 서명과 admission 검증")
# build 역할과 분리한다 — build 경로가 뚫려도 임의 이미지에 서명할 수 없게
# 한계: 같은 워크플로가 두 역할을 모두 받을 수 있어, 막는 것은 자격증명 유출이지 워크플로 침해가 아니다 (막으려면 별도 job + 승인 게이트)

data "aws_iam_policy_document" "github_assume_sign" {
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

    # main ref 만 — PR 에서는 서명 역할을 수임할 수 없다
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_actions_sign" {
  name                 = "${var.project_name}-github-actions-sign"
  assume_role_policy   = data.aws_iam_policy_document.github_assume_sign.json
  max_session_duration = 3600

  tags = {
    Name    = "${var.project_name}-github-actions-sign"
    Purpose = "ci-image-signing"
  }

  lifecycle { prevent_destroy = true }
}

# 정책은 여기서 붙이지 않음 — kms:Sign 은 키 정책(02 signing_key.tf)이, 서명 아티팩트용 ECR 쓰기는 02 의 정책이 위임한다.
# 의도적 부재: EKS 배포, Secrets 접근, ECR 삭제.

resource "aws_ssm_parameter" "github_sign_role_arn" {
  name        = "/${var.project_name}/bootstrap/github_sign_role_arn"
  description = "GitHub Actions sign role ARN — consumed by 02-security key policy"
  type        = "String"
  value       = aws_iam_role.github_actions_sign.arn
  tags        = { Name = "${var.project_name}-github-sign-role-arn" }
}

output "github_actions_sign_role_arn" {
  description = "레포 Variables 의 AWS_SIGN_ROLE_ARN 에 등록할 값"
  value       = aws_iam_role.github_actions_sign.arn
}
