# Auto Mode 를 쓰지 않는다 — 노드 IMDS·노드 역할·시작 템플릿을 직접 통제하기 위해.

# 선행 조건: 02 의 컨트롤 플레인 로그 그룹. 없으면 여기서 plan 이 실패한다 —
# 이대로 진행하면 EKS가 보존·암호화 설정 없는 기본 그룹을 먼저 만들어버려서, 나중에 02 apply 돌릴 때 "이미 존재함" 에러로 깨진다.
data "aws_cloudwatch_log_group" "eks_control_plane" {
  name = "/aws/eks/${var.cluster_name}/cluster"
}

module "eks" {
  # 레지스트리 태그 대신 커밋 SHA 로 고정 (CKV_TF_1) — 태그는 옮겨질 수 있다. 고정 버전 v21.25.0.
  # 갱신: 새 태그의 커밋 SHA 와 위 버전 표기를 함께 바꾸고 init → plan 으로 차이 확인.
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks.git?ref=48a429f63cf96361ea2f4b42677d0cc8a9a656e0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = local.vpc_id
  subnet_ids = local.private_subnet_ids # 노드는 프라이빗 서브넷에만

  # API 엔드포인트: 퍼블릭은 관리자 IP /32 + 프라이빗 활성
  endpoint_public_access       = true
  endpoint_public_access_cidrs = ["${var.my_ip}/32"]
  endpoint_private_access      = true

  # 인증은 access entry(API 모드). 클러스터 생성자(Terraform 실행자)가 admin 접근 항목으로 자동 등록됨
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # 비용 가드레일: 표준 지원만 (extended = 시간당 6배)
  upgrade_policy = {
    support_type = "STANDARD"
  }

  # 노드 간 파드 통신 허용 — 모듈 기본 노드 SG 는 self-ingress 를 DNS(53)만 열어 다른 노드의 파드끼리 통신이 끊긴다.
  # SG 는 노드 단위라 파드 수준 의도를 표현할 수 없다 — 기본 모델을 복원하고 파드 간 선택적 통제는 NetworkPolicy 가 맡는다.
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

  # 컨트롤 플레인 로그 audit·authenticator. 그룹은 02 가 소유하므로 create_cloudwatch_log_group = false
  enabled_log_types           = ["audit", "authenticator"]
  create_cloudwatch_log_group = false

  # 시크릿 암호화 키를 모듈이 만들지 않게 한다 — 세션마다 destroy 하면 삭제 대기 키가 쌓인다. EKS 기본 봉투 암호화 사용
  create_kms_key    = false
  encryption_config = null

  # before_compute = true: 노드 그룹보다 애드온을 먼저 — CNI 없이 노드가 떠서 NetworkPluginNotReady 가 되는 문제 회피.
  # pod-identity-agent 는 링크로컬(169.254.170.23)로 자격증명을 줘서 IMDS 가 필요 없다 — hop limit 1 과 충돌하지 않음
  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
      # aws-node 는 노드 역할 대신 전용 Pod Identity 로. 기존 aws-node 파드에는 소급되지 않아 재기동이 필요함
      pod_identity_association = [
        {
          role_arn        = aws_iam_role.vpc_cni.arn
          service_account = "aws-node"
        }
      ]

      # NetworkPolicy 집행 활성화 — 켜기만 하고 정책은 05 network-policy.tf 가 정한다 (정책이 없으면 전면 허용).
      # 판정 로그는 노드 로컬만 — enableCloudWatchLogs 는 S3 기본 로그 원칙에 따라 켜지 않는다.
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
      # desired_size 는 생성 때만 반영된다 (모듈이 이후 변경을 무시). 운영 중 스케일은 CLI 로.
      desired_size = var.node_desired_size

      # IMDSv2 강제 + hop limit 1: hostNetwork 가 아닌 파드는 IMDS 응답을 못 받는다 → 노드 역할 탈취 경로 차단.
      # 2 이상으로 올리면 이 통제가 사라진다 (aws-node·kube-proxy 는 hostNetwork 라 영향 없음)
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      # 모듈 노드 SG 에 APP SG 를 추가로 단다 — 01 의 ALB egress 가 APP SG 를 향해서, 없으면 헬스체크가 Target.Timeout
      # plan 에서 network_interfaces.security_groups 가 2개인지 확인한다 — 1개(APP SG 만)면 노드↔컨트롤 플레인 통신이 끊김
      vpc_security_group_ids = [local.app_sg_id]

      # SSM Session Manager 로 SSH 없이 노드 접속 (AL2023 에이전트 내장)
      iam_role_additional_policies = {
        ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      # false 면 노드 역할에서 CNI 정책을 뗀다 — aws-node 는 전용 역할(cni-identity.tf)을 쓴다.
      iam_role_attach_cni_policy = var.cni_node_role_policy_attached

      # EBS 는 02 의 ebs CMK 로 암호화. 키 정책에 ASG SLR 위임이 있어야 한다 — 없으면 노드 그룹 CREATE_FAILED 반복 (02 asg_slr.tf)
      # delete_on_termination: 세션 반복 destroy 시 고아 볼륨 방지
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
