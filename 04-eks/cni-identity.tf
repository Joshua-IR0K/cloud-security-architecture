# VPC CNI 전용 역할 — 모듈 기본값은 CNI 정책을 노드 역할에 붙여, IMDS 경로가 열리면 노드 위 모든 파드가 ENI·IP 조작 권한을 얻는다.
# hop limit 1(경로 차단)과 별개로, 빼앗길 권한 자체를 노드에서 없앤다. 연결은 eks.tf 의 vpc-cni 애드온.

data "aws_iam_policy_document" "vpc_cni_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole", "sts:TagSession"]
  }
}

resource "aws_iam_role" "vpc_cni" {
  name               = "${var.cluster_name}-vpc-cni"
  assume_role_policy = data.aws_iam_policy_document.vpc_cni_trust.json
}

# IPv4 클러스터 = AmazonEKS_CNI_Policy 하나로 충분 (IPv6 는 별도 정책 필요)
# 이 부착이 빠지면 ipamd 가 DescribeNetworkInterfaces 403 → 노드 NotReady → NodeCreationFailure (약 33분 뒤).
# module.eks 밖이라 -target=module.eks 로는 빠진다 → -target=module.eks -target=aws_iam_role.vpc_cni -target=aws_iam_role_policy_attachment.vpc_cni
# Pod Identity 는 자격 제공에 성공하면 권한이 부족해도 노드 역할로 폴백하지 않음
resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}
