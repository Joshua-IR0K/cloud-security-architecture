# ============================================================
# 02-security/eks_control_plane_logs.tf — EKS 컨트롤 플레인 로그 그룹 (멘토 ⑤)
# ============================================================
#
# 왜 필요한가 — 탐지는 있는데 조사할 원본이 없었다
#   GuardDuty EKS Protection 은 audit 스트림을 직접 읽어 "탐지"는 한다.
#   하지만 Finding 이 떴을 때 "누가 어떤 API 를 불렀나"를 볼 원본 로그가 없어
#   탐지 → 조사 → 종결 루프에서 "조사"가 비어 있었다.
#
# 왜 CloudWatch 인가 — S3-only 원칙의 명시적 예외
#   EKS 컨트롤 플레인 로그의 네이티브 목적지는 CloudWatch Logs 하나뿐이다
#   (S3 직접 전송은 aws/containers-roadmap #1141, 미제공).
#   → "CloudWatch 는 CloudWatch 만 받을 수 있는 로그에 한해, 짧게 보관한다"로 원칙을 고쳐 쓴다.
#   장기 보관이 필요해지면 구독 필터 → Firehose → S3 로 확장한다 (보류).
#
# 왜 02 인가 — 클러스터 수명과 증적 수명을 분리
#   04 에 두면(모듈이 만들면) 클러스터 destroy 때 감사 증적도 함께 사라진다.
#   EKS 는 이름이 고정된 그룹(/aws/eks/<cluster>/cluster)에 쓰므로, 영속 스택에
#   미리 만들어 두면 매 사이클 같은 그룹에 쌓이고 destroy 후에도 남는다.
#   (04 는 create_cloudwatch_log_group = false 이고, 이 그룹의 존재를 plan 에서 확인한다)
#
# 수집 범위: audit · authenticator 만 (04 의 enabled_log_types)
#   audit         누가 어떤 쿠버네티스 API 를 불렀나 (조사의 핵심)
#   authenticator 어떤 IAM 신원이 어떤 쿠버네티스 사용자로 매핑됐나
#   api · controllerManager · scheduler 는 운영 디버깅용이라 비용 대비 가치가 낮아 제외
# ============================================================

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

  # logs 키로 암호화 — 키 정책의 AllowCloudWatchLogsForEksControlPlane 이
  # 이 로그 그룹 하나에만 키 사용을 허용한다 (kms.tf)
  kms_key_id = aws_kms_key.logs.arn

  tags = {
    Name    = "${var.project_name}-eks-control-plane-logs"
    Purpose = "eks-audit-investigation"
  }
}
