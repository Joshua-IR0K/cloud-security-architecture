# ============================================================
# 05-k8s/kyverno.tf — Stage 7 admission 검증 (신규)
# ============================================================
# 컨트롤러 구성 (체크리스트 #5):
#   admission  ON  — 검증의 본체
#   reports    ON  — ★ Audit 단계에서 위반을 관측하려면 필수
#                    (PolicyReport 를 생성하는 것이 이 컨트롤러다.
#                     끄면 Audit 결과를 볼 수 없어 B1 단계가 무의미해진다)
#   background OFF — 기존 리소스 재평가. 신규 admission 만 다루므로 불필요
#   cleanup    OFF — CleanupPolicy 미사용 (v1.20 에서 제거 예정이기도 함)
#
# t3.medium × 2 에 LBC·CSI·ASCP·nginx·데모 파드가 이미 있으므로
# 불필요한 컨트롤러를 끄는 것은 취향이 아니라 용량 문제다.
# ============================================================

resource "helm_release" "kyverno" {
  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno"
  chart            = "kyverno"
  version          = var.kyverno_chart_version
  namespace        = "kyverno"
  create_namespace = true

  # CRD 설치와 admission controller Ready까지 Helm이 기다린 뒤 정책을 적용한다.
  # 고정 sleep은 readiness의 증거가 아니므로 사용하지 않는다.
  wait    = true
  timeout = 600

  set = [
    # ── 컨트롤러 최소화 ──
    { name = "backgroundController.enabled", value = "false" },
    { name = "cleanupController.enabled", value = "false" },
    { name = "reportsController.enabled", value = "true" },

    # ── 최소 replica (개인 랩) ──
    # Production Delta: admission HA replicas + PDB + topology spread/anti-affinity + monitoring.
    { name = "admissionController.replicas", value = "1" },
    { name = "reportsController.replicas", value = "1" },

    # ── 리소스 요청 축소 (2노드 비용 제약 환경) ──
    { name = "admissionController.container.resources.requests.cpu", value = "50m" },
    { name = "admissionController.container.resources.requests.memory", value = "128Mi" },
    { name = "reportsController.resources.requests.cpu", value = "50m" },
    { name = "reportsController.resources.requests.memory", value = "128Mi" },
  ]
}

# ── 02-security 가 발행한 검증 material ─────────────────────
data "aws_ssm_parameter" "signing_public_key_pem" {
  name = "/${var.project_name}/security/signing_public_key_pem"
}
