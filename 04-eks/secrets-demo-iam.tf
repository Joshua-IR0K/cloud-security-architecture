# Secrets Store CSI 데모용 시크릿이다. 값은 ephemeral로 만들어서 write-only 인자로만 넘기기 때문에 코드·state·plan 어디에도 평문이 남지 않는다.
# 이 값을 읽으려면 세 관문을 다 통과해야 한다: 역할 쪽의 GetSecretValue(이 시크릿)와 kms:Decrypt(이 키), 그리고 키 정책의 ViaService(Secrets Manager를 거칠 때만 허용, 02 kms.tf).

# ephemeral 값은 write-only 인자에만 넣을 수 있다 — 일반 인자에 잘못 쓰면 바로 에러가 터지니 그 자체가 안전장치 역할을 한다.
ephemeral "random_password" "demo" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "demo" {
  #checkov:skip=CKV2_AWS_57:S4 데모 시크릿 — 사이클마다 생성·즉시 삭제(recovery_window 0)되어 교체 주기가 의미 없음. 자동 교체는 교체용 Lambda 가 필요해 범위 밖 (운영 시크릿이면 적용)
  name        = "${var.project_name}/demo/app-credentials"
  description = "Stage 4 demo credentials — mounted via Secrets Store CSI (never a K8s Secret)"

  kms_key_id = local.secrets_kms_key_arn

  # 0 = 즉시 삭제. 세션마다 같은 이름으로 다시 만들어서 복구 대기(기본 30일)가 있으면 apply 가 실패한다. 운영 시크릿이면 7~30일
  recovery_window_in_days = 0

  tags = { Name = "${var.project_name}-s4-demo-secret" }
}

# provider 제약 때문에 _wo_version에는 ephemeral 값을 못 넣는다 — 그래서 var.demo_secret_version은 일반 변수로 둬야 한다.
# _wo_version에는 ephemeral 값을 넣을 수 없으므로(provider 제약), var.demo_secret_version은 꼭 일반 변수로 선언해야 한다.
resource "aws_secretsmanager_secret_version" "demo" {
  secret_id = aws_secretsmanager_secret.demo.id

  secret_string_wo = jsonencode({
    username = "app-service-account"
    password = ephemeral.random_password.demo.result
  })
  secret_string_wo_version = var.demo_secret_version
}

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
    # CMK를 쓰다 보니 데이터 접근 권한이랑 키 복호화 권한, 이 두 관문을 따로따로 통과해야 한다.
    sid       = "DecryptWithProjectSecretsKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [local.secrets_kms_key_arn]
  }

  # 의도적 부재: ListSecrets, 다른 시크릿 ARN — 범위 밖 접근은 AccessDenied
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

# Pod Identity 연결 (SA 는 05 가 만든다). SA 이름만 참조해 04 에서 먼저 만들 수 있어 파드보다 항상 먼저 존재함
resource "aws_eks_pod_identity_association" "secrets_demo" {
  cluster_name    = module.eks.cluster_name
  namespace       = "default"
  service_account = "s4-secrets-demo"
  role_arn        = aws_iam_role.secrets_demo.arn
}
