# EKS 컨트롤 플레인 감사 로그 그룹. 클러스터(04)를 지워도 증적이 남게 영속 스택에 둔다.
# EKS는 이름이 정해진 그룹(/aws/eks/<cluster>/cluster)에 쓰니까 04는 create_cloudwatch_log_group = false로 두고,
# 이 그룹이 있는지 plan 단계에서 확인한다. 수집 범위는 audit·authenticator(04 enabled_log_types).

variable "eks_cluster_name" {
  description = "04-eks 의 클러스터 이름. 로그 그룹 이름(/aws/eks/<name>/cluster)이 이 값에 고정된다 — 04 의 var.cluster_name 과 같아야 한다"
  type        = string
  default     = "joshua-eks"
}

variable "eks_control_plane_log_retention_days" {
  description = "EKS 컨트롤 플레인 로그 보존 일수 (조사용 단기 보관)"
  type        = number
  default     = 14
}

resource "aws_cloudwatch_log_group" "eks_control_plane" {
  #checkov:skip=CKV_AWS_338:1년 보존 미적용 — 실습 클러스터의 조사용 단기 보관(14일). 장기 보관이 필요해지면 Firehose→S3 로 확장 (S3-only 원칙)
  name              = "/aws/eks/${var.eks_cluster_name}/cluster"
  retention_in_days = var.eks_control_plane_log_retention_days

  # logs 키로 암호화한다. 키 정책의 AllowCloudWatchLogsForEksControlPlane이
  # 이 로그 그룹 하나에만 키 사용을 허용한다(kms.tf).
  kms_key_id = aws_kms_key.logs.arn

  tags = {
    Name    = "${var.project_name}-eks-control-plane-logs"
    Purpose = "eks-audit-investigation"
  }
}
