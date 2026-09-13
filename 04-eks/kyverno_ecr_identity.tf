# ============================================================
# 04-eks/kyverno_ecr_identity.tf — Stage 7 (신규)
# ============================================================
# ★ 체크리스트 #2 — 정적 PEM 만으로는 부족하다.
#
#   Kyverno 가 서명을 "검증"하려면 두 가지가 필요하다:
#     ① 검증 material (공개키)  → 정책에 PEM 삽입 (02 가 SSM 으로 전달)
#     ② 서명 아티팩트 가져오기   → **프라이빗 ECR 접근 권한**  ← 여기
#
#   정적 PEM 은 ①만 해결한다. ②는 여전히 레지스트리 인증이 필요하다.
#   → "무엇으로 검증하는가"와 "검증 대상을 어떻게 가져오는가"는 별개 문제.
#
# Pod Identity 패턴의 네 번째 적용:
#   S1 LB Controller / S2 앱 데모 / S4 Secrets CSI(ASCP) / S7 Kyverno
#
# ⚠ KMS 권한은 주지 않는다 — ECR 이 images CMK grant 로 복호화를 대행한다
#   (S6 의 판정 번복에서 확인한 모델. Secrets Manager 와 다르다)
# ============================================================

data "aws_iam_policy_document" "kyverno_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole", "sts:TagSession"]
  }
}

data "aws_iam_policy_document" "kyverno_ecr_read" {
  # 인증 토큰 — 리소스 수준 제한 미지원(AWS API 제약)
  statement {
    sid       = "EcrAuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # 서명 아티팩트 조회·다운로드 — 앱 리포지토리 하나로 스코프
  #   cosign v3 는 OCI 1.1 referrers 로 서명을 저장하므로
  #   Kyverno 가 /v2/<repo>/referrers/<digest> 를 호출한다 → 아래 권한 필요
  statement {
    sid    = "ReadAppRepositoryOnly"
    effect = "Allow"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = [nonsensitive(data.aws_ssm_parameter.app_repository_arn.value)]
  }

  # 의도적 부재: ecr:PutImage / BatchDeleteImage / kms:*
  #   Kyverno 는 읽기만 한다. 이미지를 밀거나 지울 수 없다.
}

data "aws_ssm_parameter" "app_repository_arn" {
  name = "/${var.project_name}/security/ecr_repository_arn"
}

resource "aws_iam_role" "kyverno_ecr" {
  name               = "${var.cluster_name}-kyverno-ecr-read"
  assume_role_policy = data.aws_iam_policy_document.kyverno_trust.json
  tags               = { Name = "${var.cluster_name}-kyverno-ecr-read" }
}

resource "aws_iam_role_policy" "kyverno_ecr" {
  name   = "ecr-read-app-repo"
  role   = aws_iam_role.kyverno_ecr.id
  policy = data.aws_iam_policy_document.kyverno_ecr_read.json
}

# SA 이름은 Kyverno helm 차트의 admission controller SA 와 일치해야 한다.
# ⚠ 차트 버전에 따라 SA 이름이 다를 수 있다 — apply 후 반드시 확인:
#     kubectl -n kyverno get sa
#   불일치하면 association 이 무의미하고, 증상은 "서명은 됐는데 검증 실패"다.
resource "aws_eks_pod_identity_association" "kyverno" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kyverno"
  service_account = var.kyverno_admission_sa_name
  role_arn        = aws_iam_role.kyverno_ecr.arn
}

variable "kyverno_admission_sa_name" {
  description = <<-EOT
    Kyverno admission controller 의 ServiceAccount 이름.
    차트 기본값은 보통 "kyverno-admission-controller" 이나 버전에 따라 다르다.
    확인: kubectl -n kyverno get sa
  EOT
  type        = string
  default     = "kyverno-admission-controller"
}
