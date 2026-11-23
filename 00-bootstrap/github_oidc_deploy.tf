# AWS 권한은 eks:DescribeCluster 하나. 쿠버네티스 권한은 EKS 접근 항목과 네임스페이스 RBAC(04·05)이 정한다.
# CodeBuild 러너에서 돌아도 AWS 접근은 이 역할로 한다 — 러너 서비스 역할(02)은 배관만 맡음

data "aws_iam_policy_document" "github_assume_deploy" {
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

    # main ref 만 — PR(공개 전환 후 포크 PR 포함)은 배포 경로를 실행할 수 없음
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:ref:refs/heads/main"
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_deploy" {
  name                 = "${var.project_name}-github-actions-deploy"
  assume_role_policy   = data.aws_iam_policy_document.github_assume_deploy.json
  max_session_duration = 3600

  tags = {
    Name    = "${var.project_name}-github-actions-deploy"
    Purpose = "ci-eks-image-rollout"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# kubeconfig 생성(aws eks update-kubeconfig)에 필요한 DescribeCluster만. 클러스터 변경·노드·ECR 권한은 없음
data "aws_iam_policy_document" "deploy_permissions" {
  statement {
    sid       = "DescribeClusterForKubeconfig"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/*"]
  }
}

resource "aws_iam_role_policy" "deploy_permissions" {
  name   = "${var.project_name}-deploy-permissions"
  role   = aws_iam_role.github_actions_deploy.id
  policy = data.aws_iam_policy_document.deploy_permissions.json
}

# 04-eks 가 access entry 생성에 이 ARN 을 참조한다
resource "aws_ssm_parameter" "github_deploy_role_arn" {
  name        = "/${var.project_name}/bootstrap/github_deploy_role_arn"
  description = "GitHub Actions deploy role ARN — consumed by 04-eks for the EKS access entry"
  type        = "String"
  value       = aws_iam_role.github_actions_deploy.arn

  tags = { Name = "${var.project_name}-github-deploy-role-arn" }
}

output "github_actions_deploy_role_arn" {
  description = "레포 Variables 의 AWS_DEPLOY_ROLE_ARN 에 등록할 값"
  value       = aws_iam_role.github_actions_deploy.arn
}
