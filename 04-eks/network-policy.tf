# ============================================================
# 04-eks/network-policy.tf — Pod 마이크로세그멘테이션 (Stage 3)
# ============================================================
# 엔진 결정(O2 해소 → D22): **VPC CNI native NetworkPolicy**
#   - 서드파티 CNI/컨트롤러 0개 추가 = "최소 표면" thesis 와 일관
#     (공급망 보안이 주제인 프로젝트에 새 컴포넌트를 들이는 아이러니 회피)
#   - 이미 IaC 로 관리 중인 vpc-cni 애드온의 토글이라 신규 생명주기 없음
#   - eBPF 커널 레벨 집행, 표준 k8s NetworkPolicy API (정책 자체는 이식 가능)
#   - t3.medium 1~2 노드 메모리 예산에 추가 파드 부담 0
#   ✗ Calico 미채택: 기능(GlobalNetworkPolicy·DNS 정책)은 풍부하나 S3 스코프에
#     불필요하고, 3P → native 전환은 in-place 마이그레이션 불가(단방향)
#
# 통제 분업 (AWS 권장 그대로):
#   north-south (ALB → 파드)  = Security Group  ← D19 에서 이미 구현
#   east-west   (파드 ↔ 파드) = NetworkPolicy   ← 이 파일
#
# ⚠ 전제: NetworkPolicy 는 **ownerReferences 가 있는 파드**에만 적용됨.
#   standalone bare Pod 은 정책 대상이 되지 않아 identity-test-workload.tf 의
#   데모 파드를 Deployment 로 전환함 (동시에 트러블슈팅 #7 개선도 달성).
# ============================================================

# ── 데모 클라이언트 (게이트와 무관하게 상시 존재) ─────────
# BEFORE 상태(정책 없음)를 캡처하려면 게이트를 켜기 "전"에 이미 떠 있어야 함
resource "kubernetes_deployment_v1" "netpol_client" {
  metadata {
    name      = "netpol-client"
    namespace = "default"
    labels    = { app = "netpol-client" }
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "netpol-client" }
    }
    template {
      metadata {
        labels = { app = "netpol-client" }
      }
      spec {
        # 교차 노드 실증(노드 2대 시): nginx 와 다른 노드에 배치되도록 유도.
        # preferred(soft) 이므로 노드 1대에서도 스케줄 실패하지 않음.
        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"
                label_selector {
                  match_labels = { app = "nginx" }
                }
              }
            }
          }
        }
        container {
          name    = "client"
          image   = "public.ecr.aws/docker/library/busybox:stable"
          command = ["sleep", "infinity"]
          resources {
            requests = { cpu = "10m", memory = "16Mi" }
            limits   = { memory = "64Mi" }
          }
        }
      }
    }
  }

  depends_on = [module.eks]
}

# ============================================================
# 정책 4종 — var.network_policy_enforcement 게이트
#   false: 생성 안 함 → 클러스터는 기본 전면 허용 (BEFORE 캡처용)
#   true : 생성 → default-deny + 명시 허용만 (AFTER)
#   ⚠ 애드온의 enableNetworkPolicy 는 게이트와 무관하게 항상 켬 —
#     "기능 활성화"와 "정책 집행"을 분리해야 BEFORE/AFTER 가 정책 차이만
#     반영한다 (에이전트 기동 여부가 변수로 섞이지 않음).
# ============================================================

# ── 허용 1: DNS (모든 파드 → CoreDNS) ─────────────────────
# default-deny egress 를 걸면 DNS 부터 끊겨 모든 것이 무너짐.
# 정책 실패의 압도적 1순위 원인이라 항상 제일 먼저 명시한다.
resource "kubernetes_network_policy_v1" "allow_dns" {
  count = var.network_policy_enforcement ? 1 : 0

  metadata {
    name      = "allow-dns-egress"
    namespace = "default"
  }

  spec {
    pod_selector {} # 네임스페이스 내 전체
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
        pod_selector {
          match_labels = { k8s-app = "kube-dns" }
        }
      }
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }
  }
}

# ── 허용 2: ALB → nginx (north-south 진입 경로 보존) ──────
# ipBlock 을 "퍼블릭 서브넷 CIDR"로 한정하는 이유:
#   ALB ENI 는 퍼블릭 서브넷에 있고, 파드/노드는 프라이빗 서브넷에 있다.
#   VPC CIDR 전체로 열면 모든 파드가 nginx 에 접근 가능해져
#   east-west 세그멘테이션(이 스테이지의 핵심)이 무력화된다.
#   → 정밀 스코프가 곧 데모 성립 조건.
# ⚠ kubelet readiness 프로브(노드 IP 발신)는 VPC CNI 가 자동 허용하지만,
#   만약 nginx 가 NotReady 로 떨어지면 STAGE3_RUNBOOK "폴백" 절 참고.
resource "kubernetes_network_policy_v1" "allow_alb_to_nginx" {
  count = var.network_policy_enforcement ? 1 : 0

  metadata {
    name      = "allow-alb-to-nginx"
    namespace = "default"
  }

  spec {
    pod_selector {
      match_labels = { app = "nginx" }
    }
    policy_types = ["Ingress"]

    dynamic "ingress" {
      for_each = [1]
      content {
        dynamic "from" {
          for_each = local.public_subnet_cidrs
          content {
            ip_block {
              cidr = from.value
            }
          }
        }
        ports {
          port     = "80"
          protocol = "TCP"
        }
      }
    }
  }
}

# ── 허용 3: identity-granted egress (Pod Identity + AWS API) ──
# 이 스테이지의 하이라이트 — 두 링크로컬 주소의 상반된 보안 지위를 코드로 표현:
#   169.254.170.23  = Pod Identity 에이전트 → **인가된** 자격증명 경로 (허용)
#   169.254.169.254 = EC2 IMDS            → **탈취 표적** (except 로 명시 차단)
# IMDS 는 이미 hop-limit=1(S1)로 경로가 막혀 있으나, 여기서 한 번 더
# 명시적으로 배제해 "의도된 차단"을 코드에 드러낸다 (겹방어 + 감사 가시성).
resource "kubernetes_network_policy_v1" "allow_identity_demo_egress" {
  count = var.network_policy_enforcement ? 1 : 0

  metadata {
    name      = "allow-identity-demo-egress"
    namespace = "default"
  }

  spec {
    pod_selector {
      match_labels = { role = "granted" }
    }
    policy_types = ["Egress"]

    # (a) Pod Identity 에이전트 — 자격증명 취득
    egress {
      to {
        ip_block {
          cidr = "169.254.170.23/32"
        }
      }
      ports {
        port     = "80"
        protocol = "TCP"
      }
    }

    # (b) AWS API (S3, NAT 경유) — IMDS 만 도려냄
    egress {
      to {
        ip_block {
          cidr   = "0.0.0.0/0"
          except = ["169.254.169.254/32"]
        }
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }
}

# ── default-deny (마지막에 적용) ──────────────────────────
# depends_on 으로 허용 정책들이 "먼저" 존재하게 강제.
# 순서가 뒤집히면 단일 apply 안에서도 수 초간 전면 차단 구간이 생겨
# ALB 헬스체크가 실패할 수 있다 (사이트 영향).
resource "kubernetes_network_policy_v1" "default_deny" {
  count = var.network_policy_enforcement ? 1 : 0

  metadata {
    name      = "default-deny-all"
    namespace = "default"
  }

  spec {
    pod_selector {} # 네임스페이스 내 전체
    # ingress/egress 블록을 비워두면 = 전면 거부
    policy_types = ["Ingress", "Egress"]
  }

  depends_on = [
    kubernetes_network_policy_v1.allow_dns,
    kubernetes_network_policy_v1.allow_alb_to_nginx,
    kubernetes_network_policy_v1.allow_identity_demo_egress,
  ]
}
