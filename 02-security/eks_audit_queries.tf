# EKS 감사 로그 저장 쿼리 2개(Logs Insights): app 네임스페이스의 PSA 위반·거부, CI 배포 자격의 API 호출 전부.
# Logs Insights는 JSON 필드를 200개까지만 자동 추출해서 annotations가 비어 보일 수 있다.
# 그래서 필터는 앞쪽 필드(verb·user·objectRef·responseStatus)와 @message 검색만 쓴다.

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

  # 슬래시는 콘솔 저장 쿼리 목록에서 폴더가 된다(devsecops-project / eks-audit / 01-…).
  name            = "${var.project_name}/eks-audit/${each.key}"
  log_group_names = [aws_cloudwatch_log_group.eks_control_plane.name]

  # 줄바꿈 정규화. athena.tf와 같은 이유다.
  query_string = trimspace(replace(each.value.query, "\r", ""))
}
