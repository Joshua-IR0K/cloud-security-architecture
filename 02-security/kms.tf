# ============================================================
# 02-security/kms.tf — KMS Customer Managed Keys (용도별 분리)
# ============================================================
#
# 키를 용도별로 분리하는 이유 (멘토 원칙):
#   - Blast Radius 최소화: 한 키가 손상돼도 다른 용도는 안전
#   - 권한 분리: 로그 암호화 키와 시크릿 암호화 키의 접근 주체가 다름
#   - 감사 추적: CloudTrail에서 "어떤 용도의 키가 사용되었나" 구분 가능
#
# 키를 영속 보안 스택(02)에 두는 이유:
#   - Crypto-shredding 방지: 키가 삭제되면 그 키로 암호화된 데이터를
#     영구히 복호화 불가. 워크로드 destroy로 키가 날아가면 안 됨.
#
# Key Policy 설계 원칙:
#   - 모든 키에 "Root 위임" 기본 적용 → IAM Policy로 세부 권한 관리 가능
#     (회사 출입증 비유: 문지기가 "인사팀 권한 등급을 믿겠다"고 선언)
#   - AWS 서비스(CloudTrail, Config 등)는 Key Policy에 직접 명시
#     (KMS는 Key Policy가 최상위 — 여기 없으면 IAM으로도 못 씀)
#
# ============================================================

data "aws_region" "current" {}

# ============================================================
# 키 ①: 로그 암호화 키 (S3 로그 버킷용)
# ============================================================
# 용도: CloudTrail, Config, VPC Flow Logs, WAF Logs의 S3 암호화
resource "aws_kms_key" "logs" {
  description             = "${var.project_name} - S3 log buckets encryption"
  deletion_window_in_days = 7     # 삭제 요청 후 7일 대기 (실수 방지)
  enable_key_rotation     = true  # 연 1회 자동 키 교체

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Root 위임 — IAM Policy로 세부 권한 관리 가능하게
        Sid    = "EnableRootAccount"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        # CloudTrail이 로그를 이 키로 암호화할 수 있도록
        Sid    = "AllowCloudTrail"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        # Config가 구성 스냅샷을 이 키로 암호화할 수 있도록
        Sid    = "AllowConfig"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
          "kms:Decrypt"
        ]
        Resource = "*"
      },
      {
        # VPC Flow Logs 서비스 (delivery.logs.amazonaws.com)
        Sid    = "AllowLogDelivery"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        # SNS 토픽 암호화용 — EventBridge가 암호화된 토픽에 발행하려면 필수
        # ⚠ 이 statement 없이 SNS에 CMK를 걸면 알림이 조용히 실패함 (고전 함정)
        Sid    = "AllowEventBridgeForSNS"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name    = "${var.project_name}-logs-key"
    Purpose = "s3-log-encryption"
  }
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${var.project_name}-logs"
  target_key_id = aws_kms_key.logs.key_id
}

# ============================================================
# 키 ②: 시크릿 암호화 키 (Secrets Manager용)
# ============================================================
# 용도: Secrets Manager에 저장되는 Okta 자격증명 등 암호화
resource "aws_kms_key" "secrets" {
  description             = "${var.project_name} - Secrets Manager encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccount"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        # Secrets Manager를 통한 사용만 허용 (ViaService 조건)
        # 계정 내 주체가 Secrets Manager 경유로만 이 키를 쓸 수 있음
        Sid    = "AllowSecretsManagerUse"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
          "kms:CreateGrant"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${data.aws_region.current.name}.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name    = "${var.project_name}-secrets-key"
    Purpose = "secrets-encryption"
  }
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.project_name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# ============================================================
# 키 ③: EBS 볼륨 암호화 키 (EC2/EKS 워크로드용)
# ============================================================
# 용도: EC2 인스턴스의 EBS 볼륨 암호화 (Phase 4B에서 EKS 노드도)
resource "aws_kms_key" "ebs" {
  description             = "${var.project_name} - EBS volume encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccount"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        # EC2가 EBS 볼륨 암호화에 이 키를 쓸 수 있도록
        # (계정 내 주체가 EC2 경유로 사용)
        Sid    = "AllowEC2Use"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:CreateGrant",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ec2.${data.aws_region.current.name}.amazonaws.com"
          }
        }
      },
      {
        # ── Phase 4B: EKS 노드그룹 EBS 암호화 (게이트 #1) ──
        # 노드 인스턴스를 실제로 띄우는 주체는 EKS 가 아니라 AWS 관리 ASG.
        # SLR 은 AWS 관리 정책이 불변이라 IAM 정책 부착이 불가 →
        # 키 정책에 Principal 로 직접 명시하는 것이 유일한 인가 경로.
        # (선행조건: asg_slr.tf 의 서비스연결역할 리소스)
        Sid    = "AllowASGServiceLinkedRoleUseOfEbsKey"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_service_linked_role.autoscaling.arn
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        # grant 생성 — AWS 리소스(EBS) 연동 grant 로만 제한 (최소권한)
        Sid    = "AllowASGServiceLinkedRoleGrants"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_service_linked_role.autoscaling.arn
        }
        Action   = "kms:CreateGrant"
        Resource = "*"
        Condition = {
          Bool = {
            "kms:GrantIsForAWSResource" = "true"
          }
        }
      }
    ]
  })

  tags = {
    Name    = "${var.project_name}-ebs-key"
    Purpose = "ebs-encryption"
  }
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/${var.project_name}-ebs"
  target_key_id = aws_kms_key.ebs.key_id
}
