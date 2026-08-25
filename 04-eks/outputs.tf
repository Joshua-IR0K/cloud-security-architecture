# ============================================================
# 04-eks/outputs.tf — AWS 평면 (클러스터 정보 · IAM 증거)
# ============================================================
# kubectl 검증 헬퍼는 05-k8s/outputs.tf 로 이동 (평면 분리).
# 여기 남은 것은 AWS API 로 확인하는 것 + 05 가 참조할 식별자.
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

output "s2_bucket" {
  description = "S2 데모 버킷 이름"
  value       = aws_s3_bucket.identity_demo.bucket
}

output "s2_node_role_policies" {
  description = "Phase B 전/후 — 노드롤 정책 목록 (CNI 정책 detach 확인용 before/after 증거)"
  value       = "aws iam list-attached-role-policies --role-name ${module.eks.eks_managed_node_groups["default"].iam_role_name} --query \"AttachedPolicies[].PolicyName\""
}

# ── Stage 4 (AWS 평면) ────────────────────────────────────

output "s4_secret_arn" {
  description = "S4 데모 시크릿 ARN — 05-k8s SecretProviderClass 가 참조"
  value       = aws_secretsmanager_secret.demo.arn
}

output "s4_secret_name" {
  description = "S4 데모 시크릿 이름"
  value       = aws_secretsmanager_secret.demo.name
}

output "s4_verify_state_clean" {
  description = <<-EOT
    ①의 실증 — state 에 평문이 없음을 확인.
    아무것도 안 나와야 정상 (write-only 인자는 state 에 기록되지 않음).
  EOT
  value       = "terraform state show aws_secretsmanager_secret_version.demo"
}

output "s4_verify_kms_key" {
  description = "②의 실증 — 시크릿이 고객관리형 키로 암호화됐는지"
  value       = "aws secretsmanager describe-secret --secret-id ${aws_secretsmanager_secret.demo.name} --query \"KmsKeyId\""
}
