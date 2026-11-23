# 배포 시점 Inspector 검사용 읽기 권한(build 역할). 지금 워크플로에는 연결하지 않았다.
# inspector2 List*는 리소스 수준 제한을 지원하지 않아서 resources = "*".

data "aws_iam_policy_document" "inspector_gate_read" {
  statement {
    sid    = "ReadScanStatusAndFindingsOnly"
    effect = "Allow"
    actions = [
      "inspector2:ListCoverage", # 스캔이 끝났는지 확인(비동기 대기)
      "inspector2:ListFindings", # 차단 기준 평가
    ]
    resources = ["*"]
  }

  # 일부러 안 준 권한:
  #   inspector2:CreateFilter / UpdateFilter: suppression으로 finding을 숨기지 못하게
  #   inspector2:Disable / UpdateConfiguration: 스캔 자체를 끄지 못하게
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
