# ============================================================
# 05-k8s/network-policy.tf — Pod 마이크로세그멘테이션 (Stage 3)
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
#
# [3단계 파트 2] 네임스페이스별 정책 세트
#   NetworkPolicy 는 네임스페이스 범위다 — nginx 가 app 으로 옮겨 가면서 정책도 나뉜다.
#     default (실증 데모)   : DNS 허용 · identity 데모 egress · default-deny
#     app     (운영 워크로드): ALB → nginx:8080 허용 · default-deny (egress 는 전부 차단)
#   app 에는 DNS 허용도 두지 않는다 — 정적 웹서버는 이름 해석도 외부 호출도 필요 없다.
#   east-west 실증(S3)은 이제 네임스페이스를 넘는다: default 의 client → app 의 nginx = 차단.
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
        # [3단계 파트 3] nginx 가 노드마다 흩어지면(topologySpread) 피할 노드가 없어 nginx 1개와
        #   같은 노드에 놓인다. Service 호출은 두 파드 중 하나로 가므로 동일 노드·교차 노드 모두
        #   차단돼야 정상이다 (정책은 출발 노드와 무관하게 목적지 파드에서 집행된다).
        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"
                # [3단계 파트 2] nginx 가 app 으로 옮겨 갔다 — 기준 파드를 그 네임스페이스에서 찾는다
                namespaces = [kubernetes_namespace_v1.app.metadata[0].name]
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
}

# ============================================================
# 정책 5종 (default 3 · app 2) — var.network_policy_enforcement 게이트
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

# ── 허용 2: ALB → nginx (north-south 진입 경로 보존) — app 네임스페이스 ──
# ipBlock 을 "퍼블릭 서브넷 CIDR"로 한정하는 이유:
#   ALB ENI 는 퍼블릭 서브넷에 있고, 파드/노드는 프라이빗 서브넷에 있다.
#   VPC CIDR 전체로 열면 모든 파드가 nginx 에 접근 가능해져
#   east-west 세그멘테이션(이 스테이지의 핵심)이 무력화된다.
#   → 정밀 스코프가 곧 데모 성립 조건.
# ⚠ kubelet readiness 프로브(노드 IP 발신)는 VPC CNI 가 자동 허용하지만,
#   만약 nginx 가 NotReady 로 떨어지면 STAGE3_RUNBOOK "폴백" 절 참고.
# [3단계 파트 2] 포트 80 → 8080: 정책은 서비스 포트가 아니라 파드가 실제로 듣는 포트에 건다.
resource "kubernetes_network_policy_v1" "allow_alb_to_nginx" {
  count = var.network_policy_enforcement ? 1 : 0

  metadata {
    name      = "allow-alb-to-nginx"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
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
          port     = "8080"
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
    kubernetes_network_policy_v1.allow_identity_demo_egress,
  ]
}

# ── app 네임스페이스 default-deny (ingress·egress 모두) ──
# 같은 원칙: 허용(ALB → nginx)이 먼저 존재한 뒤 마지막에 건다.
# egress 허용이 하나도 없다 = nginx 는 어디로도 연결을 시작할 수 없다
#   (응답 트래픽은 NetworkPolicy 가 상태 기반이라 허용된 인바운드에 한해 나간다).
resource "kubernetes_network_policy_v1" "app_default_deny" {
  count = var.network_policy_enforcement ? 1 : 0

  metadata {
    name      = "default-deny-all"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  spec {
    pod_selector {} # 네임스페이스 내 전체
    policy_types = ["Ingress", "Egress"]
  }

  depends_on = [
    kubernetes_network_policy_v1.allow_alb_to_nginx,
  ]
}

# ============================================================
# Stage 4 — 전용 egress 정책을 "두지 않는다" (의도적 부재)
# ============================================================
# 초안에는 s4 파드용 AWS API egress 정책이 있었으나 제거했다.
#
# 근거: 앱 파드가 AWS API 로 나갈 이유가 없다.
#   시크릿은 kube-system 의 CSI 드라이버/ASCP 가 노드 레벨에서 가져와
#   tmpfs 로 전달한다 — 앱의 네트워크 경로와 무관하다.
#   실증 편의(다른 시크릿 조회 테스트)를 위해 egress 를 여는 것은
#   최소권한을 데모에 종속시키는 것이라 본말전도.
#
# 그 결과 더 강한 실증이 가능해진다:
#   "앱 파드는 AWS 에 전혀 도달할 수 없는데(default-deny),
#    시크릿 파일은 마운트돼 있다"
#   → 침해된 앱이 시크릿을 열거·유출하려 해도 네트워크가 없다.
#   → 전달 경로와 앱 경로의 아키텍처적 분리 실증 (머니샷)
# ============================================================
