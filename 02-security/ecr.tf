# ============================================================
# 02-security/ecr.tf — 컨테이너 이미지 레지스트리 (Stage 5)
# ============================================================
# 왜 02(영속 보안 스택)인가 (O3 결정):
#   ① 이미지는 클러스터 파괴에도 생존해야 한다 — 04/05 에 두면 사이클마다
#      소실돼 재빌드에 10~20분, S7 에서는 digest 가 매번 바뀌어 서명 검증
#      데모 자체가 성립하지 않는다.
#   ② S7 에서 cosign 이 02 의 KMS 키로 서명하고 그 서명을 ECR 에 저장한다 —
#      같은 스택이면 직접 참조로 끝난다(SSM 계약 불필요).
#   ③ 서명·스캔 대상이자 공급망 신뢰의 뿌리이므로 "보안 자산" 분류가 타당.
#   ※ 신규 스택(06-registry)을 만들지 않은 이유: ECR 이 마지막 신규 영속
#      리소스라 스택 신설의 선례 가치가 없다 (S6~S8·4C 는 기존 스택에 흡수).
# ============================================================

# ── 이미지 전용 KMS 키 (목적별 분리 원칙 유지) ────────────
# 기존 3키(logs/secrets/ebs)와 목적이 다르다 — 이미지는 로그도 시크릿도
# 볼륨도 아니다. 재사용하면 "어느 키가 무엇을 지키는가"가 흐려진다.
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
        # ECR 경유 사용만 허용 — secrets 키의 ViaService 패턴과 동일.
        # 직접 kms:Decrypt 호출로는 이미지 레이어를 복호화할 수 없다.
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

# ── ECR 리포지토리 ────────────────────────────────────────
resource "aws_ecr_repository" "app" {
  name = "${var.project_name}/app"

  # ★ 검증 축 ③ — 태그 불변성
  #   같은 태그로 재푸시가 거부된다. 근거:
  #   - 2026.3 Trivy 공급망 사건이 정확히 "기존 버전 태그를 악성 커밋으로
  #     force-push" 한 공격이었다. 다운스트림은 릴리스 메타데이터상 아무
  #     변화 없이 공격자 코드를 실행하게 됐다.
  #   - IMMUTABLE 은 그 공격 표면을 레지스트리 레벨에서 제거한다.
  #   - S7 의 전제이기도 하다: cosign 은 digest 에 서명하므로,
  #     "태그 → digest" 매핑이 불변이어야 서명 검증이 의미를 갖는다.
  image_tag_mutability = "IMMUTABLE"

  # ★ 검증 축 ① — 스캔은 "레지스트리 레벨 Enhanced" 가 담당한다
  #
  # image_scanning_configuration { scan_on_push } 블록을 의도적으로 두지 않는다:
  #   그 설정은 ECR **Basic Scanning**(OS 패키지만) 용이다.
  #   이 계정은 이미 Inspector 연동 **Enhanced Scanning** 을 레지스트리 레벨로
  #   쓰고 있으며(확인: aws ecr get-registry-scanning-configuration),
  #     scanType          = ENHANCED
  #     scanFrequency     = CONTINUOUS_SCAN
  #     repositoryFilters = "*" (WILDCARD)
  #   이므로 이 신규 리포지토리도 자동으로 커버된다.
  #
  # Enhanced 가 Basic 보다 나은 점:
  #   - OS 패키지 + **언어 패키지**(npm/pip/gem 등)까지 스캔
  #   - 푸시 1회가 아니라 **지속 재평가** — 저장 후 공시된 신규 CVE 도 탐지
  #
  # 이중화 구도(중복이 아니라 시점이 다름):
  #   Trivy      = 빌드타임 게이트 (푸시 전, shift-left)
  #   Inspector  = 레지스트리 지속 스캔 (푸시 후, 시간축)

  # 고객관리형 키 암호화 (D12·D25 와 동일 원칙)
  # ⚠ ECR 암호화 설정은 리포지토리 생성 후 변경 불가 — 처음부터 CMK 로 만든다.
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.images.arn
  }

  # ⚠ 사이클 규율: 데모 리포지토리이므로 이미지가 남아 있어도 destroy 가능.
  #   운영 리포지토리라면 false 여야 한다.
  force_delete = true

  tags = { Name = "${var.project_name}-app-ecr" }
}

# ── 라이프사이클 정책 (스토리지 비용 통제) ────────────────
# IMMUTABLE 이라 태그를 재사용할 수 없으므로 이미지가 단조 증가한다.
# 방치하면 스토리지 비용이 누적되므로 보존 개수를 제한한다.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the 10 most recent tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      },
    ]
  })
}

# ── SSM 발행 (05-k8s 가 이미지 URL 참조) ──────────────────
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
