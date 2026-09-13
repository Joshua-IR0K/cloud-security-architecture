# ============================================================
# 02-security/signing_key.tf — Stage 7 서명 키 (신규)
# ============================================================
# ⚠ images CMK 를 재사용하지 않는다 — 암호화와 서명은 다른 보안 속성이고
#   KMS 키 사양(key_usage)부터 다르다:
#     images  : SYMMETRIC_DEFAULT / ENCRYPT_DECRYPT  → ECR at-rest 암호화
#     signing : ECC_NIST_P256    / SIGN_VERIFY       → cosign 이미지 서명
#   목적별 키 분리의 다섯 번째 (logs/secrets/ebs/images/signing).
#
# 왜 ECC_NIST_P256 인가: cosign 이 기본 지원하고 RSA 대비 서명이 짧고 빠르다.
# ⚠ 비대칭 키는 AWS 자동 회전을 지원하지 않는다 → 공개키가 고정된다.
#   그래서 Kyverno 정책에 **정적 PEM** 을 넣을 수 있다(런타임 KMS 호출 불필요).
#   회전이 필요하면 새 키를 만들고 정책의 PEM 을 교체하는 명시적 절차를 밟는다.
# ============================================================

resource "aws_kms_key" "signing" {
  description              = "${var.project_name} container image signing (cosign)"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_NIST_P256"
  deletion_window_in_days  = 7
  enable_key_rotation      = false # 비대칭 키는 자동 회전 미지원

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccount"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        # 서명 전용 역할에만 Sign 위임 (gha-sign, 00-bootstrap 소유)
        # ⚠ ViaService 조건을 걸지 않는다 — cosign 은 KMS API 를 직접 호출한다
        #   (S4 Secrets Manager 와 다른 모델. 서비스 경유가 아니다)
        Sid    = "AllowSignRoleToSign"
        Effect = "Allow"
        Principal = {
          AWS = nonsensitive(data.aws_ssm_parameter.github_sign_role_arn.value)
        }
        Action = [
          "kms:Sign",
          "kms:GetPublicKey",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
    ]
  })

  tags = { Name = "${var.project_name}-signing" }
}

resource "aws_kms_alias" "signing" {
  name          = "alias/${var.project_name}-signing"
  target_key_id = aws_kms_key.signing.key_id
}

data "aws_ssm_parameter" "github_sign_role_arn" {
  name = "/${var.project_name}/bootstrap/github_sign_role_arn"
}

# ── 공개키를 05-k8s 로 전달 (Kyverno 정책의 검증 material) ──
# ★ 이것이 "Kyverno 에 KMS 권한을 주지 않는" 방법이다:
#   런타임에 kms:Verify 를 호출하는 대신 공개키 PEM 을 정책에 박는다.
#   ⚠ 단 이것은 **검증 material** 문제만 해결한다 —
#     서명 아티팩트를 프라이빗 ECR 에서 "가져오는" 데는 여전히 ECR 읽기
#     권한이 필요하다(04-eks/kyverno_ecr_identity.tf).
#     "무엇으로 검증하는가"와 "검증 대상을 어떻게 가져오는가"는 별개 문제다.
data "aws_kms_public_key" "signing" {
  key_id = aws_kms_key.signing.key_id
}

resource "aws_ssm_parameter" "signing_key_arn" {
  name  = "/${var.project_name}/security/signing_key_arn"
  type  = "String"
  value = aws_kms_key.signing.arn
  tags  = { Name = "${var.project_name}-signing-key-arn" }
}

resource "aws_ssm_parameter" "signing_public_key_pem" {
  name        = "/${var.project_name}/security/signing_public_key_pem"
  description = "cosign verification material — consumed by 05-k8s Kyverno policy"
  type        = "String"
  value       = data.aws_kms_public_key.signing.public_key_pem
  tags        = { Name = "${var.project_name}-signing-public-key" }
}

output "signing_key_arn" {
  description = "cosign --key awskms:///<이 ARN>"
  value       = aws_kms_key.signing.arn
}

# ============================================================
# gha-sign 의 ECR 권한 — 서명 "아티팩트 저장"에 필요 (P0)
# ============================================================
# ⚠ 판정 정정 기록:
#   초안은 이 역할에 kms:Sign 만 주고 "서명만 하므로 ECR 불필요"라고 봤다. 틀렸다.
#   cosign 은 KMS 로 서명값을 만든 뒤 **서명 아티팩트를 레지스트리에 push** 한다.
#   ECR 권한이 없으면 `cosign sign` 이 push 단계에서 AccessDenied 로 실패한다.
#
#   같은 계열의 오류가 이 프로젝트에서 세 번째다:
#     S6 #9  ECR push 에 KMS 가 필요하다고 오판 (실제로는 ECR 이 grant 로 대행)
#     S7 #2  정적 PEM 이면 Kyverno 에 AWS 접근 불필요라고 오판 (아티팩트 pull 필요)
#     S7 여기 "서명만 한다"를 "ECR 에 안 쓴다"로 오판 (아티팩트 push 필요)
#   → 교훈: **"무엇을 하는가"가 아니라 "그것을 하려면 무엇이 필요한가"를 따진다.**
#
# 범위: 앱 리포지토리 하나에 아티팩트를 **쓰기**만. 삭제·리포지토리 관리는 없다.
data "aws_iam_policy_document" "sign_ecr_publish" {
  statement {
    sid       = "EcrAuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # 리소스 수준 제한 미지원 (AWS API 제약)
  }

  statement {
    sid    = "PublishSignatureArtifactOnly"
    effect = "Allow"
    actions = [
      # 서명 아티팩트 업로드 (OCI 1.1 referrer 또는 .sig 매니페스트)
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage",
      # 서명 대상 digest 확인 + verify 단계의 아티팩트 조회
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  # ★ P0: SSM 읽기 — 워크플로가 **sign 역할 상태에서** 두 값을 조회한다
  #   /security/signing_key_arn        → cosign --key awskms:///<arn>
  #   /security/signing_public_key_pem → cosign verify --key cosign.pub
  #   없으면 "Resolve signing material" 스텝에서 AccessDenied 로 서명에 도달조차 못 한다.
  #
  #   ⚠ 이 프로젝트에서 같은 유형의 네 번째 누락이다
  #     (S6 KMS 오판 / S7 Kyverno ECR / S7 sign ECR publish / 여기).
  #     공통 원인: "이 역할이 무엇을 하는가"만 보고
  #     "그 작업을 수행하려면 무엇에 접근해야 하는가"를 따지지 않은 것.
  statement {
    sid       = "ReadSigningMaterialOnly"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [
      aws_ssm_parameter.signing_key_arn.arn,
      aws_ssm_parameter.signing_public_key_pem.arn,
    ]
  }

  # 의도적 부재:
  #   ecr:BatchDeleteImage        — IMMUTABLE 우회 차단 (S6 push 정책과 동일 원칙)
  #   ecr:CreateRepository / SetRepositoryPolicy — 레지스트리 구조는 Terraform 소유
  #   kms:*                       — KMS 는 키 정책이 별도로 위임한다
}

resource "aws_iam_policy" "sign_ecr_publish" {
  name        = "${var.project_name}-sign-ecr-publish"
  description = "Publish cosign signature artifacts to the app repository only (S7)"
  policy      = data.aws_iam_policy_document.sign_ecr_publish.json
}

resource "aws_iam_role_policy_attachment" "github_sign_ecr" {
  role       = element(split("/", nonsensitive(data.aws_ssm_parameter.github_sign_role_arn.value)), 1)
  policy_arn = aws_iam_policy.sign_ecr_publish.arn
}
