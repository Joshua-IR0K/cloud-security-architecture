# ============================================================
# 04-eks/ssm_outputs.tf — 05-k8s 로의 계약 (신규)
# ============================================================
# 결정(a): 클러스터 "이름" 하나만 발행한다.
#   05 는 이 이름으로 data.aws_eks_cluster 를 조회해 endpoint·CA 를 얻음.
#
# 왜 endpoint/CA 를 직접 발행하지 않나:
#   - CA 인증서는 길어 SSM Standard 4KB 한도에 근접 (Advanced 는 유료)
#   - 계약 표면 최소화 — 05 가 알아야 할 건 "어느 클러스터냐" 뿐
#   - AWS API 가 항상 최신값을 주므로 재생성 시 자동 동기화
#     (사이클마다 endpoint 호스트명이 바뀌는 이 프로젝트에 특히 중요)
# ============================================================

resource "aws_ssm_parameter" "cluster_name" {
  name        = "/${var.project_name}/eks/cluster_name"
  description = "EKS cluster name — consumed by 05-k8s to resolve endpoint/CA via API"
  type        = "String"
  value       = module.eks.cluster_name

  tags = { Name = "${var.project_name}-eks-cluster-name" }
}
