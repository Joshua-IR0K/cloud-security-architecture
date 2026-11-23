# Deployment랑 Service는 typed 리소스로, TargetGroupBinding은 kubectl_manifest로 만든다.
# kubernetes_manifest는 plan 때 CRD가 이미 있어야 해서 처음부터 apply가 안 된다.
# 파드 보안 설정은 PSA restricted 요구사항을 그대로 옮긴 거라, 하나라도 빠지면 app에서 파드가 거부된다.

locals {
  # 처음 만들 때 쓰는 기준 이미지. tag는 사람이 읽는 이름이고 실제 내용은 digest가 정한다.
  app_image = "${local.ecr_repository_url}:${var.app_image_tag}@${var.app_image_digest}"
  app_uid   = "101" # nginx-unprivileged의 nginx 사용자(images/s5-good/Dockerfile USER 101)
}

# html을 ConfigMap으로 마운트하지 않는다. 이미지 안의 /usr/share/nginx/html을 덮어버려서
# 지금 어느 커밋 이미지가 떠 있는지 HTTPS 응답으로 확인할 수 없게 된다.

resource "kubernetes_deployment_v1" "nginx" {
  metadata {
    name      = "nginx"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels = {
      app = "nginx"
    }
  }

  spec {
    replicas = 2 # TG 대상 여러 개 확인용. PDB(minAvailable 1)와 짝이라 한 번에 하나만 내려간다

    # 롤아웃 중에도 Ready 파드 2개는 유지한다. 새 파드가 Ready가 돼야 기존 파드를 내린다.
    # 레플리카를 늘려도 그대로 가도록 값을 고정해 뒀다. CI 롤아웃도 같은 규칙을 따른다.
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
        # SA 토큰은 마운트하지 않는다. nginx는 쿠버네티스 API를 안 부르니까, 뚫려도 쓸 토큰이 없다.
        automount_service_account_token = false

        # 파드 수준 설정. PSA restricted 요구사항(비루트, seccomp)
        security_context {
          run_as_non_root = true
          run_as_user     = local.app_uid
          run_as_group    = local.app_uid
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        # 파드를 AZ·노드에 나눠 띄운다. hard로 하면 노드 1대·AZ 1개일 때 두 번째 파드가 Pending에 걸려서 soft(ScheduleAnyway)로 둔다.
        # match_label_keys에 pod-template-hash를 넣어 롤아웃 중 옛 파드와 새 파드를 섞어 세지 않게 한다.
        # 스케줄할 때만 적용돼서 이미 떠 있는 파드는 안 옮긴다. 노드를 늘렸다면 다음 롤아웃 때 흩어진다.
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
          # 이미지는 노드 역할의 AmazonEC2ContainerRegistryReadOnly로 받는다(IAM 추가 없음). 처음 만든 뒤로는 CI가 이미지를 바꾼다(아래 lifecycle).
          # 비루트 이미지만 된다. root로 도는 이미지는 securityContext랑 PSA restricted에 막힌다.
          image = local.app_image

          port {
            name           = "http"
            container_port = 8080 # nginx-unprivileged라 1024 미만 포트 권한이 필요 없다
          }

          # 컨테이너 수준 설정. PSA restricted 요구사항 + 읽기 전용 루트
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

          # readiness는 "지금 트래픽 받아도 되나"를 본다. 실패하면 재시작 없이 Service와 ALB 대상에서만 빠진다.
          readiness_probe {
            http_get {
              path = "/"
              port = "http"
            }
            initial_delay_seconds = 3
            period_seconds        = 5
          }

          # liveness는 응답이 멈췄을 때 재시작하는 용도다. readiness보다 느슨하게(10초 × 3회) 둬서 잠깐 부하가 튀었다고 재시작이 연달아 일어나지 않게 했다.
          # "/"는 외부 의존이 없는 정적 페이지라 liveness로 써도 괜찮다. 외부 의존을 보는 liveness는 장애 하나를 전체 파드 재시작으로 키운다.
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

          # 읽기 전용 루트에서 nginx가 쓰는 유일한 곳(pid, 임시 파일. 베이스 이미지가 /tmp로 옮겨 뒀다)
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

  # 이미지 필드만 CI에 맡긴다. 레플리카·프로브·볼륨·SA·securityContext는 Terraform이 계속 관리하고, CI는 어떤 이미지를 띄울지만 정한다.
  # CI가 05 전체를 apply하게 하면 Helm release state를 읽을 권한까지 줘야 하고, tfvars가 빠지면 보안 설정이 지워질 수도 있다.
  # 처음 만들 때는 config 값이 들어가서 var.app_image_tag/digest가 기준 이미지가 된다.
  # kubectl rollout restart는 쓰지 않는다. 파드 템플릿에 restartedAt 주석이 붙어서 drift로 잡힌다. 재시작은 CI를 다시 돌리거나 terraform apply로 한다.
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].container[0].image
    ]
  }
}

# PDB minAvailable 1 + replicas 2. 드레인이나 노드 교체처럼 계획된 중단 때 한 번에 1개씩만 내보낸다.
# CI 롤아웃, terraform destroy, 노드 장애는 퇴거가 아니라서 PDB가 안 막는다. 롤아웃은 strategy가, 장애는 topologySpread가 맡는다.
# unhealthyPodEvictionPolicy는 kubernetes provider 3.2.x가 지원을 안 해서 기본값이다. 고장 난 파드가 섞여 있으면 드레인이 막힐 수 있다.
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
      port        = 80     # 서비스 포트는 80 그대로. 클러스터 안에서는 http://nginx.app으로 부른다
      target_port = "http" # 컨테이너의 이름 붙은 포트(8080)를 가리킨다
      protocol    = "TCP"
    }

    type = "ClusterIP" # 외부 노출은 ALB(TGB)가 맡아서 LoadBalancer 타입은 필요 없다
  }
}

# nginx 파드 IP를 03에서 만든 EKS 대상 그룹에 붙인다. networking.ingress를 주면 LB Controller가 노드 SG에
# "ALB SG에서 TCP 8080" 규칙(서비스 포트 말고 파드 포트)을 만든다. ALB 쪽 egress는 01의 alb_to_eks_pods에 있다.
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

  # CRD(helm이 설치)와 Service가 생긴 뒤에 적용한다.
  depends_on = [
    helm_release.aws_lb_controller,
    kubernetes_service_v1.nginx,
  ]
}
