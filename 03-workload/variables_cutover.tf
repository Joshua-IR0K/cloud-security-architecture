# 트래픽 전환은 코드 수정 없이 이 두 변수로만 한다. 기본값 EC2 100 / EKS 0 — 비어 있는 EKS 대상 그룹으로 요청이 가지 않는다.
#   전환: terraform apply -var 'ec2_traffic_weight=0' -var 'eks_traffic_weight=100'  (05 로 파드가 등록된 뒤)
#   롤백: 가중치를 되돌려 apply. 실장애 때는 콘솔에서 규칙 가중치를 먼저 되돌리고 state 를 맞춘다.

variable "ec2_traffic_weight" {
  description = "oidc_auth 룰 forward 에서 EC2(blue) 타깃그룹 가중치 (0~999)"
  type        = number
  default     = 100
}

variable "eks_traffic_weight" {
  description = "oidc_auth 룰 forward 에서 EKS(green) 타깃그룹 가중치 (0~999)"
  type        = number
  default     = 0
}
