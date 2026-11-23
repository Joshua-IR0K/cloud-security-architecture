# 왜 필요한가 — 로그는 쌓이는데 "무엇을 물어볼지"가 코드에 없었다
#   eks_control_plane_logs.tf 로 감사 로그를 받기 시작했지만, 사고가 났을 때 매번 쿼리를
#   새로 짜야 한다면 조사는 사람의 기억에 의존한다. 조사 절차 자체를 코드로 남긴다
#   (athena.tf 의 저장 쿼리와 같은 원칙 — CloudTrail·Flow Logs·WAF 는 Athena, EKS 감사는 Logs Insights).
#
# 쿼리 2개 — PSA 와 CI RBAC 이 막는 두 경로를 그대로 추적한다
#   01 app 네임스페이스의 PSA 위반·거부
#      누가 restricted 를 어기는 파드 스펙을 넣었나(audit-violations), 무엇이 거부됐나(403).
#      CI 신원으로 hostNetwork 를 넣는 patch 가 남기는 흔적:
#        ① Deployment patch — 허용되지만 audit-violations 주석이 붙는다 (요청자 = 시도한 신원)
#        ② 파드 생성 — replicaset-controller 의 요청이 PSA enforce 에 403 으로 거부된다
#      impersonatedUser 를 함께 본다 — 세션의 실증은 관리자가 CI 그룹을 가장(--as-group)해 수행한다.
#   02 CI 배포 신원(gha-deploy-role)의 API 호출 전부
#      사용자 이름 = arn:aws:sts::<계정>:assumed-role/<배포 역할>/gha-deploy-<GitHub run ID>
#      (액세스 항목의 기본 사용자 이름) → run ID 로 GitHub Actions 실행·CloudTrail 수임 기록과 이어진다.
#      권한 경계(RBAC)가 실제로 지켜졌는지 = 이 목록에 nginx 롤아웃 외의 호출·403 이 없는지.
#
# 필드 처리 원칙 (Logs Insights 제약)
#   JSON 이벤트에서 자동 추출되는 필드는 최대 200개다. 감사 이벤트는 annotations 가 맨 끝에 오고,
#   RequestResponse 수준 이벤트는 요청·응답 객체가 앞쪽 필드를 많이 차지해 annotations 가
#   추출되지 않을 수 있다.
#   → 필터는 앞쪽 필드(verb·user·objectRef·responseStatus)와 원문(@message) 검색만 쓴다.
#     annotations 필드는 표시용이다 — 비어 보이면 행을 펼쳐 @message 에서 확인한다.
#
# 실행 권한
#   쿼리를 실행하는 것은 사람(관리자)이다. CI plan 역할은 정의 조회(logs:DescribeQueryDefinitions)만
#   갖고, 실행(logs:StartQuery)은 없다 — 감사 로그 내용을 읽는 경로라서. plan 워크플로의 가드가 확인한다.
#   실행 비용은 스캔한 데이터 양만큼이다 (14일 보존·실습 규모라 미미).

locals {
  eks_audit_queries = {
    "01-app-psa-and-denials" = {
      query = <<-EOT
        fields @timestamp, user.username, impersonatedUser.username, verb, objectRef.resource, objectRef.name, responseStatus.code, responseStatus.message, `annotations.pod-security.kubernetes.io/audit-violations`
        | filter @logStream like /kube-apiserver-audit/
        | filter objectRef.namespace = "app"
        | filter @message like /audit-violations/ or responseStatus.code = 403
        | sort @timestamp desc
        | limit 100
      EOT
    }

    "02-ci-deployer-activity" = {
      query = <<-EOT
        fields @timestamp, user.username, verb, objectRef.resource, objectRef.namespace, objectRef.name, responseStatus.code, sourceIPs.0, userAgent
        | filter @logStream like /kube-apiserver-audit/
        | filter user.username like /github-actions-deploy/
        | sort @timestamp desc
        | limit 200
      EOT
    }
  }
}

resource "aws_cloudwatch_query_definition" "eks_audit" {
  for_each = local.eks_audit_queries

  # 슬래시는 콘솔의 저장 쿼리 목록에서 폴더가 된다 — devsecops-project / eks-audit / 01-…
  name            = "${var.project_name}/eks-audit/${each.key}"
  log_group_names = [aws_cloudwatch_log_group.eks_control_plane.name]

  # 줄바꿈 정규화 — athena.tf 와 같은 이유. Windows(CRLF)에서 편집·apply 해도 CI(Linux) plan 과
  #   같은 문자열이 되게 한다 (HCL heredoc 은 CR 을 그대로 보존한다). 끝 줄바꿈도 잘라 둔다.
  query_string = trimspace(replace(each.value.query, "\r", ""))
}
