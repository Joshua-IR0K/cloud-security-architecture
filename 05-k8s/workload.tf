# ============================================================
# 05-k8s/workload.tf — 워크로드 (nginx + TGB)
# ============================================================
#
# 리소스 타입 배분 원칙 (B-1):
#   Deployment/Service = typed kubernetes 리소스 (스키마 안정, 깔끔한 diff)
#   TargetGroupBinding = kubectl_manifest (유일한 CRD —
#     HashiCorp kubernetes_manifest 는 plan 시점 CRD 요구로 fresh apply 불가)
#
# Stage 5 소유권:
#   Terraform 이 Deployment 전체(컨테이너 image 포함)를 계속 소유한다.
#   사람이 로컬 골든패스로 만든 ECR artifact tag 를 app_image_tag 로 명시해 배포한다.
#   image 필드 위임(ignore_changes)은 Stage 6 D42 에서만 도입한다.
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
          # Stage 5: public base image를 직접 실행하지 않고, 로컬 골든패스가
          # 빌드·Trivy 검증·ECR push 한 자체 artifact를 실행한다.
          # Stage 5: 공용 레지스트리 → 우리 ECR
          #   노드롤에 AmazonEC2ContainerRegistryReadOnly 가 이미 있어
          #   추가 IAM 작업 없이 pull 가능 (S2 detach 때 보존된 권한).
          #   ⚠ 리포지토리가 IMMUTABLE — 재빌드 시 새 태그 + var 갱신 필요.
          #   S7 에서 digest 핀 + cosign 서명 검증으로 대체.
          image = "${local.ecr_repository_url}:${var.app_image_tag}"

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
