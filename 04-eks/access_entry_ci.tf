# 관리형 접근 정책은 안 붙인다. ClusterAdmin은 과하고, Edit는 Secret·SA·NetworkPolicy·exec까지 들어 있다.
# 접근 항목은 쿠버네티스 그룹에만 매핑하고, 실제 권한은 05의 Role/RoleBinding이 정한다.

data "aws_ssm_parameter" "github_deploy_role_arn" {
  name = "/${var.project_name}/bootstrap/github_deploy_role_arn"
}

resource "aws_eks_access_entry" "ci_deployer" {
  cluster_name  = module.eks.cluster_name
  principal_arn = nonsensitive(data.aws_ssm_parameter.github_deploy_role_arn.value)
  type          = "STANDARD"

  # 이 그룹 이름이 05-k8s의 RoleBinding subject와 같아야 한다(스택 간 약속).
  kubernetes_groups = ["ci-deployer"]

  tags = { Name = "${var.project_name}-ci-deployer-access-entry" }
}

# CodeBuild 러너에서 EKS API(443)로. 프라이빗 서브넷에 있다고 API에 닿는 건 아니라서 클러스터 SG에 러너 SG를 허용해야 한다.
# 러너 SG(02)가 있어야 되는 규칙이라 변수로 켠다. 꺼져 있으면 CI 배포가 EKS API에 못 닿는다.
variable "ci_runner_ingress_enabled" {
  description = <<-EOT
    CodeBuild 배포 러너 → EKS API(443) 인바운드 허용 여부.
    기본 false — 02-security 에 러너가 생성된 뒤(S6-B) true 로 전환한다.
    false 인 상태로 apply 해도 기존 사이클은 영향받지 않는다.
  EOT
  type        = bool
  default     = false
}

data "aws_ssm_parameter" "codebuild_runner_sg_id" {
  count = var.ci_runner_ingress_enabled ? 1 : 0
  name  = "/${var.project_name}/security/codebuild_runner_sg_id"
}

resource "aws_vpc_security_group_ingress_rule" "ci_runner_to_cluster_api" {
  count = var.ci_runner_ingress_enabled ? 1 : 0

  security_group_id            = module.eks.cluster_security_group_id
  referenced_security_group_id = nonsensitive(data.aws_ssm_parameter.codebuild_runner_sg_id[0].value)
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "CodeBuild deploy runner to EKS private API"

  tags = { Name = "${var.project_name}-ci-runner-to-eks-api" }
}

# 퍼블릭 엔드포인트 허용 목록은 안 건드린다. 러너는 VPC 안이라 프라이빗 엔드포인트로 간다.
