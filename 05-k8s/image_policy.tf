# ============================================================
# 05-k8s/image_policy.tf — Stage 7 공급망 admission 정책
# ============================================================
# 두 통제를 분리한다.
#   A. source guard : nginx workload가 승인된 first-party ECR repo@digest만 사용
#   B. signature IVP: 그 digest가 승인된 KMS signing authority 서명을 가졌는지 검증
#
# 이유:
#   ImageValidatingPolicy의 matchImageReferences는 "검증 대상 선택"이다.
#   외부 registry로 image를 patch하면 IVP 자체를 벗어날 수 있으므로,
#   repository allowlist를 별도 ValidatingPolicy로 닫아야 한다.
#
# Scope:
#   namespace = default
#   workload  = Deployment/nginx + app=nginx Pods
#   image     = devsecops-project/app@sha256:...
#   → kube-system 및 S2~S4 public demo workload는 영향 없음.
# ============================================================

locals {
  app_digest_glob   = "${local.ecr_repository_url}@sha256:*"
  app_digest_prefix = "${local.ecr_repository_url}@sha256:"
}

# ── A. Repository + digest source guard ─────────────────────
# RBAC은 Deployment의 필드 단위 제한을 지원하지 않는다. gha-deploy가 nginx를
# patch할 수 있다면 image를 외부 registry로 바꾸는 것도 기술적으로 가능하므로,
# admission에서 정확한 first-party repository boundary를 강제한다.
resource "kubectl_manifest" "nginx_image_source_guard" {
  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1"
    kind       = "NamespacedValidatingPolicy"
    metadata = {
      name      = "restrict-nginx-image-source"
      namespace = "default"
      annotations = {
        "policies.kyverno.io/title"       = "Restrict nginx image source"
        "policies.kyverno.io/category"    = "Software Supply Chain Security"
        "policies.kyverno.io/description" = "nginx workload must use the approved first-party ECR repository and immutable digest references."
      }
    }
    spec = {
      failurePolicy = "Fail"
      webhookConfiguration = {
        timeoutSeconds = 15
      }
      evaluation = {
        background = { enabled = false }
      }
      matchConstraints = {
        resourceRules = [
          {
            apiGroups   = [""]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["pods"]
          },
          {
            apiGroups   = ["apps"]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["deployments"]
          },
        ]
      }
      matchConditions = [
        {
          name = "target-nginx-workload"
          expression = "object.kind == 'Deployment' ? object.metadata.name == 'nginx' : (has(object.metadata.labels) && 'app' in object.metadata.labels && object.metadata.labels['app'] == 'nginx')"
        }
      ]
      variables = [
        {
          name       = "containers"
          expression = "object.kind == 'Deployment' ? object.spec.template.spec.containers : object.spec.containers"
        }
      ]
      validations = [
        {
          expression = "variables.containers.all(c, c.image.startsWith('${local.app_digest_prefix}'))"
          message    = "nginx images must come from the approved first-party ECR repository and use repo@sha256:<digest> references"
        }
      ]
      validationActions = [var.image_verification_action]
    }
  })

  depends_on = [helm_release.kyverno]
}

# ── B. Signature verification ────────────────────────────────
resource "kubectl_manifest" "image_verification" {
  yaml_body = yamlencode({
    apiVersion = "policies.kyverno.io/v1"
    kind       = "NamespacedImageValidatingPolicy"
    metadata = {
      name      = "verify-first-party-images"
      namespace = "default"
      annotations = {
        "policies.kyverno.io/title"       = "Verify first-party ECR image signatures"
        "policies.kyverno.io/category"    = "Software Supply Chain Security"
        "policies.kyverno.io/subject"     = "Pod, Deployment"
        "policies.kyverno.io/description" = "CI delivery is not an artifact trust signal; only approved-signer digests are admitted."
      }
    }
    spec = {
      failurePolicy = "Fail"
      webhookConfiguration = {
        timeoutSeconds = 15
      }
      evaluation = {
        background = { enabled = false }
      }

      # Deployment에서 배포 요청 자체를 거부하고, Pod에서도 direct-create 우회를 막는다.
      matchConstraints = {
        resourceRules = [
          {
            apiGroups   = [""]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["pods"]
          },
          {
            apiGroups   = ["apps"]
            apiVersions = ["v1"]
            operations  = ["CREATE", "UPDATE"]
            resources   = ["deployments"]
          },
        ]
      }

      # digest reference만 정확히 매칭. repo* 같은 과도한 glob을 쓰지 않는다.
      matchImageReferences = [
        { glob = local.app_digest_glob }
      ]

      # IVP에는 global registry credential helper fallback이 없다.
      # Kyverno admission SA의 Pod Identity + policy-level amazon provider가 ECR auth 경로다.
      credentials = {
        providers             = ["amazon"]
        allowInsecureRegistry = false
      }

      # KMS private key는 AWS 밖으로 나오지 않는다. CI/Kyverno는 동일 public PEM으로 검증한다.
      attestors = [
        {
          name = "cosign"
          cosign = {
            key = {
              data = nonsensitive(data.aws_ssm_parameter.signing_public_key_pem.value)
            }
            # ── D44 정합: 서명 경로와 검증 경로를 일치시킨다 ──────────
            # 우리는 Rekor 없이 서명한다(cosign signing-config 에서 rekorTlogUrls 제거).
            # 그런데 검증 측 기본값은 투명성 로그 항목을 1개 이상 요구하므로
            #   "not enough verified log entries from transparency log: 0 < 1"
            # 로 실패한다. 로컬 cosign 도 --insecure-ignore-tlog 없이는 같은 에러였다.
            #
            # 왜 tlog 가 필요 없는가:
            #   Rekor 는 keyless(Fulcio 단명 인증서)에서 "서명 당시 인증서가
            #   유효했음"을 제3자가 증명하는 장치다. 우리는 KMS 장기 키 +
            #   정적 공개키 PEM 검증이므로 그 문제가 존재하지 않는다.
            #   게다가 프라이빗 아티팩트의 digest 를 공개 로그에 영구 게시하는 것은
            #   이 프로젝트의 성격과 맞지 않는다.
            #
            # ⚠ insecureIgnoreSCT 는 켜지 않는다 — 그것은 **인증서** 투명성(CT) 로그용이며,
            #   우리 신뢰 모델에는 인증서 자체가 없다(key.data 만 사용).
            #   관측된 에러도 tlog 만 지목했다. 필요하다는 증거가 생기면 그때 추가한다.
            #
            # 트레이드오프(ADR 기록): 서명 시점의 제3자 증명이 없다.
            #   키가 침해되면 소급 탐지가 어렵다. 프로덕션에서는 사설 Rekor
            #   인스턴스 또는 keyless + Fulcio 를 검토한다.
            ctlog = {
              insecureIgnoreTlog = true
            }
          }
        }
      ]

      validationConfigurations = {
        mutateDigest = false
        verifyDigest = true
        required     = true
      }

      validations = [
        {
          expression = "images.containers.map(image, verifyImageSignatures(image, [attestors.cosign])).all(e, e > 0)"
          message    = "first-party ECR image must be signed by the approved signing authority and referenced by digest"
        }
      ]

      validationActions = [var.image_verification_action]
    }
  })

  depends_on = [helm_release.kyverno]
}
