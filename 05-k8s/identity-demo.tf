# ============================================================
# 05-k8s/identity-demo.tf — Pod Identity 실증 워크로드 (K8s 평면)
# ============================================================
# S3 버킷·IAM 역할·association 은 04-eks 소유. 여기는 SA + 파드만.
# BREAK(denied) → BUILD(granted) → VERIFY(scope) 3축은 outputs.tf 참조.

# ── K8s: SA + 파드 2개 (denied / granted) ─────────────────
resource "kubernetes_service_account_v1" "identity_demo" {
  metadata {
    name      = "s2-identity-demo"
    namespace = "default"
  }
}

locals {
  # latest 사용 근거: S2 한정 데모 파드(사이클마다 소멸)라 digest 핀 원칙(D11)의
  # 적용 대상인 "서비스 워크로드"가 아님 — S5(ECR)·S7(서명/검증)에서 본편 적용.
  awscli_image = "public.ecr.aws/aws-cli/aws-cli:latest"
}

# ⚠ Stage 3 에서 bare Pod → Deployment 로 전환 (D23)
#   이유 1 (강제): NetworkPolicy 는 ownerReferences 가 있는 파드에만 적용됨.
#     standalone Pod 은 정책 대상이 되지 않아 세그멘테이션 실증이 불가능.
#   이유 2 (개선): 트러블슈팅 #7(Pod Identity admission-time 주입 레이스)의
#     복구가 `kubectl rollout restart deploy/...` 한 줄로 끝남
#     (bare Pod 은 delete → terraform apply 왕복이 필요했음).
#   ※ 검증 명령도 파드명 대신 `deploy/<name>` 참조로 변경됨 (outputs.tf)

resource "kubernetes_deployment_v1" "identity_denied" {
  metadata {
    name      = "identity-denied"
    namespace = "default"
    labels    = { app = "s2-demo", role = "denied" }
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "s2-demo", role = "denied" }
    }
    template {
      metadata {
        labels = { app = "s2-demo", role = "denied" }
      }
      spec {
        # service_account_name 미지정 = default SA = Pod Identity 연결 없음 (의도)
        container {
          name    = "awscli"
          image   = local.awscli_image
          command = ["sleep", "infinity"]
          resources {
            requests = { cpu = "10m", memory = "64Mi" }
            limits   = { memory = "128Mi" }
          }
        }
      }
    }
  }
}

resource "kubernetes_deployment_v1" "identity_granted" {
  metadata {
    name      = "identity-granted"
    namespace = "default"
    labels    = { app = "s2-demo", role = "granted" }
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "s2-demo", role = "granted" }
    }
    template {
      metadata {
        labels = { app = "s2-demo", role = "granted" }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.identity_demo.metadata[0].name
        container {
          name    = "awscli"
          image   = local.awscli_image
          command = ["sleep", "infinity"]
          resources {
            requests = { cpu = "10m", memory = "64Mi" }
            limits   = { memory = "128Mi" }
          }
        }
      }
    }
  }

  # 연결이 파드보다 먼저 존재해야 admission-time 에 자격이 주입됨.
  # 그래도 전파 지연 레이스(#7)는 남으므로, NoCredentials 시:
  #   kubectl rollout restart deploy/identity-granted
  # depends_on = [aws_eks_pod_identity_association.identity_demo]
}
