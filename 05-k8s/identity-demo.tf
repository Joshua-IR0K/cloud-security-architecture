# 버킷, IAM 역할, 연결은 04에서 만든다. 여기서는 SA와 데모 파드 2개(denied/granted)만 다룬다.
# 데모 SA·파드는 하드닝 항목을 리소스마다 checkov skip으로 뺐다. 하드닝은 운영 nginx(app)에 건다.

resource "kubernetes_service_account_v1" "identity_demo" {
  #checkov:skip=CKV_K8S_21:S2 실증 픽스처 — default 네임스페이스는 의도 (운영 워크로드는 app 네임스페이스)
  metadata {
    name      = "s2-identity-demo"
    namespace = "default"
  }
}

locals {
  # latest를 쓴다. 세션마다 지우는 데모 파드라 digest까지 고정할 필요가 없다(운영 nginx는 digest 고정).
  awscli_image = "public.ecr.aws/aws-cli/aws-cli:latest"
}

# bare Pod 말고 Deployment로 만든다. NetworkPolicy는 ownerReferences가 있는 파드에만 걸리고, 자격 주입이 늦게 붙으면 rollout restart로 살릴 수 있다.

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
        # service_account_name을 안 주면 default SA라 Pod Identity 연결이 없다(일부러 이렇게 둔다).
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

  # 연결이 파드보다 먼저 있어야 파드가 만들어질 때 자격이 주입된다.
  # 그래도 전파가 늦으면 NoCredentials가 날 수 있다. 그럴 땐 아래처럼 다시 띄운다.
  #   kubectl rollout restart deploy/identity-granted
}
