# ============================================================
# 05-k8s/workload.tf — 워크로드 (nginx + TGB)
# ============================================================
#
# 리소스 타입 배분 원칙 (B-1):
#   Deployment/Service = typed kubernetes 리소스 (스키마 안정, 깔끔한 diff)
#   TargetGroupBinding = kubectl_manifest (유일한 CRD —
#     HashiCorp kubernetes_manifest 는 plan 시점 CRD 요구로 fresh apply 불가)
#
# 소유권 (D42 Delegated Field Ownership) — "이관"이 아니다:
#   Terraform : 이 Deployment 의 구조·보안 전체를 계속 소유
#               (replica·probe·볼륨·SA·securityContext·Service·TGB)
#   CI        : 컨테이너 image 필드 **하나만** 위임받음(ignore_changes)
#   → 워크로드 전체가 파이프라인으로 넘어가는 것이 아니다.
#
# [3단계 파트 2] 파드 보안 하드닝 (위협모델 G4·G6)
#   · app 네임스페이스로 이동 — PSA restricted 가 강제되는 곳 (namespace.tf)
#   · 비루트(UID 101) · 권한 상승 금지 · capabilities 전부 제거 · seccomp RuntimeDefault
#   · 루트 파일시스템 읽기 전용 — nginx 가 쓰는 곳(/tmp: pid·임시 파일)만 emptyDir 로 연다
#   · SA 토큰 미마운트 — nginx 는 쿠버네티스 API 를 부를 일이 없다
#   · 포트 8080 — 파트 1 의 nginx-unprivileged 는 1024 미만 포트를 쓰지 않는다
#   이 조합은 PSA restricted 요구사항과 1:1 이다 — 하나라도 빠지면 app 에서 파드가 거부된다.
# ============================================================

locals {
  # 생성 시점 기준 이미지 (D43) — tag 는 사람이 읽는 이름, digest 가 실제 내용
  app_image = "${local.ecr_repository_url}:${var.app_image_tag}@${var.app_image_digest}"
  app_uid   = "101" # nginx-unprivileged 의 nginx 사용자 (images/s5-good/Dockerfile USER 101)
}

# ⚠ nginx_index ConfigMap 제거 (P1-6)
#   ConfigMap 이 /usr/share/nginx/html 을 마운트하면 이미지가 가진 콘텐츠를
#   통째로 가린다. 그러면 HTTPS 응답으로 "어느 커밋의 이미지가 도는지"를
#   확인할 수 없어 E2E 증거 사슬이 끊긴다.
#     Docker Image → application artifact  (콘텐츠 소유)
#     ConfigMap    → runtime configuration (필요해지면 conf.d 에 마운트)
#   S1~S5 에서 이 ConfigMap 이 하던 "Served from EKS" 차별화 역할은
#   이제 이미지 안의 index.html(빌드 SHA 포함)이 대신한다.

resource "kubernetes_deployment_v1" "nginx" {
  metadata {
    name      = "nginx"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels = {
      app = "nginx"
    }
  }

  spec {
    replicas = 2 # 노드 1대 위 2 레플리카 (TG 다중 타깃 확인용)

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

        container {
          name = "nginx"
          # 이미지 이력: Stage 1 공용 이미지(가변 태그) → Stage 5 우리 ECR(IMMUTABLE 태그)
          #   → 3단계 tag@digest (서명 검증은 S7). 노드롤의 AmazonEC2ContainerRegistryReadOnly 로
          #   pull 한다 (추가 IAM 없음 — S2 detach 때 보존된 권한).
          # 생성 시점 기준 이미지(D43) — 이후 이미지는 CI 가 롤아웃한다(D42, 아래 lifecycle).
          #   ⚠ 파트 1 의 비루트 이미지여야 한다 — 이전 이미지(root 실행)는 아래 securityContext 와
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

          readiness_probe {
            http_get {
              path = "/"
              port = "http"
            }
            initial_delay_seconds = 3
            period_seconds        = 5
          }

          # 읽기 전용 루트에서 nginx 가 쓰는 유일한 곳 (pid · 임시 파일 — 파트 1 베이스가 /tmp 로 옮겨 둠)
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

  # ── Delegated Field Ownership (D42) ───────────────────────
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
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].container[0].image
    ]
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

# ── TargetGroupBinding ────────────────────────────────────
# 03-workload 의 EKS 타깃그룹(weight 0 으로 리스너에 이미 연결됨)에
# nginx Service 의 파드 IP 들을 바인딩
# networking.ingress: LB Controller 가 노드/파드 SG 에
#   "ALB SG 발신 → TCP/8080" 인그레스 규칙을 자동 생성 (최소 개방)
#   [3단계 파트 2] 포트는 서비스 포트(80)가 아니라 파드가 실제로 듣는 포트(8080)다.
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

  # CRD(helm 설치) + Service 존재 후 적용 — B-1 사슬의 마지막 고리
  depends_on = [
    helm_release.aws_lb_controller,
    kubernetes_service_v1.nginx,
  ]
}
