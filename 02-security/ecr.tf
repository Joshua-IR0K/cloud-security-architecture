# ============================================================
# 02-security/ecr.tf — 컨테이너 이미지 레지스트리 (Stage 5)
# ============================================================
# 왜 02(영속 보안 스택)인가 (O3 결정):
#   ① 이미지는 클러스터 파괴에도 생존해야 한다 — 04/05 에 두면 사이클마다
#      소실돼 재빌드에 10~20분, S7 에서는 digest 가 매번 바뀌어 서명 검증
#      데모 자체가 성립하지 않는다.
#   ② S7 의 Cosign 서명용 **별도 SIGN_VERIFY KMS 키**도 02-security 에 둔다.
#      ECR 암호화용 images 키(ENCRYPT_DECRYPT)와 서명 키는 목적/KeySpec 을 분리한다.
#      같은 보안 스택 안에서 관리하므로 생명주기와 소유권이 명확하다.
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
        # ECR 경유용 grant/키 사용 조건을 명시한다.
        # 실제 image push/pull 주체에게 KMS data-plane 권한을 직접 주는 구조가 아니라,
        # ECR 서비스가 repository 생성 시 확보한 KMS grant 를 통해 암복호화를 수행한다.
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
  #   - S7 의 digest 서명과 상호보완적이다. Cosign 검증 자체는 digest 기반이라
  #     태그 불변성이 필수조건은 아니지만, 태그가 다른 digest 로 이동하는 경로를
  #     차단해 artifact identity / provenance 추적성을 강화한다.
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
# Stage 5~7 포트폴리오 규모에서는 tagged artifact 수가 크지 않다.
# 따라서 tagged image(s5-*/s6-*/baseline-* 및 S7 서명 관련 태그)는 자동 만료하지 않고,
# 빌드/태그 정리 과정에서 생긴 **untagged image만 1일 후 자동 삭제**한다.
#
# 왜 이렇게 단순화하는가:
#   ① D43: baseline 은 destroy→apply 재구축의 기준선이므로 자동 수명주기에
#      의해 사라지면 안 된다.
#   ② S6: s6-<full sha> 는 CI evidence이며 동일 커밋 rerun 시 재사용한다.
#   ③ S7: digest 서명/검증으로 확장할 때 동일 artifact 를 계속 참조해야 한다.
#   ④ 개인 포트폴리오에서 tagged artifact 자동 만료 규칙을 복잡하게 만드는 것은
#      비용 절감 효과보다 lifecycle/증거 훼손 위험이 더 크다.
#
# 운영 규모로 확장한다면 retention 정책을 별도 설계해야 하지만, 현재 스테이지의
# 목표는 "안전하게 재현 가능한 공급망 경로"의 검증이다. tagged 정리는 스테이지
# 종료/증거 보존 확인 후 수동으로 수행한다.
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
