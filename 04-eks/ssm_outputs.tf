# 클러스터 이름만 발행해 둔다 — 05 스택은 이 이름으로 endpoint랑 CA를 직접 조회한다.
# CA는 SSM Standard 4KB 한도에 간당간당하고, 세션마다 바뀌는 endpoint도 API로 받아오면 늘 최신 값이 유지된다.

resource "aws_ssm_parameter" "cluster_name" {
  name        = "/${var.project_name}/eks/cluster_name"
  description = "EKS cluster name — consumed by 05-k8s to resolve endpoint/CA via API"
  type        = "String"
  value       = module.eks.cluster_name

  tags = { Name = "${var.project_name}-eks-cluster-name" }
}
