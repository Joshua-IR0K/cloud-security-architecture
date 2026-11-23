# 02-security/inspector_gate_policy.tf — S7 CLOSE (G7)
# 워크플로의 ⑥ Inspector gate 가 build 역할로 스캔 상태와 finding 을 읽는다.
# 이 권한이 없으면 게이트가 AccessDenied 로 실패한다 —
# S6 의 ssm:GetParameter 누락(#Work log)과 같은 계열의 "작업을 하려면 무엇에
# 접근해야 하는가"를 먼저 따지는 원칙.
#
# ⚠ 읽기 전용이다. Inspector 설정 변경·suppression 생성 권한은 주지 않는다 —
#   CI 가 스스로 finding 을 숨길 수 있으면 게이트가 무의미해진다.
#
# ⚠ inspector2 의 List* API 는 리소스 수준 제한을 지원하지 않아 resources="*" 다.
#   대신 워크플로가 ecrRepositoryName · ecrImageHash 필터로 범위를 좁힌다.

data "aws_iam_policy_document" "inspector_gate_read" {
  statement {
    sid    = "ReadScanStatusAndFindingsOnly"
    effect = "Allow"
    actions = [
      "inspector2:ListCoverage", # 스캔 완료 여부 (비동기 대기)
      "inspector2:ListFindings", # 차단 기준 평가
    ]
    resources = ["*"]
  }

  # 의도적 부재:
  #   inspector2:CreateFilter / UpdateFilter  — suppression 으로 finding 숨기기 차단
  #   inspector2:Disable / UpdateConfiguration — 스캔 자체를 끄는 경로 차단
}

resource "aws_iam_policy" "inspector_gate_read" {
  name        = "${var.project_name}-inspector-gate-read"
  description = "Read Inspector coverage/findings for the CI deploy gate (G7)"
  policy      = data.aws_iam_policy_document.inspector_gate_read.json
}

data "aws_ssm_parameter" "github_build_role_arn_for_gate" {
  name = "/${var.project_name}/bootstrap/github_build_role_arn"
}

resource "aws_iam_role_policy_attachment" "github_build_inspector_gate" {
  role       = element(split("/", nonsensitive(data.aws_ssm_parameter.github_build_role_arn_for_gate.value)), 1)
  policy_arn = aws_iam_policy.inspector_gate_read.arn
}
