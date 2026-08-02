# ============================================================
# 04-eks/outputs.tf
# ============================================================

output "cluster_name" {
  description = "EKS 클러스터 이름"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API 엔드포인트"
  value       = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "로컬 kubectl 설정 명령 (apply 후 1회 실행)"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "verify_target_health_command" {
  description = "③ 검증: EKS 타깃그룹 healthy 확인 명령"
  value       = "aws elbv2 describe-target-health --target-group-arn ${local.eks_tg_arn} --query 'TargetHealthDescriptions[].TargetHealth.State'"
}


