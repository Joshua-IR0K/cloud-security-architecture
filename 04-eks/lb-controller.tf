# LB Controller(인프라 컴포넌트)용 Pod Identity. 앱 워크로드 자격(identity-demo-iam.tf)과 따로 둔다.

resource "aws_iam_role" "lb_controller" {
  name = "${var.project_name}-eks-lb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession", # Pod Identity는 세션 태깅이 필수다
        ]
      }
    ]
  })
}

# TargetGroupBinding 전용 최소 권한. 공식 정책(Ingress 모드용 넓은 권한) 대신 필요한 액션만 주고, 쓰기는 리소스 ARN으로 묶는다.
# 뚫려도 03의 EKS 대상 그룹 등록·해제와 이 클러스터 노드 SG 규칙 변경만 할 수 있다. LB 생성, 인증서, WAF는 못 건드린다.
data "aws_iam_policy_document" "lb_controller" {
  # 1) Describe/Get. AWS API 제약상 리소스로 묶을 수 없어서 "*"(읽기 전용)
  statement {
    sid    = "DescribeReadOnly"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTags",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSecurityGroupRules",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeInstances",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs",
      "ec2:DescribeAvailabilityZones",
    ]
    resources = ["*"]
  }

  # GetSecurityGroupsForVpc는 VPC 단위로 지정할 수 있어서 이 VPC로 묶는다(CKV_AWS_356). 위 Describe들은 지정 자체가 안 돼서 "*".
  statement {
    sid       = "SecurityGroupsForClusterVpcOnly"
    effect    = "Allow"
    actions   = ["ec2:GetSecurityGroupsForVpc"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:vpc/${local.vpc_id}"]
  }

  # 2) 타깃 등록/해제. 03이 발행한 EKS TG 한 곳으로만
  statement {
    sid    = "TargetRegistrationScoped"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets",
    ]
    resources = [local.eks_tg_arn]
  }

  # 3) TGB networking.ingress. 노드 SG 규칙을 알아서 관리한다.
  #    "ALB SG에서 TCP/8080" 규칙을 컨트롤러가 노드 SG에 만들고 거둬들인다.
  statement {
    sid    = "NodeSGRuleManagement"
    effect = "Allow"
    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
    ]
    resources = [module.eks.node_security_group_arn]
  }

  # 4) 관리 규칙 추적 태그. 노드 SG에만
  statement {
    sid    = "ManagedRuleTags"
    effect = "Allow"
    actions = [
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]
    resources = [module.eks.node_security_group_arn]
  }

  # 5) TG 태그. 컨트롤러가 TGB 대상 TG에 클러스터 태그를 붙이려고 할 수 있다.
  statement {
    sid       = "TargetGroupTags"
    effect    = "Allow"
    actions   = ["elasticloadbalancing:AddTags"]
    resources = [local.eks_tg_arn]
  }
}

resource "aws_iam_policy" "lb_controller" {
  name   = "${var.project_name}-eks-lb-controller"
  policy = data.aws_iam_policy_document.lb_controller.json
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

# kube-system/aws-load-balancer-controller SA 연결. helm이 SA를 만들기 전에 있어야 처음 뜰 때부터 자격증명을 받는다.
resource "aws_eks_pod_identity_association" "lb_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lb_controller.arn
}
