# VPC CNI 전용 역할. 모듈 기본값은 CNI 정책을 노드 역할에 붙여서, IMDS 경로가 열리면 노드 위 모든 파드가 ENI·IP 조작 권한을 얻는다.
# hop limit 1(경로 차단)과 별개로, 빼앗길 권한 자체를 노드에서 없앤다. 연결은 eks.tf의 vpc-cni 애드온에서 한다.

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

# IPv4 클러스터는 AmazonEKS_CNI_Policy 하나면 된다(IPv6는 정책이 따로 필요).
# 이 부착이 빠지면 ipamd가 DescribeNetworkInterfaces에서 403을 받고, 노드가 NotReady가 됐다가 약 33분 뒤 NodeCreationFailure가 난다.
# module.eks 밖이라 -target=module.eks로는 빠진다. 그럴 땐 -target=module.eks -target=aws_iam_role.vpc_cni -target=aws_iam_role_policy_attachment.vpc_cni
# Pod Identity는 자격 제공에 성공하면 권한이 모자라도 노드 역할로 넘어가지 않는다.
resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}
