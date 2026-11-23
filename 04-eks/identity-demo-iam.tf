# Pod Identity 데모: 전용 버킷 하나로 한정한 역할을 identity-granted 에만 연결한다. 리소스는 모두 04(세션) 스택 지울 때 함께 사라진다.
# identity-denied 가 S3 호출에 성공하면 IMDS 경로가 열려 노드 역할을 상속했다는 뜻 — hop limit 설정을 의심할 것.

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

# 데모 버킷도 기본 보안 설정을 적용한다 (CKV_AWS_145·21, CKV2_AWS_61). 암호화는 aws/s3 — 파드는 S3 경유로만 읽어 역할에 KMS 권한이 필요 없음
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

  # 암호화를 업로드 요청에 직접 지정한다 — 버킷 기본 암호화와 같은 apply 에서 동시에 만들어져 순서에 기댈 수 없음
  server_side_encryption = "aws:kms"
  bucket_key_enabled     = true
}

# 앱 역할: 버킷 1개 읽기로 한정
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
  # 의도적 부재: s3:ListAllMyBuckets — 전체 목록 조회는 AccessDenied
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
