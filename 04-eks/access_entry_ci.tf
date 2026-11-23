# ★ 핵심 결정: AWS 관리형 access policy 를 붙이지 않는다.
#   AmazonEKSClusterAdminPolicy  → 과함 (클러스터 전체)
#   AmazonEKSEditPolicy          → 네임스페이스 범위지만 Secret·SA·NetworkPolicy·
#                                   pod exec 까지 포함 → K8s Secret 을 쓰지 않는 원칙과 어긋남
#
#   대신 access entry 를 Kubernetes **그룹**에만 매핑하고,
#   실제 권한은 05-k8s 의 Role/RoleBinding 이 정의한다.
#   → 권한의 정의를 K8s 평면에 두어, "무엇을 할 수 있는가"가
#     kubectl 로 검증 가능한 형태(Role)로 남는다.

data "aws_ssm_parameter" "github_deploy_role_arn" {
  name = "/${var.project_name}/bootstrap/github_deploy_role_arn"
}

resource "aws_eks_access_entry" "ci_deployer" {
  cluster_name  = module.eks.cluster_name
  principal_arn = nonsensitive(data.aws_ssm_parameter.github_deploy_role_arn.value)
  type          = "STANDARD"

  # 이 그룹 이름이 05-k8s 의 RoleBinding subject 와 일치해야 한다 (크로스스택 계약)
  kubernetes_groups = ["ci-deployer"]

  tags = { Name = "${var.project_name}-ci-deployer-access-entry" }
}

# ⚠ aws_eks_access_policy_association 을 의도적으로 두지 않는다.
#   관리형 정책을 붙이면 위에 적은 과잉 권한이 따라온다.
#   access entry 는 "이 IAM 역할 = ci-deployer 그룹"이라는 신원 매핑만 하고,
#   인가는 05 의 Role/RoleBinding 이 전담한다.
#   → 인증(AWS/IAM)과 인가(K8s RBAC)의 관심사 분리.

# CodeBuild 러너 → EKS API 네트워크 경로 (P0-2)
# ⚠ 프라이빗 서브넷 배치만으로는 클러스터 API 에 도달하지 않는다.
#   EKS 클러스터 SG 의 인바운드에 러너 SG 를 소스로 허용해야 한다.
#   → #13(모듈 기본 노드 SG 가 self-ingress 를 DNS 만 허용해 cross-node 통신
#     차단)과 같은 계열의 함정: **네트워크 배치 ≠ 도달 가능성**.
#
# 왜 게이트 변수인가:
#   이 규칙은 02-security 가 러너 SG 를 만든 뒤에만 성립한다.
#   S6-B 착수 전 사이클(03/04/05 반복)에서는 러너가 없으므로,
#   기본값 false 로 두어 SSM 조회 실패로 apply 가 깨지지 않게 한다.
#   → S6-B 진입 시 true 로 flip.
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

# ⚠ 퍼블릭 엔드포인트 allowlist 는 건드리지 않는다.
#   러너는 VPC 내부에 있으므로 클러스터 DNS 가 프라이빗 IP 로 해석되고,
#   위 SG 규칙으로 프라이빗 엔드포인트에 도달한다.
