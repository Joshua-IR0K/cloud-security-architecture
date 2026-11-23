# S3 버킷·IAM 역할·association 은 04-eks 소유. 여기는 SA + 파드만.
# BREAK(denied) → BUILD(granted) → VERIFY(scope) 3축은 outputs.tf 참조.
#
# Checkov: 이 파일의 데모 SA·파드는 리소스마다 #checkov:skip 으로 K8s 하드닝 항목을 제외한다.
#   실증 목적상 의도적으로 최소 구성(sleep 데모 파드·공용 이미지 태그·default 네임스페이스)이며,
#   하드닝 기준(비루트·읽기 전용 루트·probe·digest 등)은 운영 워크로드 nginx(app 네임스페이스)에 적용·검증한다.

# K8s: SA + 파드 2개 (denied / granted)
resource "kubernetes_service_account_v1" "identity_demo" {
  #checkov:skip=CKV_K8S_21:S2 실증 픽스처 — default 네임스페이스는 의도 (운영 워크로드는 app 네임스페이스)
  metadata {
    name      = "s2-identity-demo"
    namespace = "default"
  }
}

locals {
  # latest 사용 근거: S2 한정 데모 파드(사이클마다 소멸)라 digest 핀 원칙의
  # 적용 대상인 "서비스 워크로드"가 아님 — S5(ECR)·S7(서명/검증)에서 본편 적용.
  awscli_image = "public.ecr.aws/aws-cli/aws-cli:latest"
}

# ⚠ bare Pod 이 아니라 Deployment 인 이유
#   이유 1 (강제): NetworkPolicy 는 ownerReferences 가 있는 파드에만 적용됨.
#     standalone Pod 은 정책 대상이 되지 않아 세그멘테이션 실증이 불가능.
#   이유 2 (개선): Pod Identity admission-time 주입 레이스의
#     복구가 `kubectl rollout restart deploy/...` 한 줄로 끝남
#     (bare Pod 은 delete → terraform apply 왕복이 필요했음).

resource "kubernetes_deployment_v1" "identity_denied" {
  #checkov:skip=CKV_K8S_8,CKV_K8S_9,CKV_K8S_11,CKV_K8S_14,CKV_K8S_21,CKV_K8S_28,CKV_K8S_29,CKV_K8S_30,CKV_K8S_43:S2 실증 픽스처 — aws-cli sleep 파드(서버 프로세스 없음)·공용 이미지 태그·default 네임스페이스·기본 securityContext 를 의도적으로 유지. 하드닝 기준은 운영 nginx(app)에 적용·검증
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
  #checkov:skip=CKV_K8S_8,CKV_K8S_9,CKV_K8S_11,CKV_K8S_14,CKV_K8S_21,CKV_K8S_28,CKV_K8S_29,CKV_K8S_30,CKV_K8S_43:S2 실증 픽스처 — aws-cli sleep 파드(서버 프로세스 없음)·공용 이미지 태그·default 네임스페이스·기본 securityContext 를 의도적으로 유지. 하드닝 기준은 운영 nginx(app)에 적용·검증
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
  # 그래도 전파 지연 레이스는 남으므로, NoCredentials 시:
  #   kubectl rollout restart deploy/identity-granted
}
