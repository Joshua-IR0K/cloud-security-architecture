# 로그 조사용 Athena. 파티션 프로젝션이라 크롤러 없이 S3 경로 규칙으로 파티션을 계산한다 (상시 비용 0).
# 워크그룹 설정(결과 암호화, 쿼리당 스캔 1GB)은 사용자가 끌 수 없다. 원본 로그 버킷은 이름 규칙으로 읽기만 한다.
# 버킷을 추가하면 00 의 plan 역할 s3:ListBucket 목록에도 넣어야 한다 — 빠지면 CI plan 이 버킷을 없다고 보고 재생성을 계획한다.

data "aws_regions" "athena_trail" {} # 계정에서 활성화된 리전 = 멀티 리전 trail 이 로그를 남기는 범위

locals {
  athena_account   = data.aws_caller_identity.current.account_id
  athena_region    = data.aws_region.current.name
  athena_workgroup = "${var.project_name}-security"

  # 원본 로그 버킷 (02) — 이름 규칙
  athena_cloudtrail_bucket = "${var.project_name}-cloudtrail-${local.athena_account}"
  athena_flow_logs_bucket  = "${var.project_name}-flow-logs-${local.athena_account}"
  athena_waf_logs_bucket   = "aws-waf-logs-${var.project_name}-${local.athena_account}"

  # 03 이 만드는 CloudFront 범위 Web ACL 이름 — WAF 로그 경로에 들어간다
  athena_waf_acl_name = "${var.project_name}-waf-acl"
}

resource "aws_s3_bucket" "athena_results" {
  #checkov:skip=CKV_AWS_18:쿼리 결과 임시 버킷(7일 만료) — 접근 기록은 CloudTrail 의 Athena API 이벤트로 충분
  #checkov:skip=CKV_AWS_144:7일 후 사라지는 재생성 가능한 산출물 — 리전 간 복제 불필요
  #checkov:skip=CKV2_AWS_62:결과 객체 생성 알림을 소비하는 주체 없음
  #checkov:skip=CKV_AWS_21:7일 만료 임시 산출물 — 버전 관리는 만료 정책과 충돌하고 보존 가치가 없음
  bucket = "${var.project_name}-athena-results-${local.athena_account}"

  tags = {
    Name    = "${var.project_name}-athena-results"
    Purpose = "athena-query-results"
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.logs.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    id     = "expire-query-results"
    status = "Enabled"
    filter {}
    expiration {
      days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_policy" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.athena_results.arn,
        "${aws_s3_bucket.athena_results.arn}/*",
      ]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.athena_results]
}

resource "aws_athena_workgroup" "security" {
  name        = local.athena_workgroup
  description = "Security log investigation - encrypted results, 1GB scan cap enforced"

  configuration {
    enforce_workgroup_configuration    = true # 사용자가 아래 설정을 끌 수 없다
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = 1073741824 # 1GB — 넘으면 쿼리 취소 (비용 상한)

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/results/"
      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = aws_kms_key.logs.arn
      }
    }
  }

  tags = {
    Name = local.athena_workgroup
  }
}

resource "aws_glue_catalog_database" "security_logs" {
  name        = "security_logs"
  description = "Security log tables (partition projection, no crawler)"
}

# ① CloudTrail — 멀티 리전 trail, 접두어 없음
#   경로: AWSLogs/<계정>/CloudTrail/<리전>/<yyyy>/<MM>/<dd>/   (CloudTrail-Digest/ 는 제외)
#   컬럼은 AWS 문서의 CloudTrail 테이블 정의를 따른다 (requestparameters 등은 JSON 문자열)
locals {
  athena_cloudtrail_columns = [
    { name = "eventversion", type = "string" },
    { name = "useridentity", type = "struct<type:string,principalid:string,arn:string,accountid:string,invokedby:string,accesskeyid:string,username:string,onbehalfof:struct<userid:string,identitystorearn:string>,sessioncontext:struct<attributes:struct<mfaauthenticated:string,creationdate:string>,sessionissuer:struct<type:string,principalid:string,arn:string,accountid:string,username:string>,sourceidentity:string,ec2roledelivery:string,webidfederationdata:struct<federatedprovider:string,attributes:map<string,string>>>>" },
    { name = "eventtime", type = "string" },
    { name = "eventsource", type = "string" },
    { name = "eventname", type = "string" },
    { name = "awsregion", type = "string" },
    { name = "sourceipaddress", type = "string" },
    { name = "useragent", type = "string" },
    { name = "errorcode", type = "string" },
    { name = "errormessage", type = "string" },
    { name = "requestparameters", type = "string" },
    { name = "responseelements", type = "string" },
    { name = "additionaleventdata", type = "string" },
    { name = "requestid", type = "string" },
    { name = "eventid", type = "string" },
    { name = "readonly", type = "string" },
    { name = "resources", type = "array<struct<arn:string,accountid:string,type:string>>" },
    { name = "eventtype", type = "string" },
    { name = "apiversion", type = "string" },
    { name = "recipientaccountid", type = "string" },
    { name = "serviceeventdetails", type = "string" },
    { name = "sharedeventid", type = "string" },
    { name = "vpcendpointid", type = "string" },
    { name = "eventcategory", type = "string" },
    { name = "tlsdetails", type = "struct<tlsversion:string,ciphersuite:string,clientprovidedhostheader:string>" },
  ]
}

resource "aws_glue_catalog_table" "cloudtrail" {
  name          = "cloudtrail"
  database_name = aws_glue_catalog_database.security_logs.name
  table_type    = "EXTERNAL_TABLE"
  description   = "CloudTrail management events (multi-region trail)"

  parameters = {
    "EXTERNAL"                     = "TRUE"
    "projection.enabled"           = "true"
    "projection.region.type"       = "enum"
    "projection.region.values"     = join(",", sort(data.aws_regions.athena_trail.names))
    "projection.day.type"          = "date"
    "projection.day.format"        = "yyyy/MM/dd"
    "projection.day.range"         = "2026/01/01,NOW"
    "projection.day.interval"      = "1"
    "projection.day.interval.unit" = "DAYS"
    "storage.location.template"    = "s3://${local.athena_cloudtrail_bucket}/AWSLogs/${local.athena_account}/CloudTrail/$${region}/$${day}"
  }

  partition_keys {
    name = "region"
    type = "string"
  }
  partition_keys {
    name = "day"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${local.athena_cloudtrail_bucket}/AWSLogs/${local.athena_account}/CloudTrail/"
    input_format  = "com.amazon.emr.cloudtrail.CloudTrailInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hive.hcatalog.data.JsonSerDe"
    }

    dynamic "columns" {
      for_each = local.athena_cloudtrail_columns
      content {
        name = columns.value.name
        type = columns.value.type
      }
    }
  }
}

# ② VPC Flow Logs — Parquet, Hive 호환 경로, 시간 단위 파티션
#   경로: AWSLogs/aws-account-id=<계정>/aws-service=vpcflowlogs/aws-region=<리전>/year=/month=/day=/hour=/
#   컬럼 타입은 AWS 문서의 Parquet 예시와 같다 (Parquet 은 타입이 어긋나면 읽기 실패).
#   로그 형식에 없는 필드는 NULL 로 읽힌다 (Parquet 은 이름으로 매칭).
locals {
  athena_flow_log_columns = [
    { name = "version", type = "int" },
    { name = "account_id", type = "string" },
    { name = "interface_id", type = "string" },
    { name = "srcaddr", type = "string" },
    { name = "dstaddr", type = "string" },
    { name = "srcport", type = "int" },
    { name = "dstport", type = "int" },
    { name = "protocol", type = "bigint" },
    { name = "packets", type = "bigint" },
    { name = "bytes", type = "bigint" },
    { name = "start", type = "bigint" },
    { name = "end", type = "bigint" },
    { name = "action", type = "string" },
    { name = "log_status", type = "string" },
    { name = "vpc_id", type = "string" },
    { name = "subnet_id", type = "string" },
    { name = "instance_id", type = "string" },
    { name = "tcp_flags", type = "int" },
    { name = "type", type = "string" },
    { name = "pkt_srcaddr", type = "string" },
    { name = "pkt_dstaddr", type = "string" },
    { name = "az_id", type = "string" },
    { name = "sublocation_type", type = "string" },
    { name = "sublocation_id", type = "string" },
    { name = "pkt_src_aws_service", type = "string" },
    { name = "pkt_dst_aws_service", type = "string" },
    { name = "flow_direction", type = "string" },
    { name = "traffic_path", type = "int" },
  ]
}

resource "aws_glue_catalog_table" "vpc_flow_logs" {
  name          = "vpc_flow_logs"
  database_name = aws_glue_catalog_database.security_logs.name
  table_type    = "EXTERNAL_TABLE"
  description   = "VPC Flow Logs (Parquet, hourly Hive-compatible partitions)"

  # 정수 프로젝션 + 2자리 0 채움 — AWS 문서의 Parquet 예시(hour 00~23)와 같은 방식
  parameters = {
    "EXTERNAL"                  = "TRUE"
    "projection.enabled"        = "true"
    "projection.year.type"      = "integer"
    "projection.year.range"     = "2026,2030"
    "projection.month.type"     = "integer"
    "projection.month.range"    = "01,12"
    "projection.month.digits"   = "2"
    "projection.day.type"       = "integer"
    "projection.day.range"      = "01,31"
    "projection.day.digits"     = "2"
    "projection.hour.type"      = "integer"
    "projection.hour.range"     = "00,23"
    "projection.hour.digits"    = "2"
    "storage.location.template" = "s3://${local.athena_flow_logs_bucket}/AWSLogs/aws-account-id=${local.athena_account}/aws-service=vpcflowlogs/aws-region=${local.athena_region}/year=$${year}/month=$${month}/day=$${day}/hour=$${hour}"
  }

  partition_keys {
    name = "year"
    type = "string"
  }
  partition_keys {
    name = "month"
    type = "string"
  }
  partition_keys {
    name = "day"
    type = "string"
  }
  partition_keys {
    name = "hour"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${local.athena_flow_logs_bucket}/AWSLogs/aws-account-id=${local.athena_account}/aws-service=vpcflowlogs/aws-region=${local.athena_region}/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters = {
        "serialization.format" = "1"
      }
    }

    dynamic "columns" {
      for_each = local.athena_flow_log_columns
      content {
        name = columns.value.name
        type = columns.value.type
      }
    }
  }
}

# ③ WAF — CloudFront 범위 Web ACL, JSON(gzip), 분 단위 경로
#   경로: AWSLogs/<계정>/WAFLogs/cloudfront/<web-acl>/<yyyy>/<MM>/<dd>/<HH>/<mm>/
#   조사에 쓰는 필드만 정의한다 (JSON SerDe 는 정의하지 않은 필드를 무시한다)
locals {
  athena_waf_columns = [
    { name = "timestamp", type = "bigint" },
    { name = "formatversion", type = "int" },
    { name = "webaclid", type = "string" },
    { name = "terminatingruleid", type = "string" },
    { name = "terminatingruletype", type = "string" },
    { name = "action", type = "string" },
    { name = "httpsourcename", type = "string" },
    { name = "httpsourceid", type = "string" },
    { name = "labels", type = "array<struct<name:string>>" },
    { name = "httprequest", type = "struct<clientip:string,country:string,headers:array<struct<name:string,value:string>>,uri:string,args:string,httpversion:string,httpmethod:string,requestid:string,scheme:string,host:string>" },
    { name = "responsecodesent", type = "string" },
    { name = "ja3fingerprint", type = "string" },
    { name = "ja4fingerprint", type = "string" },
  ]
}

resource "aws_glue_catalog_table" "waf_logs" {
  name          = "waf_logs"
  database_name = aws_glue_catalog_database.security_logs.name
  table_type    = "EXTERNAL_TABLE"
  description   = "WAF logs (CloudFront web ACL, minute partitions)"

  parameters = {
    "EXTERNAL"                          = "TRUE"
    "projection.enabled"                = "true"
    "projection.log_time.type"          = "date"
    "projection.log_time.format"        = "yyyy/MM/dd/HH/mm"
    "projection.log_time.range"         = "2026/01/01/00/00,NOW"
    "projection.log_time.interval"      = "1"
    "projection.log_time.interval.unit" = "MINUTES"
    "storage.location.template"         = "s3://${local.athena_waf_logs_bucket}/AWSLogs/${local.athena_account}/WAFLogs/cloudfront/${local.athena_waf_acl_name}/$${log_time}"
  }

  partition_keys {
    name = "log_time"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${local.athena_waf_logs_bucket}/AWSLogs/${local.athena_account}/WAFLogs/cloudfront/${local.athena_waf_acl_name}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
    }

    dynamic "columns" {
      for_each = local.athena_waf_columns
      content {
        name = columns.value.name
        type = columns.value.type
      }
    }
  }
}

# 저장 쿼리 5개. 콘솔에서 이 워크그룹을 고른 뒤 Saved queries 에서 실행하고, ? 자리 값은 실행할 때 넣는다 (문자열은 작은따옴표, UTC).
# 테이블은 security_logs.<table> 처럼 DB 이름까지 쓴다 — 콘솔은 왼쪽에서 고른 DB(기본 default)로 실행해 TABLE_NOT_FOUND 가 난다.
locals {
  athena_named_queries = {
    "01-waf-requests-by-ip" = {
      description = "WAF: IP별 판정 - 차단(BLOCK)과 Count 룰 라벨. ? = 시작, 끝('yyyy/MM/dd/HH/mm'), IP 패턴('%' = 전체)"
      query       = <<-SQL
        -- ① WAF: 이 IP 는 무엇을 요청했고 무엇에 막혔나
        --   Count 로 둔 룰은 요청을 통과(ALLOW)시키지만 labels 에 흔적을 남긴다.
        --   → "볼 수단이 없으면 Count 는 없는 룰"에 대한 답: 여기서 Count 매칭이 보인다.
        SELECT
          httprequest.clientip                                AS client_ip,
          httprequest.country                                 AS country,
          action,
          terminatingruleid                                   AS terminating_rule,
          array_join(transform(labels, l -> l.name), ', ')    AS labels,
          httprequest.httpmethod                              AS method,
          httprequest.uri                                     AS uri,
          count(*)                                            AS requests,
          min(from_unixtime("timestamp" / 1000))              AS first_seen,
          max(from_unixtime("timestamp" / 1000))              AS last_seen
        FROM security_logs.waf_logs
        WHERE log_time BETWEEN ? AND ?
          AND httprequest.clientip LIKE ?
        GROUP BY 1, 2, 3, 4, 5, 6, 7
        ORDER BY (action = 'BLOCK') DESC, last_seen DESC
        LIMIT 200
      SQL
    }

    "02-flowlogs-private-egress" = {
      description = "Flow Logs: 프라이빗 서브넷(노드·파드) -> VPC 밖 통신 상위. ? = year, month, day (예: '2026', '10', '06')"
      query       = <<-SQL
        -- ② VPC Flow Logs: 클러스터 안에서 누가 밖으로 얼마나 나갔나
        --   파드 IP 는 VPC CNI 로 노드와 같은 프라이빗 서브넷(10.0.11.0/24 · 10.0.12.0/24)에서 받는다.
        --   NAT 이전의 출발지(파드·노드 IP)와 최종 목적지가 노드 ENI 기록에 남는다.
        --   instance_id = 그 트래픽이 지나간 노드, pkt_dst_aws_service = 목적지가 AWS 서비스면 이름
        --   (두 필드가 비어 있으면 플로우 로그가 기본 형식이라는 뜻 — 쿼리 오류 아님)
        SELECT
          srcaddr,
          instance_id,
          dstaddr,
          dstport,
          protocol,
          pkt_dst_aws_service,
          action,
          sum(bytes)                    AS bytes,
          sum(packets)                  AS packets,
          count(*)                      AS flows,
          min(from_unixtime(start))     AS first_seen
        FROM security_logs.vpc_flow_logs
        WHERE year = ? AND month = ? AND day = ?
          AND (srcaddr LIKE '10.0.11.%' OR srcaddr LIKE '10.0.12.%')
          AND dstaddr NOT LIKE '10.0.%'
        GROUP BY 1, 2, 3, 4, 5, 6, 7
        ORDER BY bytes DESC
        LIMIT 50
      SQL
    }

    "03-cloudtrail-role-activity" = {
      description = "CloudTrail: 역할별 API 요약 - 거부 먼저. ? = 시작일, 끝일('yyyy/MM/dd'), 역할 이름 패턴(예: '%github-actions%')"
      query       = <<-SQL
        -- ③ CloudTrail: 우리 역할(CI plan·build·deploy, 워크로드 역할)이 무엇을 했고 무엇이 거부됐나
        --   거부(errorcode 있음)를 맨 위로 올린다 — 권한 경계가 실제로 작동한 기록이다.
        --   sessions = role-session-name. CI 는 잡마다 이름이 다르다
        --     gha-plan-guard = 가드의 거부 탐침 / gha-plan-01-network · gha-plan-02-security = plan 잡
        --   S3 객체·DynamoDB 항목 호출은 데이터 이벤트라 trail 이 기록하지 않으면 보이지 않는다.
        SELECT
          useridentity.sessioncontext.sessionissuer.username                     AS role_name,
          eventsource,
          eventname,
          errorcode,
          count(*)                                                               AS calls,
          min(eventtime)                                                         AS first_seen,
          max(eventtime)                                                         AS last_seen,
          array_join(slice(array_agg(DISTINCT regexp_extract(useridentity.arn, '[^/]+$')), 1, 5), ', ') AS sessions
        FROM security_logs.cloudtrail
        WHERE region IN ('ap-northeast-2', 'us-east-1')   -- 서울 + 글로벌 서비스(IAM · CloudFront · CLOUDFRONT 범위 WAF)
          AND day BETWEEN ? AND ?
          AND useridentity.type = 'AssumedRole'
          AND useridentity.sessioncontext.sessionissuer.username LIKE ?
        GROUP BY 1, 2, 3, 4
        ORDER BY (errorcode IS NULL), last_seen DESC
        LIMIT 300
      SQL
    }

    "04-cloudtrail-kms-decrypt" = {
      description = "CloudTrail: 누가 어느 키로 무엇(시크릿·버킷·로그 그룹)을 복호화했나. ? = 시작일, 끝일('yyyy/MM/dd')"
      query       = <<-SQL
        -- ④ CloudTrail: kms:Decrypt 호출자
        --   context_resource 로 무엇을 풀었는지 본다 (Secrets Manager 시크릿 / S3 버킷 / 로그 그룹).
        --   예: A-1(2026-10-12 적용) 이후 CI plan 역할은 시크릿을 복호화할 수 없다 — 그 뒤로는 행이 없어야 한다.
        SELECT
          coalesce(useridentity.sessioncontext.sessionissuer.username,
                   useridentity.arn,
                   useridentity.invokedby)                                               AS principal,
          sourceipaddress                                                                AS via,
          element_at(resources, 1).arn                                                   AS key_arn,
          coalesce(
            json_extract_scalar(requestparameters, '$.encryptionContext.SecretARN'),
            regexp_extract(json_extract_scalar(requestparameters, '$.encryptionContext["aws:s3:arn"]'), '^arn:aws:s3:::[^/]+'),
            json_extract_scalar(requestparameters, '$.encryptionContext["aws:logs:arn"]')
          )                                                                              AS context_resource,
          count(*)                                                                       AS calls,
          count_if(errorcode IS NOT NULL)                                                AS denied,
          min(eventtime)                                                                 AS first_seen,
          max(eventtime)                                                                 AS last_seen
        FROM security_logs.cloudtrail
        WHERE region = 'ap-northeast-2'
          AND day BETWEEN ? AND ?
          AND eventsource = 'kms.amazonaws.com'
          AND eventname = 'Decrypt'
        GROUP BY 1, 2, 3, 4
        ORDER BY calls DESC
        LIMIT 200
      SQL
    }

    "05-cloudtrail-ecr-push" = {
      description = "CloudTrail: 누가 어떤 태그·digest 를 ECR 에 올렸나(거부 포함). ? = 시작일, 끝일('yyyy/MM/dd')"
      query       = <<-SQL
        -- ⑤ CloudTrail: ECR 이미지 push 이력 (공급망 추적)
        --   같은 태그를 다시 올리려는 시도는 IMMUTABLE 에 막혀 errorcode = ImageTagAlreadyExistsException 으로 남는다.
        --   image_tag 가 비어 있는 행 = 태그 없이 digest 로만 올린 객체 (예: 서명 referrer)
        SELECT
          eventtime,
          coalesce(useridentity.sessioncontext.sessionissuer.username, useridentity.arn) AS principal,
          json_extract_scalar(requestparameters, '$.repositoryName')                     AS repository,
          json_extract_scalar(requestparameters, '$.imageTag')                           AS image_tag,
          json_extract_scalar(responseelements, '$.image.imageId.imageDigest')           AS image_digest,
          errorcode
        FROM security_logs.cloudtrail
        WHERE region = 'ap-northeast-2'
          AND day BETWEEN ? AND ?
          AND eventsource = 'ecr.amazonaws.com'
          AND eventname = 'PutImage'
        ORDER BY eventtime DESC
        LIMIT 200
      SQL
    }
  }
}

resource "aws_athena_named_query" "investigation" {
  for_each = local.athena_named_queries

  name        = each.key
  description = each.value.description
  workgroup   = aws_athena_workgroup.security.name
  database    = aws_glue_catalog_database.security_logs.name

  # 줄바꿈 정규화 — heredoc 은 CR 을 보존하고 query 는 바뀌면 재생성이라, Windows(CRLF)에서 apply 하면 CI plan 이 저장 쿼리 교체를 계획한다.
  # 끝 줄바꿈도 잘라 서비스 쪽 정규화에 흔들리지 않게 한다.
  query = trimspace(replace(each.value.query, "\r", ""))
}
