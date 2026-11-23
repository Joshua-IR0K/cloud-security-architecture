# 04의 접근 항목이 deploy 역할을 "ci-deployer" 그룹에 매핑하고, 이 파일에서 그 그룹이 할 수 있는 일을 정한다. nginx 이미지 롤아웃 하나뿐이다.
# app 네임스페이스 Role만 쓰고 ClusterRole은 안 만든다. patch로 파드 스펙을 위험하게 바꿔도 app의 PSA restricted가 파드 생성을 막는다.

resource "kubernetes_role_v1" "ci_deployer" {
  metadata {
    name      = "ci-deployer"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels    = { "app.kubernetes.io/managed-by" = "terraform" }
  }

  # nginx Deployment 하나로만 묶는다(resource_names). 같은 네임스페이스에 다른 Deployment가 생겨도 손을 못 댄다.
  rule {
    api_groups     = ["apps"]
    resources      = ["deployments"]
    resource_names = ["nginx"]
    verbs          = ["get", "patch"]
  }

  # 롤아웃 상태 확인용. list/watch는 K8s RBAC 특성상 resource_names로 못 묶어서 읽기 동사만 준다.
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

  # 배포가 왜 실패했는지 보는 용도(FailedMount, ImagePullBackOff 같은 Warning 이벤트)
  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["get", "list"]
  }

  # 일부러 안 준 권한: pods/exec, pods/log, secrets, configmaps 쓰기, networkpolicies, serviceaccounts, services 쓰기
}

resource "kubernetes_role_binding_v1" "ci_deployer" {
  metadata {
    name      = "ci-deployer"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.ci_deployer.metadata[0].name
  }

  # 04의 접근 항목이 준 그룹 이름과 글자 하나까지 같아야 한다
  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = "ci-deployer"
  }
}
