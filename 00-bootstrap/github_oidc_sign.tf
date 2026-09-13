# ============================================================
# 00-bootstrap/github_oidc_sign.tf — Stage 7 서명 전용 역할 (신규)
# ============================================================
# 역할 4분할의 마지막: plan / build / deploy / **sign**
#
# 왜 gha-build 에 kms:Sign 을 얹지 않는가 — 이것이 S7 thesis 의 핵심이다:
#   빌드 역할이 서명까지 할 수 있으면 "빌드 경로 침해 → 임의 아티팩트 서명"이 되어
#   admission 통제 전체가 무력화된다. 서명 권한(signing authority)의 분리가
#   S7 보안 주장의 하중을 진다.
#
# ⚠ 방어 범위의 정직한 한정 (ADR 기록 대상):
#   같은 워크플로에서 두 역할을 모두 수임할 수 있으므로, 이 분리가 막는 것은
#   **자격증명 유출**이지 **워크플로 자체의 침해**가 아니다.
#   워크플로 침해까지 막으려면 서명을 별도 job + GitHub Environment 승인으로
#   분리해야 한다 → 프로덕션 델타로 기록하고 이번 스코프에서는 하지 않는다.
# ============================================================

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

# ⚠ 이 역할에는 여기서 정책을 붙이지 않는다.
#   kms:Sign 은 **키 정책**(02-security/signing_key.tf)이 principal 로 직접 위임한다.
#   → 키 소유 스택이 그 키의 사용 주체를 정의한다는 원칙.
#
# ⚠ 단 ECR 권한은 **필요하다** — cosign 은 서명값 생성 후 아티팩트를
#   레지스트리에 push 하기 때문이다. 그 정책은 02-security 가 소유·부착한다
#   (리소스 소유 스택이 그 리소스 권한을 정의한다는 원칙).
#
# 의도적 부재: EKS 배포 / Secrets 접근 / ECR 삭제 — 이 역할은 서명하고 저장만 한다.

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
