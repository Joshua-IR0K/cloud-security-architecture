# ============================================================
# 04-eks/secrets-demo-iam.tf — Stage 4 시크릿 (AWS 평면)
# ============================================================
# 설계 전제 3개 (Stage 4 진입 전 확정):
#   ① 값 관리: Terraform 이 생성하되 평문이 코드·state·plan 어디에도 남지 않음
#      (ephemeral + write-only 인자) — 생성자인 나조차 값을 모름
#   ② 암호화: 02-security 의 고객관리형 키(aws_kms_key.secrets) 사용
#      → D12(노드 EBS = CMK)와 동일 원칙. 기본키를 쓰면 프로젝트 내에서
#        암호화 통제 원칙이 갈라짐
#   ③ 검증: S2·S3 와 같은 3축 + D9(ESO 기각 근거) 증명 — 05-k8s/outputs.tf
#
# 접근에 필요한 "세 관문" (이 파일이 ①②를, 02 키 정책이 ③을 담당):
#   ① 역할의 secretsmanager:GetSecretValue  — 해당 시크릿 ARN 으로 스코프
#   ② 역할의 kms:Decrypt                    — 해당 키 ARN 으로 스코프
#   ③ 키 정책의 ViaService 조건             — Secrets Manager 경유만 허용,
#      직접 kms:Decrypt 호출은 권한이 있어도 거부 (02-security/kms.tf)
#   → ③은 IAM 정책만 보면 안 보이는 경계. 실무에서 자주 빠뜨리는 하드닝.
# ============================================================

# ── ① 값 생성: ephemeral (state·plan 미기록) ──────────────
# ephemeral 블록의 결과는 write-only 인자에만 전달 가능하다.
# 일반 인자에 쓰면 "Ephemeral values are not valid" 에러 — 그 자체가 안전장치.
ephemeral "random_password" "demo" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# ── 시크릿 컨테이너 ────────────────────────────────────────
resource "aws_secretsmanager_secret" "demo" {
  #checkov:skip=CKV2_AWS_57:S4 데모 시크릿 — 사이클마다 생성·즉시 삭제(recovery_window 0)되어 교체 주기가 의미 없음. 자동 교체는 교체용 Lambda 가 필요해 범위 밖 (운영 시크릿이면 적용)
  name        = "${var.project_name}/demo/app-credentials"
  description = "Stage 4 demo credentials — mounted via Secrets Store CSI (never a K8s Secret)"

  # ② 고객관리형 키로 암호화 (02-security 소유)
  kms_key_id = local.secrets_kms_key_arn

  # ⚠ 사이클 규율과의 충돌 해소 (충돌 검사에서 발견):
  #   기본값은 30일 복구 대기라, destroy 후 같은 이름으로 재생성하면
  #   "scheduled for deletion" 상태와 충돌해 apply 가 실패한다.
  #   세션마다 destroy/apply 를 반복하는 이 프로젝트에선 0(즉시 삭제)이 필수.
  #   → 데모 시크릿이라 복구 가치가 없고, 운영 시크릿이라면 7~30을 쓴다.
  recovery_window_in_days = 0

  tags = { Name = "${var.project_name}-s4-demo-secret" }
}

# ── 값 주입: write-only 인자 ───────────────────────────────
# secret_string_wo 는 state/plan 에 기록되지 않는다.
# 값이 바뀌었는지 Terraform 이 알 수 없으므로 _wo_version 으로 변경을 신호한다.
# ⚠ secret_string_wo_version 에는 ephemeral 값을 넣을 수 없다(프로바이더 제약).
#   → var.demo_secret_version 은 일반 변수여야 하며, state 에 저장돼야
#     변경 감지가 성립한다.
resource "aws_secretsmanager_secret_version" "demo" {
  secret_id = aws_secretsmanager_secret.demo.id

  secret_string_wo = jsonencode({
    username = "app-service-account"
    password = ephemeral.random_password.demo.result
  })
  secret_string_wo_version = var.demo_secret_version
}

# ── 앱 역할: 세 관문 중 ①② ───────────────────────────────
data "aws_iam_policy_document" "secrets_demo_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole", "sts:TagSession"]
  }
}

data "aws_iam_policy_document" "secrets_demo_read" {
  statement {
    sid    = "ReadThisSecretOnly"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [aws_secretsmanager_secret.demo.arn]
  }

  statement {
    # ★ 이 statement 가 CMK 선택(②)의 실증이다.
    #   기본키(aws/secretsmanager)를 썼다면 이 권한이 필요 없어
    #   "데이터 권한과 키 권한은 별개의 관문"이라는 사실이 코드에 안 드러난다.
    sid       = "DecryptWithProjectSecretsKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [local.secrets_kms_key_arn]
  }

  # 의도적 부재: secretsmanager:ListSecrets, 다른 시크릿 ARN
  #   → 3축 검증 ③(SCOPE)에서 AccessDenied 로 증명
}

resource "aws_iam_role" "secrets_demo" {
  name               = "${var.cluster_name}-s4-secrets-demo"
  assume_role_policy = data.aws_iam_policy_document.secrets_demo_trust.json
}

resource "aws_iam_role_policy" "secrets_demo" {
  name   = "read-single-secret"
  role   = aws_iam_role.secrets_demo.id
  policy = data.aws_iam_policy_document.secrets_demo_read.json
}

# ── Pod Identity 연결 (SA 는 05-k8s 가 생성) ───────────────
# association 은 SA "이름"만 참조하므로 SA 실체 없이 생성 가능하고,
# 04 가 먼저 apply 되므로 파드보다 항상 먼저 존재한다
# → 트러블슈팅 #7(admission-time 주입 레이스)이 스택 분리로 구조적 해소.
resource "aws_eks_pod_identity_association" "secrets_demo" {
  cluster_name    = module.eks.cluster_name
  namespace       = "default"
  service_account = "s4-secrets-demo"
  role_arn        = aws_iam_role.secrets_demo.arn
}
