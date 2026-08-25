# ============================================================
# 05-k8s/workload.tf — Walking Skeleton 워크로드 (nginx + TGB)
# ============================================================
#
# 리소스 타입 배분 원칙 (B-1):
#   Deployment/Service = typed kubernetes 리소스 (스키마 안정, 깔끔한 diff)
#   TargetGroupBinding = kubectl_manifest (유일한 CRD —
#     HashiCorp kubernetes_manifest 는 plan 시점 CRD 요구로 fresh apply 불가)
#
# Stage 6 에서 이 워크로드 관리는 GitHub Actions 파이프라인으로 이관 예정
# ============================================================

# ── 검증 차별화 페이지 (U3 대응) ──────────────────────────
# EC2 스켈레톤도 기본 nginx 페이지라, 컷오버 후 브라우저에 기본 페이지가
# 떠도 "어느 쪽이 응답했는지" 증명 불가. EKS 쪽 index 를 차별화해
# ④ weight 전환의 성공/롤백을 눈으로 판정 가능하게 만듦.
# ($hostname 은 nginx SSI 없이는 동적 삽입이 번거로워 정적 텍스트로 충분 —
#  파드 단위 식별은 kubectl logs 의 액세스 로그로)
resource "kubernetes_config_map_v1" "nginx_index" {
  metadata {
    name      = "nginx-index"
    namespace = "default"
  }

  data = {
    "index.html" = <<-HTML
      <!DOCTYPE html>
      <html>
      <head><title>EKS Walking Skeleton</title></head>
      <body style="font-family: monospace; background:#0b1120; color:#7dd3fc; padding:3rem;">
        <h1>Served from EKS — Phase 4B Stage 1</h1>
        <p>nginx pod behind existing ALB (Okta OIDC + X-Origin-Verify + WAF + CloudFront preserved)</p>
      </body>
      </html>
    HTML
  }
}

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
          image = "public.ecr.aws/docker/library/nginx:stable-alpine"

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

          # ConfigMap index 마운트 — /usr/share/nginx/html 전체가
          # ConfigMap 내용(index.html)으로 대체됨. 헬스체크 "/" 도 이 페이지로 200.
          volume_mount {
            name       = "index-html"
            mount_path = "/usr/share/nginx/html"
            read_only  = true
          }
        }

        volume {
          name = "index-html"
          config_map {
            name = kubernetes_config_map_v1.nginx_index.metadata[0].name
          }
        }
      }
    }
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
