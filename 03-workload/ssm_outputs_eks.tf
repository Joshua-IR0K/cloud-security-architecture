# ============================================================
# 03-workload/ssm_outputs_eks.tf — 04-eks 로 값 전달 (신규 추가 파일)
# ============================================================
# 03 이 최초로 "발행자"가 되는 지점 — workload 세그먼트 신설.
# 발행은 EKS TG ARN 단 하나:
#   - alb_sg_id 는 발행하지 않음. SG 소유자는 01-network 이고 이미
#     "/<project>/network/alb_sg_id" 로 발행 중 → 04 가 소유자에게서
#     직접 읽음 (소유 스택이 발행하고 소비 스택이 조회한다는 원칙)
# 네이밍: 기존 관용구(언더스코어 + var.project_name 보간) 준수
# ============================================================

resource "aws_ssm_parameter" "eks_target_group_arn" {
  name  = "/${var.project_name}/workload/eks_target_group_arn"
  type  = "String"
  value = aws_lb_target_group.eks.arn

  tags = { Name = "${var.project_name}-eks-target-group-arn" }
}
