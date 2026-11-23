# 노드 인스턴스를 띄우는 건 EKS가 아니라 AWS 관리 ASG다. 노드 EBS를 ebs CMK로 암호화하려면 이 SLR과 키 정책 위임(kms.tf)이 둘 다 있어야 한다.
# 없으면 노드 그룹이 "Client.InternalError: Client error on launch"로 CREATE_FAILED를 반복한다.
# SLR이 계정에 이미 있으면 create가 실패한다. 그럴 땐 terraform import aws_iam_service_linked_role.autoscaling <SLR ARN>

resource "aws_iam_service_linked_role" "autoscaling" {
  aws_service_name = "autoscaling.amazonaws.com"
  description      = "EKS managed node group (ASG) launching CMK-encrypted EBS volumes"
}
