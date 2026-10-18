# ============================================================
# 04-eks/identity-test-workload.tf — 앱 워크로드 Pod Identity 실증 (Stage 2)
# ============================================================
# BREAK → BUILD → VERIFY (순서가 곧 서사):
#   ① identity-denied (SA 역할 없음) 에서 S3 호출 → 자격증명 부재로 실패
#      = "기본 거부" + hop-limit=1(노드롤 IMDS 폴백 차단) 이중 실증
#      ⚠ 이게 "성공"하면 그게 더 큰 문제 — IMDS 경로가 열려 노드롤을
#        상속했다는 뜻 (hop-limit 설정을 의심할 것)
#   ② 전용 미니 버킷 + 그 버킷 "하나"로 스코프된 역할 + Pod Identity 연결
#   ③ identity-granted: 대상 버킷 ls 성공 / 전체 버킷 목록 → AccessDenied
#
# 배치 결정(확정): 리소스 전부 04(destroyable) — 클린 리빌드 때 함께 소멸.
#   영속 스택(02)에 데모 의존성을 만들지 않음.
# ============================================================

# ── 데모 대상: 전용 미니 S3 버킷 ──────────────────────────
resource "aws_s3_bucket" "identity_demo" {
  # 버킷명은 글로벌 유일 — 계정 ID suffix 로 결정론적 유일성 확보
  bucket        = "${var.project_name}-s2-identity-demo-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # 데모 객체가 남아 있어도 destroy 가능 (사이클 규율)
}

resource "aws_s3_bucket_public_access_block" "identity_demo" {
  bucket                  = aws_s3_bucket.identity_demo.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── [3단계 파트 4] 데모 버킷도 기본 보안 설정 (Checkov CKV_AWS_145 · CKV_AWS_21 · CKV2_AWS_61) ──
# 사이클마다 지워지는 버킷이라 비용·운영 부담이 없어 skip 대신 고친다.
# 암호화: AWS 관리형 키(aws/s3). 파드는 S3 를 거쳐서만 읽으므로 역할에 KMS 권한을 더할 필요가 없다
#   (aws/s3 키 정책이 "이 계정 주체 + S3 경유" 사용을 허용) — S2 실증 내용은 그대로다.
resource "aws_s3_bucket_server_side_encryption_configuration" "identity_demo" {
  bucket = aws_s3_bucket.identity_demo.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "identity_demo" {
  bucket = aws_s3_bucket.identity_demo.id

  versioning_configuration {
    status = "Enabled"
  }
}

# 버전이 쌓이지 않게 — 이전 버전·미완료 업로드는 1일 뒤 정리 (force_destroy 와 함께 destroy 도 깨끗하다)
resource "aws_s3_bucket_lifecycle_configuration" "identity_demo" {
  bucket = aws_s3_bucket.identity_demo.id

  rule {
    id     = "expire-noncurrent-and-abort-mpu"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.identity_demo]
}

resource "aws_s3_object" "identity_demo_hello" {
  bucket  = aws_s3_bucket.identity_demo.id
  key     = "hello-from-stage2.txt"
  content = "pod identity works - scoped to this bucket only\n"
}

# ── 앱 역할: 버킷 1개 읽기로 핀포인트 (LBC 최소권한과 같은 철학, D13) ──
data "aws_iam_policy_document" "identity_demo_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole", "sts:TagSession"]
  }
}

data "aws_iam_policy_document" "identity_demo_read" {
  statement {
    sid       = "ListTargetBucketOnly"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.identity_demo.arn]
  }
  statement {
    sid       = "GetObjectsInTargetBucketOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.identity_demo.arn}/*"]
  }
  # 의도적 부재: s3:ListAllMyBuckets
  #   → "aws s3 ls"(전체 목록)는 AccessDenied = 스코프 증명의 세 번째 축
}

resource "aws_iam_role" "identity_demo" {
  name               = "${var.cluster_name}-s2-identity-demo"
  assume_role_policy = data.aws_iam_policy_document.identity_demo_trust.json
}

resource "aws_iam_role_policy" "identity_demo" {
  name   = "s3-read-single-bucket"
  role   = aws_iam_role.identity_demo.id
  policy = data.aws_iam_policy_document.identity_demo_read.json
}

# 앱 워크로드용 연결 — LBC(인프라 컴포넌트, lb-controller.tf)와 목적 구분
resource "aws_eks_pod_identity_association" "identity_demo" {
  cluster_name    = module.eks.cluster_name
  namespace       = "default"
  service_account = "s2-identity-demo"
  role_arn        = aws_iam_role.identity_demo.arn
}
