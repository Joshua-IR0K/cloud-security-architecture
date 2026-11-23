# 시크릿, IAM 역할, Pod Identity 연결은 04에서 만든다. 여기서는 드라이버, SA, SecretProviderClass, 데모 파드만 다룬다.
# ASCP가 usePodIdentity로 파드에 연결된 역할을 받아서 허용된 시크릿만 가져온다(차트 0.3.11 이상 필요).
# 데모 SA·파드는 하드닝 항목을 리소스마다 checkov skip으로 뺐다. 하드닝은 운영 nginx(app)에 건다.

# CSI 드라이버는 따로 깐다. ASCP 차트 v1.x는 드라이버를 같이 안 깔아서 SecretProviderClass CRD가 없고,
# kubectl_manifest가 "isn't valid for cluster"로 실패한다. ASCP 파드는 Running이라 더 헷갈린다.
resource "helm_release" "secrets_store_csi_driver" {
  name       = "secrets-store-csi-driver"
  repository = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart      = "secrets-store-csi-driver"
  version    = var.secrets_store_driver_version
  namespace  = "kube-system"

  set = [
    {
      # K8s Secret 객체는 안 만든다. true로 두면 etcd에 Secret이 생겨서 CSI를 쓰는 의미가 없어진다.
      name  = "syncSecret.enabled"
      value = "false"
    },
    {
      # 회전 리컨실러. 시크릿이 바뀌면 파드를 다시 안 띄워도 마운트된 파일이 갱신된다.
      name  = "enableSecretRotation"
      value = "true"
    },
    {
      name  = "rotationPollInterval"
      value = "60s"
    },
  ]
}

# AWS 프로바이더(ASCP). 드라이버에 꽂는 플러그인이다.
resource "helm_release" "secrets_csi" {
  name       = "secrets-store-csi-driver-provider-aws"
  repository = "https://aws.github.io/secrets-store-csi-driver-provider-aws"
  chart      = "secrets-store-csi-driver-provider-aws"
  version    = var.secrets_csi_chart_version
  namespace  = "kube-system"

  depends_on = [helm_release.secrets_store_csi_driver]
}

# CRD 전파 대기. helm 릴리스가 끝나도 CRD가 API 디스커버리에 바로 보인다는 보장은 없다.
resource "time_sleep" "wait_for_crd" {
  create_duration = "30s"
  depends_on      = [helm_release.secrets_store_csi_driver]
}

# SA. 04의 연결(association)이 이 이름을 가리킨다.
resource "kubernetes_service_account_v1" "secrets_demo" {
  #checkov:skip=CKV_K8S_21:S4 실증 픽스처 — default 네임스페이스는 의도 (운영 워크로드는 app 네임스페이스)
  metadata {
    name      = "s4-secrets-demo"
    namespace = "default"
  }
}

# SecretProviderClass는 CRD라서 kubectl_manifest로 만든다(typed 리소스는 plan 때 CRD가 있어야 한다).
resource "kubectl_manifest" "secrets_demo" {
  yaml_body = yamlencode({
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "s4-secrets-demo"
      namespace = "default" # 파드와 꼭 같은 네임스페이스여야 한다
    }
    spec = {
      provider = "aws"
      parameters = {
        # Pod Identity를 쓴다고 명시한다(안 쓰면 기본값이 IRSA).
        usePodIdentity = "true"
        region         = var.region
        # JMESPath로 JSON 시크릿의 키를 하나씩 파일로 마운트한다.
        objects = yamlencode([
          {
            objectName = local.s4_secret_name
            objectType = "secretsmanager"
            jmesPath = [
              { path = "username", objectAlias = "db-username" },
              { path = "password", objectAlias = "db-password" },
            ]
          }
        ])
      }
    }
  })

  depends_on = [time_sleep.wait_for_crd, helm_release.secrets_csi]
}

# 권한 있는 파드. 마운트가 성공해야 정상이다.
resource "kubernetes_deployment_v1" "secrets_granted" {
  #checkov:skip=CKV_K8S_8,CKV_K8S_9,CKV_K8S_11,CKV_K8S_14,CKV_K8S_21,CKV_K8S_28,CKV_K8S_29,CKV_K8S_30,CKV_K8S_43:S4 실증 픽스처 — aws-cli sleep 파드(서버 프로세스 없음)·공용 이미지 태그·default 네임스페이스·기본 securityContext 를 의도적으로 유지. 하드닝 기준은 운영 nginx(app)에 적용·검증
  metadata {
    name      = "secrets-granted"
    namespace = "default"
    labels    = { app = "s4-demo", role = "s4-granted" }
  }

  spec {
    replicas = 1
    selector { match_labels = { app = "s4-demo", role = "s4-granted" } }

    template {
      metadata { labels = { app = "s4-demo", role = "s4-granted" } }
      spec {
        service_account_name = kubernetes_service_account_v1.secrets_demo.metadata[0].name

        container {
          name    = "awscli"
          image   = local.awscli_image
          command = ["sleep", "infinity"]

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets-store"
            read_only  = true
          }

          resources {
            requests = { cpu = "10m", memory = "64Mi" }
            limits   = { memory = "128Mi" }
          }
        }

        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = "s4-secrets-demo"
            }
          }
        }
      }
    }
  }

  depends_on = [kubectl_manifest.secrets_demo]
}

# 권한 없는 파드. default SA는 Pod Identity 연결이 없어서 마운트가 실패하고 ContainerCreating에 멈춰 있어야 정상이다.
resource "kubernetes_deployment_v1" "secrets_denied" {
  #checkov:skip=CKV_K8S_8,CKV_K8S_9,CKV_K8S_11,CKV_K8S_14,CKV_K8S_21,CKV_K8S_28,CKV_K8S_29,CKV_K8S_30,CKV_K8S_43:S4 실증 픽스처 — aws-cli sleep 파드(서버 프로세스 없음)·공용 이미지 태그·default 네임스페이스·기본 securityContext 를 의도적으로 유지. 하드닝 기준은 운영 nginx(app)에 적용·검증
  metadata {
    name      = "secrets-denied"
    namespace = "default"
    labels    = { app = "s4-demo", role = "s4-denied" }
  }

  # 일부러 못 뜨게 만든 파드라 롤아웃을 기다리지 않는다. 기다리면 apply가 타임아웃으로 실패한다.
  wait_for_rollout = false

  spec {
    replicas = 1
    selector { match_labels = { app = "s4-demo", role = "s4-denied" } }

    template {
      metadata { labels = { app = "s4-demo", role = "s4-denied" } }
      spec {
        # service_account_name을 안 주면 default SA(연결 없음)
        container {
          name    = "awscli"
          image   = local.awscli_image
          command = ["sleep", "infinity"]

          volume_mount {
            name       = "secrets-store"
            mount_path = "/mnt/secrets-store"
            read_only  = true
          }

          resources {
            requests = { cpu = "10m", memory = "64Mi" }
            limits   = { memory = "128Mi" }
          }
        }

        volume {
          name = "secrets-store"
          csi {
            driver    = "secrets-store.csi.k8s.io"
            read_only = true
            volume_attributes = {
              secretProviderClass = "s4-secrets-demo"
            }
          }
        }
      }
    }
  }

  depends_on = [kubectl_manifest.secrets_demo]
}
