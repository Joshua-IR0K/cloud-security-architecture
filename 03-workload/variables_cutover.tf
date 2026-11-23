# 사용법:
#   ① 초기 상태(기본값): EC2 100 / EKS 0  → EKS TG 는 비어 있어도 무해
#   ④ 컷오버:  terraform apply \
#                -var 'ec2_traffic_weight=0' -var 'eks_traffic_weight=100'
#   롤백:      weight 원복 apply
#              (실장애 시 콘솔 ModifyRule 로 먼저 되돌리고 → state 정합)
#
# 코드 수정 없이 변수만으로 트래픽을 옮기는 것이 목적
# (canary 도 가능: 90/10 → 50/50 → 0/100)

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
