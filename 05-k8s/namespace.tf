# 운영(app)과 데모(default)를 네임스페이스로 나누고, 엄격한 기준은 운영에만 건다. default에 restricted를 걸면 데모가 안 돌아간다.
# *-version은 클러스터 버전에 맞춰 고정한다. 업그레이드하다가 기준이 슬쩍 바뀌지 않게.

locals {
  app_namespace = "app"
  psa_version   = "v1.35"  # 04-eks var.kubernetes_version이랑 맞춘다
}

resource "kubernetes_namespace_v1" "app" {
  # 새 네임스페이스의 default SA는 컨트롤러가 조금 늦게 만든다. 그 전에 Deployment가 파드를 만들면
  # "serviceaccount default not found"로 재시도가 돌아서, SA가 생길 때까지 기다린다.
  wait_for_default_service_account = true

  metadata {
    name = local.app_namespace
    labels = {
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = local.psa_version
      "pod-security.kubernetes.io/audit"           = "restricted"
      "pod-security.kubernetes.io/audit-version"   = local.psa_version
      "pod-security.kubernetes.io/warn"            = "restricted"
      "pod-security.kubernetes.io/warn-version"    = local.psa_version
    }
  }
}
