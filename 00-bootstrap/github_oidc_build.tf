# ============================================================
# 00-bootstrap/github_oidc_build.tf — S6-A 빌드 전용 역할 (신규)
# ============================================================
# 왜 기존 plan 역할에 권한을 "추가"하지 않는가:
#   github_actions_plan 은 이름 그대로 plan 전용(방향 A)으로 설계됐다.
#   여기에 ECR push 를 얹으면 하나의 역할이
#     plan(읽기) + build(레지스트리 쓰기)
#   를 겸하게 되고, 워크플로 하나가 침해되면 두 권한이 함께 넘어간다.
#   → 역할을 목적별로 분리한다. 이것이 S6 의 첫 보안 결정이다.
#
#   [S6-A]  gha-build   : ECR push 만
#   [S6-B]  gha-deploy  : EKS 배포만 (별도 파일, 클러스터 필요 시점에)
#   [기존]  gha-plan    : 그대로 — 이 파일은 기존 역할을 건드리지 않는다
#
# 왜 00-bootstrap 인가:
#   OIDC provider 소유자가 여기이고, 신뢰 관계는 provider 와 한 몸이다.
#   ECR push "정책"은 02-security 가 소유해 attach 한다
#   (리소스 소유 스택이 그 리소스에 대한 권한을 정의한다는 원칙).
# ============================================================

# ── 신뢰 정책 — plan 역할과 다른 점 하나 ──────────────────
# plan 은 PR 이벤트에서 동작해야 하므로 pull_request 를 허용한다.
# build 는 **main 에 merge 된 뒤에만** 이미지를 밀어야 하므로
# pull_request 를 신뢰 대상에서 제외한다.
#   → fork/PR 에서 임의 이미지를 레지스트리에 넣는 경로를 원천 차단.
#   → 최소권한의 "시간축"(사용하지 않는 권한을 미리 열지 않음)과 같은 원칙.
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

    # ★ main ref 만 — pull_request 없음 (plan 역할과의 결정적 차이)
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

# ⚠ 이 역할에는 여기서 정책을 붙이지 않는다.
#   ECR push 정책은 02-security(ECR 소유 스택)가 생성해 attach 한다.
#   → 02 가 이 역할 ARN 을 알아야 하므로 SSM 으로 발행.
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
