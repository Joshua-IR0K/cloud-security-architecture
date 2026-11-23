# 이미지 서명용 KMS 키. 현재 워크플로에는 연결하지 않았다 (README 다음 단계 "이미지 서명과 admission 검증").
# images 키를 재사용하지 않는다 — 암호화(ENCRYPT_DECRYPT)와 서명(SIGN_VERIFY)은 키 사양부터 다르다.
# 비대칭 키는 자동 회전이 없어 공개키가 고정된다 → 검증 쪽에 공개키를 고정해 둘 수 있다. 회전은 새 키 + 공개키 교체로.

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
        # 서명 역할에만 Sign 을 위임하며, cosign 은 KMS API 를 직접 부르므로 ViaService 조건을 걸지 않음
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

# 공개키를 SSM 으로 발행한다 — 검증 쪽이 KMS 권한 없이 공개키만으로 검증하게. (서명 아티팩트를 ECR 에서 가져오는 권한은 별도)
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

# 서명 역할의 ECR 쓰기 권한 — cosign 은 서명 후 서명 아티팩트를 레지스트리에 push 한다.
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

  # 워크플로가 서명 역할로 키 ARN 과 공개키(SSM 두 파라미터)를 읽는다.
  statement {
    sid     = "ReadSigningMaterialOnly"
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      aws_ssm_parameter.signing_key_arn.arn,
      aws_ssm_parameter.signing_public_key_pem.arn,
    ]
  }

  # 의도적 부재:
  #   ecr:BatchDeleteImage        — IMMUTABLE 우회 차단 (build 역할 push 정책과 같은 원칙)
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
