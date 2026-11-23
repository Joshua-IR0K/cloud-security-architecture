data "aws_region" "current" {}

# 로그 키. CloudTrail·Config·Flow Logs 버킷, SNS 토픽, Athena 결과, EKS 감사 로그 그룹(WAF 로그 버킷은 us-east-1이라 제외)
resource "aws_kms_key" "logs" {
  description             = "${var.project_name} - S3 log buckets encryption"
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
        # 없으면 CMK를 건 SNS 토픽으로 가는 EventBridge 알림이 조용히 실패한다.
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
      },
      {
        # CloudWatch Logs는 리전 서비스 주체(logs.<region>)로 키를 쓴다. 암호화 컨텍스트(aws:logs:arn)로 EKS 감사 로그 그룹 하나에만 묶는다.
        Sid    = "AllowCloudWatchLogsForEksControlPlane"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.name}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*"
        ]
        Resource = "*"
        Condition = {
          ArnEquals = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.eks_cluster_name}/cluster"
          }
        }
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

# 시크릿 키. Secrets Manager(Okta 자격증명)
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
        # Secrets Manager를 거칠 때만 쓴다(ViaService).
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

# EBS 키. EC2·EKS 노드 볼륨
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
        # 노드 인스턴스를 띄우는 건 AWS 관리 ASG의 SLR이다. SLR에는 IAM 정책을 붙일 수 없어서 키 정책에 직접 적는다(asg_slr.tf).
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
        # grant 생성. AWS 리소스(EBS) 연동 grant로만 묶는다(최소 권한).
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
