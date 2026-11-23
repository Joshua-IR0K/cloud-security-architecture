# ★ 이 역할의 AWS 권한은 극단적으로 좁다 — eks:DescribeCluster 하나뿐.
#   Kubernetes 에 대한 실제 권한은 IAM 이 아니라
#   EKS Access Entry + 네임스페이스 RBAC 이 결정한다(04/05).
#   → "AWS 권한"과 "K8s 권한"을 분리해 각각 최소화하는 구조.
#
# ⚠ CodeBuild 러너에서 실행되더라도 AWS 접근은 이 역할(GitHub OIDC)을 쓴다.
#   CodeBuild 서비스 역할은 러너 배관(VPC ENI/로그/연결)만 담당한다.
#   두 신원을 혼동하지 않는 것이 S6-B 의 핵심 보안 판단.

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

    # ★ main ref 만 — PR 에서는 배포 역할을 수임할 수 없다.
    #   신뢰 경계: untrusted PR(특히 향후 public 전환 시 fork PR)이
    #   프라이빗 배포 경로를 실행하지 못하게 하는 1차 방어.
    #   (2차 방어는 워크플로의 job 조건, 3차는 GitHub Environment 보호 규칙)
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

# AWS 권한: kubeconfig 생성에 필요한 최소
# aws eks update-kubeconfig 가 DescribeCluster 를 호출한다.
# 그 외 AWS 권한은 없다 — 클러스터 변경·노드 조작·ECR 접근 모두 불가.
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
