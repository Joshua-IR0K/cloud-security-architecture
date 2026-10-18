# ============================================================
# 05-k8s/namespace.tf — 운영 워크로드 전용 네임스페이스 (3단계 파트 2)
# ============================================================
#
# 왜 nginx 만 따로 옮기는가 — CI 가 손댈 수 있는 유일한 워크로드
#   CI(gha-deploy-role → ci-deployer 그룹)는 nginx Deployment 를 patch 할 수 있다.
#   patch 는 image 필드만이 아니라 파드 템플릿 전체를 바꿀 수 있으므로,
#   침해된 CI 가 privileged · hostNetwork · hostPath 를 넣으면 노드 장악 경로가 된다 (위협모델 G6).
#   → 이 네임스페이스에 Pod Security Admission(PSA) "restricted" 를 enforce 해서
#     그런 파드 스펙은 API 서버가 생성 자체를 거부하게 만든다.
#     Deployment 수정은 받아들여지지만 ReplicaSet 이 새 파드를 만들지 못하고,
#     기존 파드는 그대로 서비스한다 (가용성을 해치지 않는 차단).
#
# 왜 default 에 그대로 걸지 않는가
#   default 에는 S2·S3·S4 실증 데모(aws-cli·busybox·CSI 데모)가 있다. restricted 를 걸면
#   그 데모가 깨지고, 반대로 기준을 낮추면 운영 워크로드 보호가 약해진다.
#   → 운영(app)과 실증(default)을 네임스페이스 경계로 분리하고, 기준은 운영에만 엄격하게.
#
# 라벨 3종 (같은 레벨을 세 모드로)
#   enforce : 위반 파드 생성 거부 (실제 통제)
#   audit   : 위반을 감사 로그에 기록 (EKS 감사 로그 → Logs Insights 로 조사 가능)
#   warn    : kubectl·CI 응답에 경고 표시 (patch 하는 쪽이 바로 알 수 있게)
#   *-version 은 클러스터 버전(04 var.kubernetes_version)에 고정 — 업그레이드 때 기준이
#   조용히 바뀌지 않게 하고, 올릴 때는 의도적으로 올린다.
# ============================================================

locals {
  app_namespace = "app"
  psa_version   = "v1.35" # 04-eks var.kubernetes_version 과 맞춘다
}

resource "kubernetes_namespace_v1" "app" {
  # 새 네임스페이스의 default SA 는 컨트롤러가 비동기로 만든다 — 생기기 전에 Deployment 가
  # 파드를 만들면 "serviceaccount default not found" 로 재시도가 돈다. 생성까지 기다린다.
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
