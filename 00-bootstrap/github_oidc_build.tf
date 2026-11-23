# build 역할 — plan 역할과 분리해, 워크플로 하나가 뚫려도 읽기와 레지스트리 쓰기가 함께 넘어가지 않게 한다

# main 에서만 수임 — PR(포크 포함)에서 임의 이미지를 레지스트리에 넣는 경로를 막음
data "aws_iam_policy_document" "github_assume_build" {
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

    # main ref 만 — pull_request 없음
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:ref:refs/heads/main"
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_build" {
  name                 = "${var.project_name}-github-actions-build"
  assume_role_policy   = data.aws_iam_policy_document.github_assume_build.json
  max_session_duration = 3600

  tags = {
    Name    = "${var.project_name}-github-actions-build"
    Purpose = "ci-build-and-ecr-push"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# 정책은 여기서 붙이지 않는다 — 02 가 SSM 으로 이 ARN 을 받아 ECR push 정책을 붙임
resource "aws_ssm_parameter" "github_build_role_arn" {
  name        = "/${var.project_name}/bootstrap/github_build_role_arn"
  description = "GitHub Actions build role ARN — consumed by 02-security to attach the ECR push policy"
  type        = "String"
  value       = aws_iam_role.github_actions_build.arn

  tags = { Name = "${var.project_name}-github-build-role-arn" }
}

output "github_actions_build_role_arn" {
  description = "레포 Variables 의 AWS_BUILD_ROLE_ARN 에 등록할 값"
  value       = aws_iam_role.github_actions_build.arn
}
