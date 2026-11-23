# 아이덴티티 설계:
#   이 Pod Identity 는 "인프라 컴포넌트" 아이덴티티.
#   후속 스테이지의 "애플리케이션 워크로드" Pod Identity 와는 목적이 구분됨
#   (인프라 부트스트랩 vs 앱 최소권한).

# IAM Role: Pod Identity 신뢰 정책
# IRSA 와의 차이:
#   IRSA  = OIDC Federated + sub 조건 문자열 (별표 오설정 위험)
#   PodID = pods.eks.amazonaws.com 서비스 프린시펄 + EKS 가
#           클러스터/네임스페이스/SA 매핑을 API 레벨에서 강제
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
          "sts:TagSession", # Pod Identity 는 세션 태깅 필수
        ]
      }
    ]
  })
}

# IAM Policy: TGB 전용 최소권한
# 공식 정책(elasticloadbalancing 광범위 + ACM/WAF/Shield/Cognito 등
# Ingress 모드 전용 권한 포함)을 쓰지 않고, "TGB-only 운용"에 필요한
# 액션만 허용 + 쓰기 액션은 리소스 ARN 으로 핀포인트:
#
#   폭발반경 통제: 이 역할이 침해돼도
#     - 타깃 등록/해제는 03 이 발행한 EKS TG "한 곳"에서만 가능
#     - SG 룰 변경은 이 클러스터의 노드 SG 에서만 가능
#     - LB/리스너/TG 생성·삭제, 인증서·WAF 접근은 아예 불가 (권한 부재)
#
# 최소권한 반복 루프: 권한 부족 시 컨트롤러 로그에
#   AccessDenied + 액션명이 그대로 찍힘 → 해당 액션만 의식적으로 추가.
data "aws_iam_policy_document" "lb_controller" {
  # 1) Describe/Get — AWS API 제약상 리소스 스코프 불가 → "*" (읽기 전용)
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

  # 1-b) GetSecurityGroupsForVpc 는 VPC 단위 리소스 지정을 지원한다 (Checkov CKV_AWS_356)
  #      → 이 클러스터의 VPC 하나로 핀포인트. 위 Describe 들은 리소스 지정 자체가 불가해 "*" 가 유일한 선택.
  #      ⚠ 클러스터 세션에서 확인: LBC 로그에 AccessDenied 가 없고 TGB 가 정상 동작해야 한다.
  statement {
    sid       = "SecurityGroupsForClusterVpcOnly"
    effect    = "Allow"
    actions   = ["ec2:GetSecurityGroupsForVpc"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:vpc/${local.vpc_id}"]
  }

  # 2) 타깃 등록/해제 — 03 발행 EKS TG 한 곳으로 핀포인트
  statement {
    sid    = "TargetRegistrationScoped"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets",
    ]
    resources = [local.eks_tg_arn]
  }

  # 3) TGB networking.ingress — 노드 SG 룰 자동 관리
  #    "ALB SG 발신 → TCP/8080" 규칙을 컨트롤러가 노드 SG 에 생성/회수
  statement {
    sid    = "NodeSGRuleManagement"
    effect = "Allow"
    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
    ]
    resources = [module.eks.node_security_group_arn]
  }

  # 4) 관리 룰 추적 태그 — 노드 SG 한정
  statement {
    sid    = "ManagedRuleTags"
    effect = "Allow"
    actions = [
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]
    resources = [module.eks.node_security_group_arn]
  }

  # 5) TG 태그 — 컨트롤러가 TGB 대상 TG 에 클러스터 태그를 시도할 수 있음
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

# Pod Identity Association
# kube-system/aws-load-balancer-controller SA ↔ 위 IAM Role 매핑
# helm 이 SA 를 만들기 "전"에 association 이 존재해야
# 컨트롤러 파드가 첫 기동부터 자격증명을 받음 (depends_on 사슬)
resource "aws_eks_pod_identity_association" "lb_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lb_controller.arn
}
