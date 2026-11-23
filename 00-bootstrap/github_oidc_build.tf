# build 역할. plan 역할과 따로 둬서, 워크플로 하나가 뚫려도 읽기 권한과 레지스트리 쓰기 권한이 같이 넘어가지 않게 한다.

# main에서만 받을 수 있다. PR(포크 포함)에서 아무 이미지나 레지스트리에 넣는 길을 막는다.
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

    # main ref만 허용하고 pull_request는 없다.
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

# 정책은 여기서 안 붙인다. 02가 SSM으로 이 ARN을 받아서 ECR push 정책을 붙인다.
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
