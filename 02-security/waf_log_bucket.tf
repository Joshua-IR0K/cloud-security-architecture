# ============================================================
# 02-security/waf_log_bucket.tf — WAF 로그 저장용 S3 버킷
# ============================================================
# WAF WebACL 자체는 03-workload에 배치 (고비용, 임시)
# 로그 버킷은 영속 보안 스택에 보관 (워크로드 destroy 후에도 로그 유지)
#
# ⚠ KMS 암호화 미적용 (의도적 결정):
#   KMS 키는 리전별 리소스. logs CMK는 ap-northeast-2에 있는데
#   이 버킷은 us-east-1(CloudFront WAF 제약)에 있어 키를 공유 불가.
#   단일 버킷을 위해 us-east-1 전용 CMK를 따로 관리하는 것은
#   과한 운영 부담이라 판단 → SSE-S3(AES256) 유지.
#   프로덕션에서 규제 요구가 있으면 us-east-1 전용 CMK 추가 가능.
# ============================================================

resource "aws_s3_bucket" "waf_logs" {
  provider = aws.us_east_1

  bucket        = "aws-waf-logs-${var.project_name}-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags = { Name = "${var.project_name}-waf-logs" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "waf_logs" {
  provider = aws.us_east_1
  bucket   = aws_s3_bucket.waf_logs.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "waf_logs" {
  provider = aws.us_east_1
  bucket   = aws_s3_bucket.waf_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
