# ============================================================
# 04-eks/eks.tf — EKS 클러스터 + 매니지드 노드그룹 (모듈 v21)
# ============================================================
#
# v21 입력명 검증 완료 (공식 README 대조, 2026-06):
#   name / kubernetes_version / addons / endpoint_public_access
#   / enable_cluster_creator_admin_permissions / eks_managed_node_groups
#   (v20 의 cluster_* 프리픽스 입력들은 v21 에서 제거됨)
#
# 모듈이 자동 생성하는 것 (알고 있어야 할 목록):
#   클러스터 IAM Role / 노드 IAM Role / 클러스터·노드 보안그룹
#   / OIDC Provider / 애드온 / 노드그룹용 Launch Template
#
# Auto Mode 미채택 (결정 #5): 노드 레이어 보안 통제
#   (IMDS hop-limit, 노드롤, LT)의 코드 가시성이 이 포트폴리오의 목적
# ============================================================

# ── 선행 조건: 02 가 만든 컨트롤플레인 로그 그룹 ─────────────
# 없으면 plan 이 여기서 실패한다 (02 apply 누락을 클러스터 생성 전에 잡는다).
# 그대로 진행되면 EKS 가 보존 기한·암호화 없는 그룹을 직접 만들고,
# 이후 02 apply 가 "이미 존재"로 실패하는 꼬임이 생긴다.
data "aws_cloudwatch_log_group" "eks_control_plane" {
  name = "/aws/eks/${var.cluster_name}/cluster"
}

module "eks" {
  # [3단계 파트 4] 레지스트리 태그(~> 21.0) 대신 커밋 SHA 로 고정 (Checkov CKV_TF_1)
  #   레지스트리 모듈도 실제로는 이 GitHub 저장소의 태그를 내려받는다 — 태그는 옮겨질 수 있다.
  #   액션을 SHA 로 고정한 이유(2026.3 trivy-action 태그 오염, build-deploy.yml P1-5)와 같은 원칙.
  #   고정 버전: v21.25.0 (로컬에서 쓰던 검증된 버전 — 아래 SHA 가 그 태그의 커밋)
  #   갱신: 새 버전 태그의 커밋 SHA 와 위 버전 표기를 함께 바꾸고 terraform init → plan 으로 차이 확인
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks.git?ref=48a429f63cf96361ea2f4b42677d0cc8a9a656e0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = local.vpc_id
  subnet_ids = local.private_subnet_ids # 노드는 프라이빗 서브넷에만

  # ── API 엔드포인트: 혼합 모드 (결정 #7) ─────────────────
  # Stage 1: public 은 내 IP /32 만 + private 활성
  # 후반 Stage: endpoint_public_access = false 로 완전 Private 전환
  endpoint_public_access       = true
  endpoint_public_access_cidrs = ["${var.my_ip}/32"]
  endpoint_private_access      = true

  # ── 인증: access entries (API 모드) ─────────────────────
  # aws-auth ConfigMap 시대 종료. Terraform 실행자(클러스터 생성자)를
  # admin access entry 로 자동 등록 → exec 인증(get-token)이 이걸로 통과
  # ⚠ Stage 6 에서 GitHub Actions OIDC 역할은 별도 access entry 필요 (메모)
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # ── 비용 가드레일: 표준 지원만 (extended = 시간당 6배) ──
  upgrade_policy = {
    support_type = "STANDARD"
  }

  # ── 노드 간(파드 간) 통신 허용 — cross-node 데이터플레인 ──
      # 모듈 기본 노드 SG 는 self-ingress 를 DNS(53)만 허용한다(공식 문서: 노드 간
      # 통신 규칙은 사용자가 추가). 그 결과 서로 다른 노드의 파드 간 통신이 전부
      # 차단되는데, 이는 Kubernetes 의 flat pod network 모델과 어긋난다.
      #
      # 보안 관점(중요): SG 는 "노드 단위"라 파드 수준 의도를 표현할 수 없다 —
      # 열면 전부 열리고 닫으면 전부 닫힌다. 따라서 L4 에서는 클러스터 기본 모델을
      # 복원하고, 파드 수준 선택적 통제는 Stage 3 NetworkPolicy 가 담당한다.
      # (north-south = SG(D19) / east-west = NetworkPolicy — 통제 분업 D22)
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

  # ── 컨트롤플레인 로깅: audit · authenticator (멘토 ⑤, 2026-10) ──
  # 이전 결정: 비활성 — 유일한 네이티브 목적지가 CloudWatch 라 S3-only 원칙과 충돌,
  #   탐지는 GuardDuty EKS Protection 이 audit 스트림을 직접 소비해 커버.
  # 바꾼 이유: 탐지는 되지만 Finding 을 조사할 원본(누가 어떤 API 를 불렀나)이 없었다.
  #   → CloudWatch 를 "CloudWatch 만 받을 수 있는 로그에 한해 단기 보관"으로 예외 허용.
  # 로그 그룹은 02-security 가 소유한다 (보존 14일, logs 키 암호화).
  #   모듈이 만들면 04 destroy 때 증적도 사라진다 → create_cloudwatch_log_group = false 유지.
  #   EKS 는 이름이 고정된 /aws/eks/<cluster>/cluster 에 쓰므로 02 의 그룹으로 들어간다.
  #   그룹이 없으면 EKS 가 보존·암호화 없이 직접 만들어 버린다 → 파일 위쪽 데이터 소스로 plan 에서 막는다.
  enabled_log_types           = ["audit", "authenticator"]
  create_cloudwatch_log_group = false

  # ── 시크릿 암호화: 모듈 KMS 키 생성 안 함 (키 churn 방지) ──
  # 모듈 기본값은 클러스터마다 CMK 자동 생성 → 세션 반복 destroy 마다
  # pending-deletion 키가 쌓임. EKS 는 기본으로 AWS-owned 키 봉투암호화를
  # 제공하므로 Stage 1 은 기본 암호화 사용.
  # (02 KMS 키로 시크릿 CMK 통합은 4B 후반 백로그 — Secrets CSI 와 한 세트 검토)
  # ⚠ plan 에서 encryption_config 타입 에러 시 {} ↔ null 로 교체해 볼 것
  create_kms_key    = false
  encryption_config = null

  # ── 애드온 ──────────────────────────────────────────────
  # before_compute = true: 노드그룹 생성 "전"에 애드온 등록
  #   → "노드가 CNI 없이 부팅 → NetworkPluginNotReady" 알려진 이슈 회피
  # eks-pod-identity-agent: LB Controller 자격증명 경로 (결정 #10)
  #   링크로컬 169.254.170.23 에서 자격증명 서빙 → IMDS 불필요
  #   → hop-limit=1 과 충돌 없음 ("파드는 IMDS 에 닿을 수 없고, 닿을 필요도 없다")
  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
      # Stage 2 (D8 구현): aws-node 를 노드롤이 아닌 전용 Pod Identity 자격으로.
      # 애드온 레벨 연결이라 애드온 업데이트로 in-place 반영 —
      # 단, 기존 aws-node 파드엔 소급 적용 안 됨 → 재기동 필수 (RUNBOOK Phase A)
      pod_identity_association = [
        {
          role_arn        = aws_iam_role.vpc_cni.arn
          service_account = "aws-node"
        }
      ]

      # Stage 3 (D22): native NetworkPolicy 활성화 — Calico 등 3P 미도입.
      #   컨트롤러는 EKS 컨트롤플레인, 집행은 노드의 network-policy-agent 가
      #   eBPF 로 커널 레벨 수행. "기능 활성화"일 뿐 정책은 별도
      #   (network-policy.tf 의 게이트) — 켜도 기본 동작은 전면 허용.
      # enablePolicyEventLogs: 노드 로컬 로그로 allow/deny 판정 추적.
      #   enableCloudWatchLogs 는 의도적 미설정 — CW 를 1차 로그 저장소로
      #   쓰지 않는 프로젝트 원칙 유지 (S3-only).
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

  # ── 매니지드 노드그룹 (결정 #6: 다이얼 1→2) ─────────────
  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      # ⚠ desired_size 는 "생성 시점에만" 반영됨 — 모듈이 생성 후 변경을
      #   ignore_changes 처리 (cluster-autoscaler 와의 충돌 방지 설계,
      #   모듈 이슈 #1879/#2151). 운영 중 스케일(Pause 0 / Stage 3 의 2)은
      #   Terraform 이 아니라 CLI 로: 런북 §4 "노드 스케일 운용" 참고.
      desired_size = var.node_desired_size

      # ── IMDS 하드닝 (관리형 클러스터 구조적 취약점 방어 1차) ──
      # http_tokens = required   : IMDSv2 강제 (SSRF 계열 완화)
      # hop_limit  = 1           : 노드 자신(1홉)만 IMDS 도달 가능
      #   → hostNetwork 가 아닌 파드(nginx, LB Controller)는 컨테이너
      #     네트워크 네임스페이스에서 +1 홉이라 응답이 도달 못함
      #   → "파드 → IMDS → 노드롤 크리덴셜 탈취 → AWS 장악" 체인 차단
      #   (aws-node/kube-proxy 는 hostNetwork 라 정상 동작)
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      # ── SG: 모듈 노드 SG + APP SG 병합 (D19) ───────────────
      # 모듈이 만드는 노드 SG 에 "추가"됨(교체 아님) — 커스텀 LT 의
      # network_interfaces.security_groups 에 concat 되는 구조.
      # 이유: ALB SG egress 가 APP SG 를 향하도록 01 에 설계돼 있어(EC2 전제),
      #   노드가 APP SG 를 함께 달아야 ALB→파드 경로가 열림 (3단계 파트 2 이후 :8080 — 01 alb_to_eks_pods).
      #   미부착 시 증상: 타깃 등록은 되는데 헬스체크 Target.Timeout.
      # ⚠ plan 에서 network_interfaces.security_groups 가 2개인지 확인할 것.
      #   1개(APP SG만)면 중단 — 노드↔컨트롤플레인 통신이 끊김.
      vpc_security_group_ids = [local.app_sg_id]

      # ── 노드 IAM: SSM Session Manager 접근 경로 ────────────
      # 프라이빗 노드에 SSH 없이 접속하는 운영 경로 (AL2023 = SSM 에이전트 내장).
      # 후반 완전 Private API 전환 시 kubectl 경유지(B-1 논의)의 기반이기도 함.
      iam_role_additional_policies = {
        ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }


      

      # ── Stage 2 게이트: 노드롤의 CNI 정책 (2단계 detach) ──
      # 모듈 기본값(true)은 AmazonEKS_CNI_Policy 를 노드롤에 자동 부착 —
      # S1 은 이를 암묵적으로 상속하고 있었음. Phase A(병존)에선 true 유지,
      # Phase B 에서 false 로 flip = 실제 detach (변수 설명·RUNBOOK 참고).
      iam_role_attach_cni_policy = var.cni_node_role_policy_attached

      # ── EBS: 02-security ebs CMK 암호화 (게이트 #1) ────────
      # kms_key_id 미지정 시 aws/ebs(AWS 관리키)로 암호화됨 — 자체 키로 지정해
      # 키 정책·회전·감사를 우리 통제 하에 둠 (보안 thesis 일관성).
      # ⚠ 하드 선행조건: ebs 키 정책에 ASG SLR(AWSServiceRoleForAutoScaling)
      #   위임이 있어야 함. 실제 인스턴스 생성 주체는 EKS 가 아니라 ASG 이고,
      #   ASG 는 SLR 자격으로 KMS grant 를 만들어 볼륨을 복호화함.
      #   누락 시 증상: 노드그룹 CREATE_FAILED 무한 반복, ASG Activity 에
      #   "Client.InternalError: Client error on launch" — 02-security-patch/ 선적용.
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
