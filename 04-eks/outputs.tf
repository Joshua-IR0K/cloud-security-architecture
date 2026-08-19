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

# ============================================================
# Stage 2 검증 헬퍼 — 실행: Invoke-Expression (terraform output -raw <이름>)
# ============================================================

output "s2_bucket" {
  description = "S2 데모 버킷 이름"
  value       = aws_s3_bucket.identity_demo.bucket
}

output "s2_verify_denied" {
  description = "① BREAK — '자격증명 부재'로 실패해야 정상 (성공하면 IMDS 경로 의심)"
  value       = "kubectl exec deploy/identity-denied -- aws s3 ls s3://${aws_s3_bucket.identity_demo.bucket} --region ${var.region}"
}

output "s2_verify_granted" {
  description = "② 성공해야 정상 — hello-from-stage2.txt 가 보임"
  value       = "kubectl exec deploy/identity-granted -- aws s3 ls s3://${aws_s3_bucket.identity_demo.bucket} --region ${var.region}"
}

output "s2_verify_scope" {
  description = "③ 스코프 증명 — 전체 버킷 목록은 AccessDenied 여야 정상 (ListAllMyBuckets 의도적 부재)"
  value       = "kubectl exec deploy/identity-granted -- aws s3 ls --region ${var.region}"
}

output "s2_cni_restart" {
  description = "Phase A — aws-node 재기동 (Pod Identity 주입 반영, 소급 미적용 해소)"
  value       = "kubectl -n kube-system rollout restart daemonset aws-node ; kubectl -n kube-system rollout status daemonset aws-node"
}

output "s2_cni_env_check" {
  description = <<-EOT
    Phase A 게이트 1 — Pod Identity 주입 확인 (env 2개 + 토큰 볼륨).
    ⚠ 컨테이너 exec 방식(printenv) 금지: 최신 VPC CNI 이미지는 최소 베이스라
      셸 유틸리티가 없어 "executable file not found" 로 실패 (트러블슈팅 #8).
      상태 확인은 컨테이너 내부가 아니라 API 서버에서 한다.
    ⚠ DaemonSet 이 아니라 "파드"를 조회할 것 — 주입은 admission-time 에
      파드에만 일어나므로 DaemonSet 템플릿에는 나타나지 않음.
  EOT
  value       = "kubectl -n kube-system describe pod -l k8s-app=aws-node | Select-String \"AWS_CONTAINER_CREDENTIALS_FULL_URI|AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE|eks-pod-identity-token\""
}

output "s2_cni_addon_check" {
  description = "Phase A 보조 — 애드온 레벨에서 Pod Identity 연결이 실제로 걸렸는지"
  value       = "aws eks describe-addon --cluster-name ${var.cluster_name} --addon-name vpc-cni --region ${var.region} --query \"addon.podIdentityAssociations\""
}

output "s2_node_role_policies" {
  description = "Phase B 전/후 — 노드롤 정책 목록 (CNI 정책 detach 확인용 before/after 증거)"
  value       = "aws iam list-attached-role-policies --role-name ${module.eks.eks_managed_node_groups["default"].iam_role_name} --query \"AttachedPolicies[].PolicyName\""
}

# ============================================================
# Stage 3 검증 헬퍼 — NetworkPolicy 마이크로세그멘테이션
# ============================================================

output "s3_netpol_status" {
  description = "정책 목록 — 게이트 ON 이면 4개(deny/dns/alb/identity), OFF 면 0개"
  value       = "kubectl get networkpolicy -n default"
}

output "s3_verify_pod_to_pod" {
  description = <<-EOT
    핵심 실증 — 클라이언트 → nginx (east-west).
    BEFORE(게이트 OFF): HTML 응답  /  AFTER(ON): 타임아웃 = 차단
    ※ DNS 는 허용 정책이 있으므로 이름 해석은 계속 성공 —
      실패 원인이 DNS 가 아니라 L3/L4 정책임이 분리 증명됨
  EOT
  value       = "kubectl exec deploy/netpol-client -- wget -qO- --timeout=5 http://nginx"
}

output "s3_verify_placement" {
  description = "교차 노드 배치 확인 — nginx 와 netpol-client 가 서로 다른 NODE 여야 교차 노드 실증"
  value       = "kubectl get pods -o wide -l 'app in (nginx,netpol-client)'"
}

output "s3_verify_imds_blocked" {
  description = <<-EOT
    IMDS 차단 확인 (겹방어 2층) — 타임아웃이 정답.
    1층 hop-limit=1(S1) + 2층 NetworkPolicy except 169.254.169.254/32(S3)
  EOT
  value       = "kubectl exec deploy/netpol-client -- wget -qO- --timeout=3 http://169.254.169.254/latest/meta-data/"
}

output "s3_verify_aws_api_allowed" {
  description = "IMDS 는 막고 AWS API 는 통과 — 게이트 ON 상태에서도 S2 의 ② 가 계속 성공해야 정상"
  value       = "kubectl exec deploy/identity-granted -- aws s3 ls s3://${aws_s3_bucket.identity_demo.bucket} --region ${var.region}"
}

output "s3_node_scale" {
  description = "노드 1→2 스케일 (⚠ 모듈이 desired_size 를 무시하므로 Terraform 이 아닌 CLI — D6)"
  value       = "aws eks update-nodegroup-config --cluster-name ${var.cluster_name} --region ${var.region} --nodegroup-name $(aws eks list-nodegroups --cluster-name ${var.cluster_name} --region ${var.region} --query \"nodegroups[0]\" --output text) --scaling-config minSize=0,maxSize=3,desiredSize=2"
}
