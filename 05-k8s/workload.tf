# 리소스 타입 배분 원칙:
#   Deployment/Service = typed kubernetes 리소스 (스키마 안정, 깔끔한 diff)
#   TargetGroupBinding = kubectl_manifest (유일한 CRD —
#     HashiCorp kubernetes_manifest 는 plan 시점 CRD 요구로 fresh apply 불가)
#
# 파드 보안 설정(비루트·권한 상승 금지·capabilities 제거·seccomp·읽기 전용 루트·SA 토큰 미마운트)은
#   PSA restricted 요구사항과 1:1 이다 — 하나라도 빠지면 app 에서 파드가 거부된다.
#
# 가용성 — "파드가 언제 사라지는가"마다 통제 하나씩
#   · 배포로 교체될 때          → RollingUpdate maxSurge 1 / maxUnavailable 0 (Ready 2개 유지)
#   · 노드·AZ 가 사라질 때       → topologySpreadConstraints (AZ·노드 분산, soft)
#   · 프로세스가 응답을 멈출 때  → livenessProbe 로 재시작 (readiness 보다 느슨하게)
#   · 드레인·노드 교체(자발적)   → PodDisruptionBudget minAvailable 1

locals {
  # 생성 시점 기준 이미지 — tag 는 사람이 읽는 이름, digest 가 실제 내용
  app_image = "${local.ecr_repository_url}:${var.app_image_tag}@${var.app_image_digest}"
  app_uid   = "101" # nginx-unprivileged 의 nginx 사용자 (images/s5-good/Dockerfile USER 101)
}

# ⚠ html 을 ConfigMap 으로 마운트하지 않는다
#   ConfigMap 이 /usr/share/nginx/html 을 마운트하면 이미지가 가진 콘텐츠를
#   통째로 가린다. 그러면 HTTPS 응답으로 "어느 커밋의 이미지가 도는지"를
#   확인할 수 없어 E2E 증거 사슬이 끊긴다.
#     Docker Image → application artifact  (콘텐츠 소유)
#     ConfigMap    → runtime configuration (필요해지면 conf.d 에 마운트)

resource "kubernetes_deployment_v1" "nginx" {
  metadata {
    name      = "nginx"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels = {
      app = "nginx"
    }
  }

  spec {
    replicas = 2 # TG 다중 타깃 확인 + PDB(minAvailable 1)와 짝 — 한 번에 1개까지만 내려간다

    # 롤아웃 중에도 Ready 파드 2개 유지 — 새 파드가 Ready 가 된 뒤에 기존 파드를 내린다.
    #   2 레플리카에서는 기본값(25%)도 결과가 같지만(올림 1 / 내림 0) 의도를 코드에 고정한다
    #   — 레플리카를 늘려도 "롤아웃 중 가용 감소 0" 이 유지된다. CI 롤아웃(set image)도 이 규칙을 따른다.
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "1"
        max_unavailable = "0"
      }
    }

    selector {
      match_labels = {
        app = "nginx"
      }
    }

    template {
      metadata {
        labels = {
          app = "nginx"
        }
      }

      spec {
        # SA 토큰 미마운트 — nginx 는 쿠버네티스 API 를 부르지 않는다 (탈취돼도 쓸 토큰이 없다)
        automount_service_account_token = false

        # 파드 수준 — PSA restricted 요구사항 (비루트 · seccomp)
        security_context {
          run_as_non_root = true
          run_as_user     = local.app_uid
          run_as_group    = local.app_uid
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        # AZ·노드 분산 — soft(ScheduleAnyway)
        #   노드가 1대면 두 파드가 같은 노드에 뜨고(스케줄을 막지 않음), 2대 이상이면 흩어 놓는다.
        #   hard(DoNotSchedule)로 하면 노드 1대·AZ 1개일 때 두 번째 파드가 Pending 이 된다.
        #   zone = AZ 장애 대비, hostname = 노드 장애·교체 대비 (같은 AZ 에 노드가 여럿일 때).
        #   match_label_keys = pod-template-hash: 롤아웃 중 옛 파드와 새 파드를 섞어 세지 않고
        #   새 리비전끼리만 균형을 맞춘다 (섞어 세면 롤아웃이 끝난 뒤 한쪽으로 몰릴 수 있다).
        #   ⚠ 스케줄 시점에만 적용 — 이미 떠 있는 파드를 옮기지 않는다. 노드를 늘린 뒤에는 다음 롤아웃 때 흩어진다.
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"
          match_label_keys   = ["pod-template-hash"]
          label_selector {
            match_labels = { app = "nginx" }
          }
        }

        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          match_label_keys   = ["pod-template-hash"]
          label_selector {
            match_labels = { app = "nginx" }
          }
        }

        container {
          name = "nginx"
          # 노드롤의 AmazonEC2ContainerRegistryReadOnly 로 pull 한다 (추가 IAM 없음 — S2 detach 때 보존된 권한).
          # 생성 시점 기준 이미지 — 이후 이미지는 CI 가 롤아웃한다 (아래 lifecycle).
          #   ⚠ 비루트 이미지여야 한다 — root 로 실행되는 이미지는 아래 securityContext 와
          #     PSA restricted 에 거부되어 파드가 뜨지 않는다.
          image = local.app_image

          port {
            name           = "http"
            container_port = 8080 # nginx-unprivileged — 1024 미만 포트 바인딩 권한이 필요 없다
          }

          # 컨테이너 수준 — PSA restricted 요구사항 + 읽기 전용 루트
          security_context {
            allow_privilege_escalation = false
            privileged                 = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            capabilities {
              drop = ["ALL"]
            }
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "128Mi"
            }
          }

          # readiness — "지금 트래픽을 받아도 되는가". 실패하면 재시작 없이 Service·ALB 대상에서만 빠진다.
          readiness_probe {
            http_get {
              path = "/"
              port = "http"
            }
            initial_delay_seconds = 3
            period_seconds        = 5
          }

          # liveness — "살아 있는가". 응답이 멈췄으면 컨테이너를 재시작한다.
          #   readiness 보다 느슨하게: 10초 주기 × 3회 = 약 30초 연속 실패할 때만 재시작.
          #   더 공격적이면 순간 부하에도 재시작이 이어져(재시작 폭풍) 오히려 가용성을 떨어뜨린다.
          #   "/" 는 외부 의존이 없는 정적 페이지라 liveness 로 써도 안전하다
          #   (DB·외부 API 를 확인하는 liveness 는 의존 대상 장애를 전 파드 재시작으로 키운다 — 금물).
          liveness_probe {
            http_get {
              path = "/"
              port = "http"
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 2
            failure_threshold     = 3
          }

          # 읽기 전용 루트에서 nginx 가 쓰는 유일한 곳 (pid · 임시 파일 — 베이스 이미지가 /tmp 로 옮겨 둠)
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        volume {
          name = "tmp"
          empty_dir {
            size_limit = "16Mi"
          }
        }
      }
    }
  }

  # Delegated Field Ownership (D42)
  # 컨테이너 이미지 필드의 소유권을 CI 에 명시적으로 위임한다.
  #
  # 왜 필요한가:
  #   CI 가 05 전체를 terraform apply 하면
  #     ① Helm release state(kube-system Secret) 읽기 권한이 필요해지고
  #     ② tfvars 누락 시 NetworkPolicy 등 보안 통제를 파괴할 수 있다
  #   → 배포 하나를 위해 플랫폼/보안 통제의 소유권을 CI 에 넘기는 셈.
  #
  # 대신 Terraform 은 Deployment 의 "구조와 보안"(replica·probe·볼륨·SA·
  # securityContext)을 계속 소유하고, CI 는 "실행할 아티팩트"(image) 하나만
  # 소유한다. CI 의 K8s 권한은 이 Deployment 의 get/patch 로 축소된다.
  #
  # 이것은 drift 방치가 아니다:
  #   drift = 코드에 없는 변경이 조용히 발생하는 것
  #   위임 = 어느 필드를 누가 소유하는지 코드에 선언하는 것
  #   → "코드에 없으면 존재하지 않는다"의 예외가 아니라, 예외 자체가 코드에 있다.
  #   → 프로젝트 내 두 번째 적용: EKS 모듈이 같은 이유로 desired_size 를
  #     ignore 하고 우리가 그것을 D6 로 수용했다.
  #
  # 동작 메커니즘:
  #   refresh 가 실제 값(CI 가 설정한 이미지)을 state 로 읽고,
  #   plan 은 ignore 대상에 config 대신 prior state 를 쓴다
  #   → Terraform 이 다른 필드를 고쳐도 CI 의 이미지는 유지된다.
  #   ⚠ 단 "생성" 시점에는 config 가 적용된다 → var.app_image_tag 의 baseline 의미(D43)
  #   ⚠ kubectl rollout restart 는 쓰지 않는다 — 파드 템플릿에 restartedAt 주석을 넣어 plan 에
  #     drift 가 생긴다 (위임 범위는 image 하나뿐). 재시작이 필요하면 CI 재실행(set image) 또는
  #     terraform apply 로 한다. (3단계 파트 3 로컬 검증에서 확인)
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].container[0].image
    ]
  }
}

# PodDisruptionBudget
# 드레인·노드 교체 같은 "자발적 중단" 때 nginx 가 한꺼번에 사라지지 않게 한다.
#   minAvailable 1 + replicas 2 = 한 번에 1개까지만 퇴거(evict) 허용.
#   노드가 1대일 때 그 노드를 드레인하면: 첫 파드는 퇴거되고, 두 번째는 PDB 가 막는다
#   (퇴거된 파드가 갈 노드가 없어 Ready 가 1개 → 마지막 1개를 끝까지 지킨다).
# PDB 가 관여하지 않는 것 (오해 주의):
#   · CI 롤아웃(set image) — 퇴거가 아니라 Deployment 교체다 (위 strategy 가 담당)
#   · terraform destroy — Deployment 삭제는 퇴거가 아니다 (05 → 04 순서라 노드그룹 삭제도 막지 않는다)
#   · 노드 장애·OOM — 비자발적 중단은 PDB 대상이 아니다 (위 topologySpread 가 담당)
# ⚠ unhealthyPodEvictionPolicy(AlwaysAllow)는 이 프로바이더(kubernetes 3.2.x)의 PDB 리소스가
#   지원하지 않아 기본값(IfHealthyBudget)이다 — 고장 난 파드가 섞이면 드레인이 막힐 수 있다.
resource "kubernetes_pod_disruption_budget_v1" "nginx" {
  metadata {
    name      = "nginx"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  spec {
    min_available = "1"
    selector {
      match_labels = { app = "nginx" }
    }
  }
}

resource "kubernetes_service_v1" "nginx" {
  metadata {
    name      = "nginx"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  spec {
    selector = {
      app = "nginx"
    }

    port {
      port        = 80     # 서비스 포트는 그대로 — 클러스터 안에서는 http://nginx.app 으로 부른다
      target_port = "http" # 컨테이너의 이름 붙은 포트(8080)를 가리킨다
      protocol    = "TCP"
    }

    type = "ClusterIP" # 외부 노출은 ALB(TGB)가 담당 — LoadBalancer 타입 불필요
  }
}

# TargetGroupBinding
# 03-workload 의 EKS 타깃그룹(weight 0 으로 리스너에 이미 연결됨)에
# nginx Service 의 파드 IP 들을 바인딩
# networking.ingress: LB Controller 가 노드/파드 SG 에
#   "ALB SG 발신 → TCP/8080" 인그레스 규칙을 자동 생성 (최소 개방)
#   포트는 서비스 포트(80)가 아니라 파드가 실제로 듣는 포트(8080)다.
#   ALB 쪽 egress 는 01 의 alb_to_eks_pods 규칙이 연다.
resource "kubectl_manifest" "nginx_tgb" {
  yaml_body = <<-YAML
    apiVersion: elbv2.k8s.aws/v1beta1
    kind: TargetGroupBinding
    metadata:
      name: nginx-tgb
      namespace: ${kubernetes_namespace_v1.app.metadata[0].name}
    spec:
      serviceRef:
        name: nginx
        port: 80
      targetGroupARN: ${local.eks_tg_arn}
      targetType: ip
      networking:
        ingress:
          - from:
              - securityGroup:
                  groupID: ${local.alb_sg_id}
            ports:
              - protocol: TCP
                port: 8080
  YAML

  # CRD(helm 설치) + Service 존재 후 적용
  depends_on = [
    helm_release.aws_lb_controller,
    kubernetes_service_v1.nginx,
  ]
}
