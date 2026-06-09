# ============================================================
# guardduty.tf — Amazon GuardDuty (위협 탐지)
# ============================================================
#
# 역할: ML 기반으로 악의적 활동과 이상 행위를 자동 탐지
#
# 분석 대상:
#   - CloudTrail 관리 이벤트 (API 호출 이상)
#   - VPC Flow Logs (네트워크 이상)
#   - DNS 로그 (악성 도메인 통신)
#
# Finding 유형 예시:
#   - UnauthorizedAccess:IAMUser/MaliciousIPCaller
#   - Recon:EC2/PortProbeUnprotectedPort
#   - CryptoCurrency:EC2/BitcoinTool.B!DNS
#
# 비용: 30일 무료 → 이후 분석량 기반 과금 (테스트 수준 $3~5/월)
#
# ============================================================

# ── GuardDuty 활성화 ──────────────────────────────────────
resource "aws_guardduty_detector" "main" {
  enable = true

  # Finding 발행 주기: 15분 (가장 빠른 설정)
  # 실시간은 아니지만, EventBridge를 통해 Finding 생성 즉시 알림 가능
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  # 데이터 소스 설정
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

    # Malware Protection
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
