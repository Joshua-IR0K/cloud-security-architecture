# EKS 대상 그룹 ARN 만 발행한다 — ALB SG ID 는 소유자인 01 이 이미 발행하므로 04 가 01 스택에서 읽어야 함

resource "aws_ssm_parameter" "eks_target_group_arn" {
  name  = "/${var.project_name}/workload/eks_target_group_arn"
  type  = "String"
  value = aws_lb_target_group.eks.arn

  tags = { Name = "${var.project_name}-eks-target-group-arn" }
}
