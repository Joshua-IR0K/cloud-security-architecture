# NetworkPolicy는 ownerReferences가 있는 파드에만 걸린다. 그래서 데모 파드도 Deployment로 만든다(identity-demo.tf).
# app에는 DNS 허용도 안 둔다. 정적 웹서버라 이름 풀 일도 밖으로 나갈 일도 없다.

# 데모 클라이언트. 정책 없는 상태도 캡처할 수 있게 게이트 값과 상관없이 항상 띄운다.
resource "kubernetes_deployment_v1" "netpol_client" {
  #checkov:skip=CKV_K8S_8,CKV_K8S_9,CKV_K8S_11,CKV_K8S_15,CKV_K8S_21,CKV_K8S_28,CKV_K8S_29,CKV_K8S_30,CKV_K8S_43:S3 실증 픽스처 — busybox sleep 클라이언트(서버 프로세스 없음)·공용 이미지 태그·default 네임스페이스·기본 securityContext 를 의도적으로 유지. 하드닝 기준은 운영 nginx(app)에 적용·검증
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
        # nginx와 다른 노드에 뜨도록 유도만 한다(soft). 노드가 1대여도 스케줄은 된다.
        # 같은 노드든 다른 노드든 다 막혀야 정상이다. 정책은 출발 노드와 상관없이 목적지 파드 쪽에서 걸린다.
        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"
                # 기준 파드(nginx)는 app 네임스페이스에 있다
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

# 정책 5개(default 3, app 2). var.network_policy_enforcement가 false면 안 만든다(정책 전/후 비교용).
# 애드온의 enableNetworkPolicy는 게이트와 상관없이 항상 켠다. 그래야 비교 결과에 정책 유무 차이만 남는다.

# DNS 허용. egress를 기본 차단하면 DNS부터 끊긴다.
resource "kubernetes_network_policy_v1" "allow_dns" {
  count = var.network_policy_enforcement ? 1 : 0

  metadata {
    name      = "allow-dns-egress"
    namespace = "default"
  }

  spec {
    pod_selector {} # 네임스페이스 안 파드 전부
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

# ALB에서 nginx(app)로. 출발지는 ALB ENI가 있는 퍼블릭 서브넷 CIDR로만 연다. VPC 전체로 열면 아무 파드나 nginx에 붙을 수 있다.
# 포트는 서비스 포트가 아니라 파드가 실제로 듣는 8080이다. kubelet 프로브(노드 IP에서 옴)는 VPC CNI가 알아서 허용한다.
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

# identity-granted egress. Pod Identity 에이전트(169.254.170.23)는 열고, IMDS(169.254.169.254)는 except로 콕 집어 막는다.
# IMDS는 hop limit 1로 이미 막혀 있지만, 일부러 막았다는 걸 코드에 남겨 둔다.
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

    # (a) Pod Identity 에이전트. 여기서 자격증명을 받는다.
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

    # (b) AWS API(S3, NAT 경유). IMDS만 빼고 연다.
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

# 기본 차단은 허용 정책이 다 생긴 다음에 건다(depends_on). 순서가 뒤집히면 몇 초 동안 전부 막혀서 ALB 헬스체크가 실패할 수 있다.
resource "kubernetes_network_policy_v1" "default_deny" {
  count = var.network_policy_enforcement ? 1 : 0

  metadata {
    name      = "default-deny-all"
    namespace = "default"
  }

  spec {
    pod_selector {} # 네임스페이스 안 파드 전부
    # ingress/egress 블록을 비워 두면 전부 거부된다.
    policy_types = ["Ingress", "Egress"]
  }

  depends_on = [
    kubernetes_network_policy_v1.allow_dns,
    kubernetes_network_policy_v1.allow_identity_demo_egress,
  ]
}

# app 기본 차단(ingress·egress). egress 허용이 없으니 nginx가 먼저 연결을 열 수는 없다. 응답은 상태 기반이라 허용된 인바운드에 대해서만 나간다.
resource "kubernetes_network_policy_v1" "app_default_deny" {
  count = var.network_policy_enforcement ? 1 : 0

  metadata {
    name      = "default-deny-all"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  spec {
    pod_selector {} # 네임스페이스 안 파드 전부
    policy_types = ["Ingress", "Egress"]
  }

  depends_on = [
    kubernetes_network_policy_v1.allow_alb_to_nginx,
  ]
}

# 시크릿 데모 파드용 egress 정책은 따로 없다. 시크릿은 CSI 드라이버와 ASCP가 노드 레벨에서 받아와 tmpfs로 넣어준다.
# 그래서 앱 파드가 AWS에 아예 못 나가도 시크릿 파일은 마운트된다. 앱이 뚫리더라도 시크릿을 뒤지거나 빼낼 네트워크가 없다.
