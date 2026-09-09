# ============================================================
# 05-k8s/rbac-ci-deployer.tf — S6-B: CI 배포 권한 (신규)
# ============================================================
# 04 의 access entry 가 gha-deploy-role 을 "ci-deployer" 그룹에 매핑했다.
# 이 파일은 그 그룹이 **무엇을 할 수 있는지**를 정의한다.
#
# 설계 목표: CI 는 이미지 롤아웃 하나만 할 수 있어야 한다.
#   허용   nginx Deployment get/patch + 롤아웃 관측(RS/Pod read)
#   미부여 Secret · NetworkPolicy · ServiceAccount · SecretProviderClass ·
#          TargetGroupBinding · Helm release · CRD · kube-system · cluster-scope · exec
#
# ★ Role(네임스페이스 범위)만 쓰고 ClusterRole 을 만들지 않는다.
#   → default 네임스페이스 밖으로는 어떤 권한도 새지 않는다.
# ============================================================

resource "kubernetes_role_v1" "ci_deployer" {
  metadata {
    name      = "ci-deployer"
    namespace = "default"
    labels    = { "app.kubernetes.io/managed-by" = "terraform" }
  }

  # ── 이미지 롤아웃 대상: nginx Deployment 하나로 핀포인트 ──
  # resource_names 로 특정 객체만 지정 — 같은 네임스페이스의 다른 Deployment
  # (netpol-client, identity-*, secrets-*)는 건드릴 수 없다.
  rule {
    api_groups     = ["apps"]
    resources      = ["deployments"]
    resource_names = ["nginx"]
    verbs          = ["get", "patch"]
  }

  # ── 롤아웃 관측 ───────────────────────────────────────────
  # ⚠ list/watch 는 resource_names 로 제한할 수 없다(K8s RBAC 제약) —
  #   컬렉션 조회는 이름 기반 필터링을 지원하지 않기 때문.
  #   그래서 읽기 전용 동사만 부여하고 쓰기는 위 statement 로만 허용한다.
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "replicasets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }

  # 배포 실패 원인 확인용 (Warning 이벤트 — FailedMount·ImagePullBackOff 등)
  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["get", "list"]
  }

  # 의도적 부재: pods/exec, pods/log, secrets, configmaps write,
  #             networkpolicies, serviceaccounts, services write
}

resource "kubernetes_role_binding_v1" "ci_deployer" {
  metadata {
    name      = "ci-deployer"
    namespace = "default"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.ci_deployer.metadata[0].name
  }

  # ★ 04 의 access entry 가 부여한 그룹 이름과 정확히 일치해야 한다
  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = "ci-deployer"
  }
}
