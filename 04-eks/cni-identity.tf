# 문제: 모듈 기본값은 AmazonEKS_CNI_Policy 를 "노드 인스턴스 롤"에 부착
#   → 노드 위 모든 파드가 (IMDS 경로가 열려 있다면) ENI/IP 조작 권한을
#   잠재적으로 상속.
#
# 겹방어 위치: S1 의 hop-limit=1 이 "경로 차단"(1차)이라면,
#   이 분리는 "빼앗길 권한 자체를 노드에서 제거"(2차) — 서로 다른 층.
#
# 해법: CNI 전용 역할(관리형 정책 1개로 스코프) + aws-node SA 에
#   Pod Identity 연결(eks.tf 의 vpc-cni 애드온 pod_identity_association).
#   노드롤 쪽 CNI 정책은 게이트 변수로 2단계 detach.

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
# ⚠ 이 부착이 빠지면 ipamd 가
#   ec2:DescribeNetworkInterfaces 403 → CNI 초기화 실패 → 노드 NotReady →
#   NodeCreationFailure(33분 후 실패). 그런데 이 리소스는 module.eks "밖"이라
#   `terraform apply -target=module.eks` 시 그래프에서 제외된다
#   (역할 자체는 애드온이 참조해 딸려 들어오지만 부착은 안 따라옴).
#   → 2단계 apply 시 반드시 함께 타깃할 것:
#     -target=module.eks -target=aws_iam_role.vpc_cni `
#     -target=aws_iam_role_policy_attachment.vpc_cni
#   ⚠ Pod Identity 는 자격 제공에 "성공"하면 권한이 부족해도 노드롤(IMDS)로
#     폴백하지 않으므로, cni_node_role_policy_attached=true 로도 구제 불가.
resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}
