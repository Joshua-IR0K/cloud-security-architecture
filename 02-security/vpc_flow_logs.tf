# ============================================================
# 02-security/vpc_flow_logs.tf — VPC Flow Logs (S3 직접 저장)
# ============================================================
# 01-network 스택의 VPC ID를 SSM에서 읽어서 Flow Logs 설정
# ============================================================

locals {
  flow_log_format = join(" ", [
    "$${version}", "$${account-id}", "$${interface-id}",
    "$${srcaddr}", "$${dstaddr}", "$${srcport}", "$${dstport}",
    "$${protocol}", "$${packets}", "$${bytes}",
    "$${start}", "$${end}", "$${action}", "$${log-status}",
    "$${vpc-id}", "$${subnet-id}", "$${instance-id}", "$${type}",
    "$${tcp-flags}", "$${pkt-srcaddr}", "$${pkt-dstaddr}",
    "$${region}", "$${az-id}", "$${flow-direction}",
    "$${pkt-src-aws-service}", "$${pkt-dst-aws-service}", "$${traffic-path}",
  ])
}

resource "aws_flow_log" "vpc_s3" {
  vpc_id               = local.vpc_id # ← SSM에서 읽은 VPC ID
  traffic_type         = "ALL"
  log_destination_type = "s3"
  log_destination      = aws_s3_bucket.flow_logs.arn
  log_format           = local.flow_log_format
  max_aggregation_interval = 600

  destination_options {
    file_format                = "parquet"
    hive_compatible_partitions = true
    per_hour_partition         = true
  }

  tags = {
    Name = "${var.project_name}-vpc-flow-log-s3"
  }
}

resource "aws_s3_bucket" "flow_logs" {
  bucket        = "${var.project_name}-flow-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags = { Name = "${var.project_name}-flow-logs" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.logs.arn # Phase 4A.5: 전용 CMK
    }
    bucket_key_enabled = true # S3 Bucket Key로 KMS 호출 비용 절감
  }
}

resource "aws_s3_bucket_public_access_block" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
