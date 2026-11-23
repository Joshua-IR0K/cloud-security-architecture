resource "aws_guardduty_detector" "main" {
  #checkov:skip=CKV2_AWS_3:단일 계정 범위 — Organizations 수준 활성화는 Phase 5에서 구성
  enable = true

  # Finding 발행 주기: 15분 (가장 빠른 설정)
  # 실시간은 아니지만, EventBridge를 통해 Finding 생성 즉시 알림 가능
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  datasources {
    # S3 보호: S3 데이터 이벤트 분석
    s3_logs {
      enable = true
    }

    # EKS 보호: Phase 4B에서 EKS 전환 후 자동 적용
    kubernetes {
      audit_logs {
        enable = false # Phase 4B에서 true로 변경
      }
    }

    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }

  tags = {
    Name = "${var.project_name}-guardduty"
  }
}
