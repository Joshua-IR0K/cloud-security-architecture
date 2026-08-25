# ============================================================
# 05-k8s/lb-controller.tf — AWS Load Balancer Controller (Helm)
# ============================================================
# IAM 역할·정책·Pod Identity association 은 04-eks 소유 (AWS 평면).
# 여기는 차트 설치만 — 두 평면 분리 원칙.
#
# 04 가 association 을 먼저 만들어 두므로, 컨트롤러 파드는 첫 기동부터
# 자격증명을 받는다 (트러블슈팅 #7 의 admission-time 레이스가
#  스택 분리로 구조적으로 해소된 지점).

# ── Helm Release ──────────────────────────────────────────
# 의존 사슬(스택 분리 후): [04] 클러스터·노드·association → [05] helm → TGB
#   스택 경계가 곧 순서 보장 — 04 apply 완료 없이는 05 의 data 조회부터 실패
# helm install 이 TargetGroupBinding CRD 를 자동 설치
#   → kubectl_manifest(TGB) 는 이 릴리스에 depends_on (workload.tf)
resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = var.lb_controller_chart_version

  # region / vpcId 명시 = 필수 (선택 아님):
  #   hop-limit=1 로 컨트롤러 파드가 IMDS 에 접근 불가
  #   → IMDS 로 리전/VPC 자동탐지가 실패하므로 값으로 직접 주입
  #   (AWS 공식 문서의 "restricted IMDS 노드" 케이스 그대로)
  values = [
    yamlencode({
      clusterName = local.cluster_name
      region      = var.region
      vpcId       = local.vpc_id

      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
      }

      # Stage 1 = 노드 1대: 기본 HA(replica 2) 대신 1로 시작
      # Stage 3 노드 2대 확장 시 2로 올려 HA 복원 (다이얼)
      replicaCount = 1
    })
  ]

  wait    = true
  timeout = 600

  #depends_on = [
  #  aws_eks_pod_identity_association.lb_controller,
  #]
}
