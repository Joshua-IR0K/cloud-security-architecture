# Auto Mode는 안 쓴다. 노드 IMDS, 노드 역할, 시작 템플릿을 직접 통제하려고.

# 선행 조건: 02의 컨트롤 플레인 로그 그룹. 없으면 여기서 plan이 실패한다.
# 그대로 진행하면 EKS가 보존·암호화 설정 없는 기본 그룹을 먼저 만들어 버려서, 나중에 02 apply를 돌릴 때 "이미 존재함" 에러로 깨진다.
data "aws_cloudwatch_log_group" "eks_control_plane" {
  name = "/aws/eks/${var.cluster_name}/cluster"
}

module "eks" {
  # 레지스트리 태그 대신 커밋 SHA로 고정한다(CKV_TF_1). 태그는 옮겨질 수 있다. 고정 버전은 v21.25.0.
  # 갱신: 새 태그의 커밋 SHA와 위 버전 표기를 같이 바꾸고 init, plan으로 차이를 확인한다.
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks.git?ref=48a429f63cf96361ea2f4b42677d0cc8a9a656e0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = local.vpc_id
  subnet_ids = local.private_subnet_ids # 노드는 프라이빗 서브넷에만

  # API 엔드포인트: 퍼블릭은 관리자 IP /32만, 프라이빗도 켠다.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = ["${var.my_ip}/32"]
  endpoint_private_access      = true

  # 인증은 access entry(API 모드). 클러스터를 만든 주체(Terraform 실행자)가 admin 접근 항목으로 자동 등록된다.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # 비용 가드레일: 표준 지원만 쓴다(extended는 시간당 6배).
  upgrade_policy = {
    support_type = "STANDARD"
  }

  # 노드 간 파드 통신을 허용한다. 모듈 기본 노드 SG는 self-ingress를 DNS(53)만 열어서 다른 노드 파드끼리 통신이 끊긴다.
  # SG는 노드 단위라 파드 수준 의도를 담을 수 없다. 기본 모델을 되살리고, 파드 간 선택적 통제는 NetworkPolicy가 맡는다.
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node (pod to pod) all ports"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  # 컨트롤 플레인 로그는 audit·authenticator. 그룹은 02가 만들어서 create_cloudwatch_log_group = false
  enabled_log_types           = ["audit", "authenticator"]
  create_cloudwatch_log_group = false

  # 시크릿 암호화 키를 모듈이 만들지 않게 한다. 세션마다 destroy하면 삭제 대기 키가 쌓인다. EKS 기본 봉투 암호화를 쓴다.
  create_kms_key    = false
  encryption_config = null

  # before_compute = true: 노드 그룹보다 애드온을 먼저 깐다. CNI 없이 노드가 떠서 NetworkPluginNotReady가 되는 걸 피한다.
  # pod-identity-agent는 링크로컬(169.254.170.23)로 자격증명을 줘서 IMDS가 필요 없다. hop limit 1과 부딪히지 않는다.
  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
      # aws-node는 노드 역할 대신 전용 Pod Identity를 쓴다. 이미 떠 있는 aws-node 파드에는 소급되지 않아서 재기동해야 한다.
      pod_identity_association = [
        {
          role_arn        = aws_iam_role.vpc_cni.arn
          service_account = "aws-node"
        }
      ]

      # NetworkPolicy 집행을 켠다. 켜기만 하고 정책은 05 network-policy.tf가 정한다(정책이 없으면 전부 허용).
      # 판정 로그는 노드 로컬에만 남긴다. 로그는 S3가 기본이라 enableCloudWatchLogs는 안 켠다.
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
        nodeAgent = {
          enablePolicyEventLogs = "true"
        }
      })
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]

      min_size = var.node_min_size
      max_size = var.node_max_size
      # desired_size는 처음 만들 때만 반영된다(모듈이 이후 변경을 무시한다). 운영 중 스케일은 CLI로.
      desired_size = var.node_desired_size

      # IMDSv2 강제 + hop limit 1: hostNetwork가 아닌 파드는 IMDS 응답을 못 받아서 노드 역할을 빼앗을 길이 막힌다.
      # 2 이상으로 올리면 이 통제가 사라진다(aws-node·kube-proxy는 hostNetwork라 영향 없음).
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      # 모듈 노드 SG에 APP SG를 추가로 단다. 01의 ALB egress가 APP SG를 향해서, 없으면 헬스체크가 Target.Timeout이 난다.
      # plan에서 network_interfaces.security_groups가 2개인지 확인한다. 1개(APP SG만)면 노드와 컨트롤 플레인 사이 통신이 끊긴다.
      vpc_security_group_ids = [local.app_sg_id]

      # SSM Session Manager로 SSH 없이 노드에 접속한다(AL2023 에이전트 내장).
      iam_role_additional_policies = {
        ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      # false면 노드 역할에서 CNI 정책을 뗀다. aws-node는 전용 역할(cni-identity.tf)을 쓴다.
      iam_role_attach_cni_policy = var.cni_node_role_policy_attached

      # EBS는 02의 ebs CMK로 암호화한다. 키 정책에 ASG SLR 위임이 있어야 하고, 없으면 노드 그룹이 CREATE_FAILED를 반복한다(02 asg_slr.tf).
      # delete_on_termination: 세션마다 destroy해도 고아 볼륨이 안 남게.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 20
            volume_type           = "gp3"
            encrypted             = true
            kms_key_id            = local.ebs_kms_key_arn
            delete_on_termination = true
          }
        }
      }
    }
  }
}
