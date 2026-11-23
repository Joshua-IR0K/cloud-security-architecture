# Secrets Manager 시크릿·IAM 역할·Pod Identity association 은 04-eks 소유.
# 여기는 드라이버 설치 + SA + SecretProviderClass + 데모 파드.
#
# 인증 경로: usePodIdentity="true"
#   ASCP 가 파드의 아이덴티티를 받아 IAM 역할을 수임하고,
#   그 역할로 허용된 시크릿만 가져온다. IRSA 대신 Pod Identity 사용.
#   요건: EKS 1.24+ (우리는 1.35), 차트 0.3.11+ (Pod Identity 지원 추가 버전)
#
# Checkov: 이 파일의 데모 SA·파드는 리소스마다 #checkov:skip 으로 K8s 하드닝 항목을 제외한다.
#   실증 목적상 의도적으로 최소 구성(sleep 데모 파드·공용 이미지 태그·default 네임스페이스)이며,
#   하드닝 기준(비루트·읽기 전용 루트·probe·digest 등)은 운영 워크로드 nginx(app 네임스페이스)에 적용·검증한다.

# ① CSI 드라이버 (CRD 제공자) — 명시적 설치
# ⚠ 드라이버를 따로 설치하는 이유:
#   ASCP 차트의 "드라이버 자동 동반 설치"는 **차트 v2 기준**이다.
#   v1.x 에서는 드라이버가 함께 깔리지 않아 SecretProviderClass CRD 가
#   등록되지 않고, kubectl_manifest 가
#     "resource [secrets-store.csi.x-k8s.io/v1/SecretProviderClass]
#      isn't valid for cluster"
#   로 실패한다. 이때 ASCP 파드는 Running 이라 더 헷갈린다
#   (프로바이더는 드라이버의 플러그인 — 본체 없이도 파드는 뜬다).
#
# → 암묵적 의존성에 기대지 않고 드라이버를 별도 릴리스로 명시한다.
#   공급망 원칙과도 일치: "무엇이 설치되는지 코드에 드러나야 한다".
resource "helm_release" "secrets_store_csi_driver" {
  name       = "secrets-store-csi-driver"
  repository = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart      = "secrets-store-csi-driver"
  version    = var.secrets_store_driver_version
  namespace  = "kube-system"

  set = [
    {
      # ★ K8s Secret 객체를 만들지 않는다
      #   (이 값이 true 면 etcd 에 Secret 이 생겨 CSI 를 택한 이유가 무너진다)
      name  = "syncSecret.enabled"
      value = "false"
    },
    {
      # 회전 리컨실러 — 시크릿 갱신 시 마운트 파일 자동 갱신
      # (파드 재배포 없이 — demo_secret_version 회전 데모의 전제)
      name  = "enableSecretRotation"
      value = "true"
    },
    {
      name  = "rotationPollInterval"
      value = "60s"
    },
  ]
}

# ② AWS 프로바이더 (ASCP)
# 드라이버의 플러그인. 드라이버가 먼저 있어야 의미가 있다.
resource "helm_release" "secrets_csi" {
  name       = "secrets-store-csi-driver-provider-aws"
  repository = "https://aws.github.io/secrets-store-csi-driver-provider-aws"
  chart      = "secrets-store-csi-driver-provider-aws"
  version    = var.secrets_csi_chart_version
  namespace  = "kube-system"

  depends_on = [helm_release.secrets_store_csi_driver]
}

# CRD 전파 대기
# depends_on 은 helm 릴리스 "완료"만 보장할 뿐, CRD 등록이 API 서버에
# 전파돼 디스커버리에 노출되기까지는 별개다. kubectl_manifest 가 그
# 사이에 실행되면 같은 에러가 재발한다 (Pod Identity 주입과 동일 계열의
# "생성 완료 ≠ 사용 가능" 문제).
resource "time_sleep" "wait_for_crd" {
  create_duration = "30s"
  depends_on      = [helm_release.secrets_store_csi_driver]
}

# SA — 04 의 association 이 이 이름을 참조
resource "kubernetes_service_account_v1" "secrets_demo" {
  #checkov:skip=CKV_K8S_21:S4 실증 픽스처 — default 네임스페이스는 의도 (운영 워크로드는 app 네임스페이스)
  metadata {
    name      = "s4-secrets-demo"
    namespace = "default"
  }
}

# SecretProviderClass (CRD — 드라이버가 설치)
# CRD 라 kubectl_manifest 사용 (typed 리소스는 plan 시점에 CRD 를 요구)
resource "kubectl_manifest" "secrets_demo" {
  yaml_body = yamlencode({
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "s4-secrets-demo"
      namespace = "default" # 파드와 반드시 같은 네임스페이스
    }
    spec = {
      provider = "aws"
      parameters = {
        # ★ Pod Identity 사용 선언 (미지정 시 기본값은 IRSA)
        usePodIdentity = "true"
        region         = var.region
        # JMESPath 로 JSON 시크릿의 개별 키를 각각 파일로 마운트
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

# ② BUILD: 자격 있는 파드 (마운트 성공해야 정답)
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

# ① BREAK: 자격 없는 파드 (마운트 실패해야 정답)
# default SA = Pod Identity 연결 없음 → ASCP 가 역할을 수임하지 못함
# → 볼륨 마운트 실패 → 파드가 ContainerCreating 에서 진행 못 함
resource "kubernetes_deployment_v1" "secrets_denied" {
  #checkov:skip=CKV_K8S_8,CKV_K8S_9,CKV_K8S_11,CKV_K8S_14,CKV_K8S_21,CKV_K8S_28,CKV_K8S_29,CKV_K8S_30,CKV_K8S_43:S4 실증 픽스처 — aws-cli sleep 파드(서버 프로세스 없음)·공용 이미지 태그·default 네임스페이스·기본 securityContext 를 의도적으로 유지. 하드닝 기준은 운영 nginx(app)에 적용·검증
  metadata {
    name      = "secrets-denied"
    namespace = "default"
    labels    = { app = "s4-demo", role = "s4-denied" }
  }

  # ⚠ 필수: 이 파드는 "의도적으로" 기동에 실패하므로 롤아웃을 기다리면
  #   terraform apply 가 타임아웃으로 실패한다.
  wait_for_rollout = false

  spec {
    replicas = 1
    selector { match_labels = { app = "s4-demo", role = "s4-denied" } }

    template {
      metadata { labels = { app = "s4-demo", role = "s4-denied" } }
      spec {
        # service_account_name 미지정 = default SA (association 없음)
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
