# EKS 대상 그룹 ARN만 발행한다. ALB SG ID는 01이 이미 발행해서 04가 01 쪽에서 읽어야 한다.

resource "aws_ssm_parameter" "eks_target_group_arn" {
  name  = "/${var.project_name}/workload/eks_target_group_arn"
  type  = "String"
  value = aws_lb_target_group.eks.arn

  tags = { Name = "${var.project_name}-eks-target-group-arn" }
}
