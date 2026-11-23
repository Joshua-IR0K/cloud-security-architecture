# Pod Identity 데모: 버킷 하나로 묶은 역할을 identity-granted에만 연결한다. 리소스는 전부 04(세션) 스택을 지울 때 같이 사라진다.
# identity-denied가 S3 호출에 성공하면 IMDS 경로가 열려서 노드 역할을 물려받았다는 뜻이다. hop limit 설정부터 의심할 것.

resource "aws_s3_bucket" "identity_demo" {
  # 버킷 이름은 전역에서 유일해야 해서 계정 ID를 뒤에 붙인다.
  bucket        = "${var.project_name}-s2-identity-demo-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # 데모 객체가 남아 있어도 destroy할 수 있게(사이클마다 깔끔하게)
}

resource "aws_s3_bucket_public_access_block" "identity_demo" {
  bucket                  = aws_s3_bucket.identity_demo.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 데모 버킷도 기본 보안 설정을 건다(CKV_AWS_145·21, CKV2_AWS_61). 암호화는 aws/s3. 파드는 S3를 거쳐서만 읽어서 역할에 KMS 권한이 필요 없다.
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

# 버전이 쌓이지 않게 이전 버전과 미완료 업로드는 1일 뒤 정리한다(force_destroy와 같이 destroy도 깔끔하다).
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

  # 암호화를 업로드 요청에 직접 적는다. 버킷 기본 암호화와 같은 apply에서 동시에 만들어져서 순서에 기댈 수 없다.
  server_side_encryption = "aws:kms"
  bucket_key_enabled     = true
}

# 앱 역할: 버킷 1개 읽기만
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
  # 일부러 안 준 권한: s3:ListAllMyBuckets. 전체 목록 조회는 AccessDenied가 난다.
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

# 앱 워크로드용 연결. LBC(인프라 컴포넌트, lb-controller.tf)와는 목적이 다르다.
resource "aws_eks_pod_identity_association" "identity_demo" {
  cluster_name    = module.eks.cluster_name
  namespace       = "default"
  service_account = "s2-identity-demo"
  role_arn        = aws_iam_role.identity_demo.arn
}
