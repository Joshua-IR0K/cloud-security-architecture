# ============================================================
# 02-security/asg_slr.tf — ASG 서비스연결역할 (신규 추가 파일, 게이트 #1)
# ============================================================
#
# 배경: EKS 매니지드 노드그룹의 실제 인스턴스 생성 주체는 EKS 가 아니라
#   AWS 관리 ASG. 노드 EBS 를 ebs 고객관리형 키로 암호화하면 ASG 가
#   "자기 SLR 자격"으로 KMS grant 를 만들어 볼륨을 복호화해야 함.
#   → SLR 존재 + 키 정책 위임(PATCH_kms_key_policy.md) 둘 다 필요.
#   누락 시: 노드그룹 CREATE_FAILED 무한 반복
#            (ASG Activity: "Client.InternalError: Client error on launch")
#
# 대조 완료(2026-07): 키 리소스명 = aws_kms_key.ebs (kms.tf ③) ✓
#   SSM 발행은 02 기존 ssm_outputs.tf 의 ebs_kms_key_arn 이 이미 수행 중
#   → 이 파일은 SLR 하나만 추가 (중복 발행 없음)
#
# ⚠ SLR 이 계정에 이미 존재하면 create 가 실패함. 사전 확인:
#   aws iam get-role --role-name AWSServiceRoleForAutoScaling
#   → 존재(NoSuchEntity 아님)하면 create 대신 import:
#   terraform import aws_iam_service_linked_role.autoscaling `
#     arn:aws:iam::<ACCOUNT_ID>:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling
# ============================================================

resource "aws_iam_service_linked_role" "autoscaling" {
  aws_service_name = "autoscaling.amazonaws.com"
  description      = "EKS managed node group (ASG) launching CMK-encrypted EBS volumes"
}
