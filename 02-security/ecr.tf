# 영속 스택에 둔다. 클러스터(04·05)를 지워도 이미지와 digest가 남아 있어야 재배포 기준이 유지된다.

# 이미지 전용 키. 로그·시크릿·EBS 키와 목적이 달라서 같이 쓰지 않는다.
resource "aws_kms_key" "images" {
  description             = "${var.project_name} container image encryption (ECR)"
  enable_key_rotation     = true
  deletion_window_in_days = 7

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
        # ECR을 거쳐 쓰는 grant/키 사용 조건을 적어 둔다.
        # image push/pull 주체에게 KMS data-plane 권한을 직접 주는 게 아니라,
        # ECR 서비스가 repository를 만들 때 받아 둔 KMS grant로 암복호화한다.
        Sid       = "AllowECRUse"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
          "kms:CreateGrant",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ecr.${data.aws_region.current.name}.amazonaws.com"
          }
        }
      },
    ]
  })

  tags = { Name = "${var.project_name}-images-kms" }
}

resource "aws_kms_alias" "images" {
  name          = "alias/${var.project_name}-images"
  target_key_id = aws_kms_key.images.key_id
}

resource "aws_ecr_repository" "app" {
  #checkov:skip=CKV_AWS_163:스캔은 레지스트리 단위 Inspector Enhanced Scanning 이 담당 — scan_on_push 는 Basic 전용 설정
  name = "${var.project_name}/app"

  image_tag_mutability = "IMMUTABLE"

  # scan_on_push는 안 둔다. Basic 스캔용 설정이고, 이 계정은 레지스트리 단위 Enhanced(지속 스캔, 전체 리포지토리)를 쓴다.
  # 확인: aws ecr get-registry-scanning-configuration의 scanType = ENHANCED
  # Trivy(푸시 전 차단)와 Inspector(푸시 후 계속 재평가)는 시점이 다른 이중화다.

  # ECR 암호화 설정은 리포지토리를 만든 뒤에는 못 바꾼다. 그래서 처음부터 CMK로 만든다.
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.images.arn
  }

  # 데모 리포지토리라 이미지가 남아 있어도 destroy할 수 있게 한다(운영이라면 false).
  force_delete = true

  tags = { Name = "${var.project_name}-app-ecr" }
}

# untagged 이미지만 1일 뒤 지우고, 태그 붙은 이미지는 자동으로 만료하지 않는다.
# 05의 기준 이미지(app_image_tag/digest)나 CI가 재사용하는 s6-<sha>가 사라지면 재배포가 깨져서, 태그 이미지 정리는 수동으로 한다.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day; preserve tagged artifacts"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
    ]
  })
}

# SSM 발행(05-k8s가 이미지 URL을 참조)
resource "aws_ssm_parameter" "ecr_repository_url" {
  name  = "/${var.project_name}/security/ecr_repository_url"
  type  = "String"
  value = aws_ecr_repository.app.repository_url

  tags = { Name = "${var.project_name}-ecr-repository-url" }
}

resource "aws_ssm_parameter" "images_kms_key_arn" {
  name  = "/${var.project_name}/security/images_kms_key_arn"
  type  = "String"
  value = aws_kms_key.images.arn

  tags = { Name = "${var.project_name}-images-kms-key-arn" }
}

resource "aws_ssm_parameter" "ecr_repository_arn" {
  name  = "/${var.project_name}/security/ecr_repository_arn"
  type  = "String"
  value = aws_ecr_repository.app.arn

  tags = { Name = "${var.project_name}-ecr-repository-arn" }
}
