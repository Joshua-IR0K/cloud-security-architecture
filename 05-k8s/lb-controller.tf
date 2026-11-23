# IAM 역할과 Pod Identity 연결은 04에서 만든다. 여기서는 차트만 설치한다.

# TargetGroupBinding CRD는 helm이 깐다. 그래서 workload.tf의 TGB가 이 릴리스에 depends_on을 건다.
resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = var.lb_controller_chart_version

  # region·vpcId는 직접 넣어줘야 한다. hop limit 1이라 컨트롤러가 IMDS로 알아낼 수 없다.
  values = [
    yamlencode({
      clusterName = local.cluster_name
      region      = var.region
      vpcId       = local.vpc_id

      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
      }

      # 노드 1대라 1로 둔다. 노드를 2대 이상으로 늘리면 2로 올려서 HA를 되살린다.
      replicaCount = 1

      # Service mutator webhook은 끈다. type=LoadBalancer를 안 쓰는데(ALB는 03에서 만들고 TGB로 연결) 이 webhook은 모든 Service 생성을
      # failurePolicy=Fail로 가로챈다. LBC가 Ready 되기 전에 다른 차트를 설치하다가 Service 생성이 실제로 깨진 적이 있다.
      # 다시 켜는 건 NLB를 type=LoadBalancer로 LBC가 만들게 바꿀 때다. 그때는 serviceMutatorWebhookConfig의 namespaceSelectors로 범위를 좁혀서 켠다.
      # TargetGroupBinding은 CRD 기반이라 이 webhook과 관계없다.
      enableServiceMutatorWebhook = false
    })
  ]

  # wait = true라서 워크로드가 Ready 돼야 릴리스가 끝나고, TGB는 그다음에 만들어진다.
  # atomic은 안 쓴다. 실패했을 때 자동으로 롤백되면 helm list로 볼 흔적까지 사라진다.
  wait    = true
  timeout = 600

}
