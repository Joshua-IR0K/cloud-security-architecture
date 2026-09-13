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
# ============================================================

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
    namespace = "default"
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
        container {
          name = "nginx"
          # 가변 태그 사용은 Stage 1 한정 (공식 이미지, 존재 보장 목적)
          # → Stage 5(ECR)부터 자체 빌드 이미지, Stage 7 에서
          #   digest 고정 + cosign 서명 검증으로 대체 (로드맵 확정)
          # ECR Public 미러 사용 이유: Docker Hub 익명 pull 은 IP 당
          # rate limit — 모든 pull 이 단일 NAT IP 로 나가는 이 구조에서
          # destroy/apply 사이클 반복 시 ImagePullBackOff 로 발현될 수
          # 있는 노출면. ECR Public 은 AWS 발신 트래픽에 관대함.
          # Stage 5: 공용 레지스트리 → 우리 ECR
          #   노드롤에 AmazonEC2ContainerRegistryReadOnly 가 이미 있어
          #   추가 IAM 작업 없이 pull 가능 (S2 detach 때 보존된 권한).
          #   ⚠ 리포지토리가 IMMUTABLE — 재빌드 시 새 태그 + var 갱신 필요.
          #   S7 에서 digest 핀 + cosign 서명 검증으로 대체.
          # ★ S7: 태그가 아니라 digest 참조 (D43 갱신)
          #   정책의 verifyDigest=true 가 태그 참조를 거부하므로 baseline 도 digest 여야 한다.
          #   "태그는 이름, digest 가 신원" — S5 IMMUTABLE 실증의 연장.
          image = "${local.ecr_repository_url}@${var.app_image_digest}"

          port {
            container_port = 80
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
              port = 80
            }
            initial_delay_seconds = 3
            period_seconds        = 5
          }

        }

      }
    }
  }

  # ── ★ P0: 정책이 먼저 존재해야 한다 (S7) ─────────────────
  # fresh apply 에서 Deployment 가 정책보다 먼저 생성되면 baseline 파드가
  # **검증 없이 admission 을 통과**한다. background 평가를 껐으므로
  # 사후 재검증도 되지 않아, 검증된 적 없는 이미지가 조용히 도는 상태가 된다.
  # → 실패보다 나쁘다(잘못된 안전감). 명시적 순서로 막는다.
  depends_on = [
    kubectl_manifest.nginx_image_source_guard,
    kubectl_manifest.image_verification,
  ]

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
  #   ⚠ 단 "생성" 시점에는 config 가 적용된다 → var.app_image_digest 의 baseline 의미(D43)
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].container[0].image
    ]
  }
}

resource "kubernetes_service_v1" "nginx" {
  metadata {
    name      = "nginx"
    namespace = "default"
  }

  spec {
    selector = {
      app = "nginx"
    }

    port {
      port        = 80
      target_port = 80
      protocol    = "TCP"
    }

    type = "ClusterIP" # 외부 노출은 ALB(TGB)가 담당 — LoadBalancer 타입 불필요
  }
}

# ── TargetGroupBinding ────────────────────────────────────
# 03-workload 의 EKS 타깃그룹(weight 0 으로 리스너에 이미 연결됨)에
# nginx Service 의 파드 IP 들을 바인딩
# networking.ingress: LB Controller 가 노드/파드 SG 에
#   "ALB SG 발신 → TCP/80" 인그레스 규칙을 자동 생성 (최소 개방)
resource "kubectl_manifest" "nginx_tgb" {
  yaml_body = <<-YAML
    apiVersion: elbv2.k8s.aws/v1beta1
    kind: TargetGroupBinding
    metadata:
      name: nginx-tgb
      namespace: default
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
                port: 80
  YAML

  # CRD(helm 설치) + Service 존재 후 적용 — B-1 사슬의 마지막 고리
  depends_on = [
    helm_release.aws_lb_controller,
    kubernetes_service_v1.nginx,
  ]
}
