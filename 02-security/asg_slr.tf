# 노드 인스턴스를 띄우는 주체는 EKS 가 아니라 AWS 관리 ASG 다. 노드 EBS 를 ebs CMK 로 암호화하려면 이 SLR 과 키 정책 위임(kms.tf)이 둘 다 필요하다.
# 없으면 노드 그룹이 "Client.InternalError: Client error on launch" 로 CREATE_FAILED 를 반복한다.
# SLR 이 계정에 이미 있으면 create 가 실패한다 → terraform import aws_iam_service_linked_role.autoscaling <SLR ARN>

resource "aws_iam_service_linked_role" "autoscaling" {
  aws_service_name = "autoscaling.amazonaws.com"
  description      = "EKS managed node group (ASG) launching CMK-encrypted EBS volumes"
}
