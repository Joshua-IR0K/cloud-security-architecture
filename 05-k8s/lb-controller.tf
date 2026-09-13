# ============================================================
# 05-k8s/lb-controller.tf — AWS Load Balancer Controller (Helm)
# ============================================================
# IAM 역할·정책·Pod Identity association 은 04-eks 소유 (AWS 평면).
# 여기는 차트 설치만 — 두 평면 분리 원칙.
#
# 04 가 Pod Identity association 을 먼저 생성하므로,
# LBC 파드는 첫 기동부터 AWS credential 경로를 사용할 수 있다.
# 이는 IAM/credential bootstrap dependency를 04→05 스택 경계로 분리한다.
#
# Service Mutator webhook readiness race는 별개의 문제이며,
# 아래 enableServiceMutatorWebhook=false 로 제거한다.

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

      # ── Service Mutator Webhook 비활성화 (Stage 7) ──────────────
      # 이 webhook 의 용도는 "Service type=LoadBalancer 를 LBC 가 프로비저닝하게
      # 만드는 것"이다. 우리는 ALB 를 03-workload 가 소유하고 TargetGroupBinding
      # 으로 연결하므로 type=LoadBalancer 를 쓰지 않는다
      # (workload.tf: kubernetes_service_v1.nginx → type = "ClusterIP").
      #
      # ⚠ 쓰지 않는데도 해로웠다 — 실제로 겪은 장애:
      #   이 webhook 은 operations=[CREATE] 로 **클러스터의 모든 Service 생성**을
      #   가로채고 failurePolicy=Fail 이다. LBC 파드가 Ready 되기 전에 다른
      #   컴포넌트가 Service 를 만들면 다음으로 그 컴포넌트 설치가 실패한다:
      #     Internal error occurred: failed calling webhook "mservice.elbv2.k8s.aws":
      #     no endpoints available for service "aws-load-balancer-webhook-service"
      #   Stage 7 에서 Kyverno helm 이 정확히 이 이유로 깨졌다.
      #   Kyverno 도입 전에는 05 가 만드는 Service 가 nginx 하나뿐이었고 LBC 보다
      #   늦게 생성돼 우연히 드러나지 않았다.
      #
      # ⚠ 대안이었던 namespaceSelectors 예외를 택하지 않은 이유:
      #   새 컴포넌트를 넣을 때마다 예외를 추가해야 하고 "왜 이 예외가 있는가"가
      #   계속 늘어난다. 쓰지 않는 기능은 끄는 것이 근원적이다.
      #   (D22 Calico 미도입 · D40 GitOps 미도입과 같은 "최소 표면" 원칙)
      #
      # ⚠ 되살려야 하는 조건: Service type=LoadBalancer 로 NLB 를
      #   LBC가 직접 프로비저닝하도록 전환할 경우 true 로 되돌린다. 그때는 serviceMutatorWebhookConfig
      #   의 namespaceSelectors 로 범위를 좁혀서 켠다.
      #
      # 영향 없음: TargetGroupBinding 은 CRD 기반이라 이 webhook 과 무관하다.
      #   Ingress validation webhook, pod mutator webhook 도 그대로 유지된다.
      enableServiceMutatorWebhook = false
    })
  ]

  # wait = true:
  # 이 Helm release의 워크로드가 Ready 될 때까지 release 완료로 처리하지 않는다.
  # TGB는 workload.tf에서 이 release에 depends_on 하므로 LBC readiness 이후 생성된다.
  #
  # ⚠ atomic = true 는 의도적으로 두지 않는다:
  #   실패 시 자동 롤백(uninstall)되어 **진단 흔적이 사라진다.** Stage 7 에서
  #   Kyverno helm 이 깨졌을 때 실패한 릴리스가 남아 있었기에 helm list 로 상태를
  #   확인하고 원인(webhook endpoint 미준비)을 추적할 수 있었다.
  #   그리고 atomic 은 실패를 깔끔히 처리할 뿐 실패 자체를 막지 못한다 —
  #   근원 해결은 위의 enableServiceMutatorWebhook = false 다.
  wait    = true
  timeout = 600

  #depends_on = [
  #  aws_eks_pod_identity_association.lb_controller,
  #]
}
