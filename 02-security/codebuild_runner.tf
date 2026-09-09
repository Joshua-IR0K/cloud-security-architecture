# ============================================================
# 02-security/codebuild_runner.tf — S6-B: VPC 배포 러너 (신규)
# ============================================================
# 문제: GitHub 호스티드 러너는 EKS 엔드포인트 allowlist(관리자 IP /32) 밖이라
#       kubectl 이 클러스터에 도달할 수 없다.
#
# 기각한 대안:
#   ✗ GitHub 러너 IP 대역을 allowlist 에 추가
#       → 대역이 방대하고 수시로 변경. 관리 평면 공개 노출을 크게 확대.
#         GitHub 자신도 내부 리소스 allowlist 용도로 권장하지 않는다.
#   ✗ 상시 EC2 self-hosted 러너
#       → EC2 수명주기·패치·러너 데몬·등록·유휴 비용이라는 새 운영 대상 발생.
#         S6 의 목적은 CI/CD 보안이지 러너 플릿 운영이 아니다.
#
# 채택: CodeBuild-hosted GitHub Actions 러너 (VPC 연결, job 단위 ephemeral)
#   ★ D37 보존: codebuild_runner_enabled=false가 기본이라 S6-A에서는 이 실패 도메인을 생성하지 않는다.
#     S6-B 진입 시 CodeConnection 준비 후 true로 전환한다.
#   GitHub Actions = 워크플로 엔진 (그대로)
#   CodeBuild      = EKS 프라이빗 API 에 닿기 위한 배포 job 전용 컴퓨트
#   → 별도 CI 제품으로 키우지 않는다. runs-on 한 줄만 바뀐다.
#
# 부수 이득: 후일 U2 에서 엔드포인트를 private-only 로 바꿔도
#   CI 배포 아키텍처를 재설계할 필요가 없다 (이미 VPC 경로).
#
# ★ 신뢰 경계 (ADR 필수 기록):
#   기존:  GitHub → AWS (OIDC, 단기 자격증명)
#   추가:  AWS → GitHub (CodeConnections/GitHub App, 러너 등록·제어)
#   → 이것은 "keyless 원칙 포기"가 아니다. 장기 AWS 키도 GitHub PAT 도 없다.
#     정확히는 **신뢰 표면(trust surface)의 증가**이며, 그 대가로
#     관리 평면을 인터넷에 넓게 열지 않아도 된다.
#   ⚠ PAT 를 쓰면 AWS→GitHub 방향에 장기 자격증명이 생겨 실제 후퇴가 된다.
#     그래서 CodeConnections + repo 스코프 GitHub App 을 쓴다(설치 토큰은 단기).
# ============================================================

data "aws_ssm_parameter" "private_subnet_ids_for_runner" {
  count = var.codebuild_runner_enabled ? 1 : 0
  name = "/${var.project_name}/network/private_subnet_ids"
}

data "aws_ssm_parameter" "vpc_id_for_runner" {
  count = var.codebuild_runner_enabled ? 1 : 0
  name = "/${var.project_name}/network/vpc_id"
}

# ── 러너용 보안그룹: 아웃바운드 전용 ────────────────────────
# 인바운드 0 — 러너는 GitHub 에서 job 을 받아오는 쪽(아웃바운드)이다.
resource "aws_security_group" "codebuild_runner" {
  count       = var.codebuild_runner_enabled ? 1 : 0
  name        = "${var.project_name}-codebuild-runner"
  description = "Ephemeral GitHub Actions runner for EKS deploy (egress only)"
  vpc_id      = nonsensitive(data.aws_ssm_parameter.vpc_id_for_runner[0].value)

  egress {
    description = "HTTPS to EKS API, ECR, GitHub, AWS APIs (via NAT)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-codebuild-runner" }
}

# ── CodeBuild 서비스 역할 ──────────────────────────────────
# ★ 여기에 배포 권한을 싣지 않는다.
#   이 역할은 "러너 배관"만 담당한다 — VPC ENI, 로그, 지정 CodeConnection 사용.
#   AWS 리소스 접근은 워크플로가 GitHub OIDC 로 gha-deploy-role 을 수임해 수행한다.
#   두 신원을 분리하는 것이 이 설계의 핵심 — 러너 컴퓨트가 침해돼도
#   그 자체로는 클러스터에 아무 권한이 없다.
data "aws_iam_policy_document" "codebuild_runner_trust" {
  count = var.codebuild_runner_enabled ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild_runner" {
  count              = var.codebuild_runner_enabled ? 1 : 0
  name               = "${var.project_name}-codebuild-runner"
  assume_role_policy = data.aws_iam_policy_document.codebuild_runner_trust[0].json

  tags = { Name = "${var.project_name}-codebuild-runner" }
}

data "aws_iam_policy_document" "codebuild_runner" {
  count = var.codebuild_runner_enabled ? 1 : 0
  # 로그
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      # Log group 자체 + 그 아래 log stream. CreateLogStream/PutLogEvents는 :* 범위가 필요하다.
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.project_name}-*",
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.project_name}-*:log-stream:*",
    ]
  }

  # VPC ENI — CodeBuild 가 프라이빗 서브넷에 붙기 위해 필요
  # ⚠ ec2:CreateNetworkInterfacePermission 은 조건으로 좁힌다:
  #   이 서브넷 + CodeBuild 서비스 경유만 허용
  statement {
    sid    = "VpcEni"
    effect = "Allow"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeDhcpOptions",
      "ec2:DescribeVpcs",
    ]
    resources = ["*"] # 이들 API 는 리소스 수준 제한 미지원
  }

  statement {
    sid       = "EniPermissionScoped"
    effect    = "Allow"
    actions   = ["ec2:CreateNetworkInterfacePermission"]
    resources = ["arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:network-interface/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:AuthorizedService"
      values   = ["codebuild.amazonaws.com"]
    }

    # ★ P2: AuthorizedService 만으로는 어느 서브넷이든 허용된다.
    #   ec2:Subnet 조건을 함께 걸어 이 프로젝트의 프라이빗 서브넷으로 한정
    #   (주석과 구현의 불일치 해소).
    condition {
      test     = "ArnEquals"
      variable = "ec2:Subnet"
      values = [
        for id in split(",", nonsensitive(data.aws_ssm_parameter.private_subnet_ids_for_runner[0].value)) :
        "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:subnet/${id}"
      ]
    }
  }

  # ── CodeConnections — 지정된 연결 하나만 ─────────────────
  # GitHub 저장소를 소스로 쓰기 위한 최소권한. 연결 ARN 으로 스코프해
  # 계정의 다른 연결은 사용할 수 없다.
  statement {
    sid    = "UseGitHubConnectionOnly"
    effect = "Allow"
    actions = [
      "codeconnections:GetConnection",
      "codeconnections:GetConnectionToken",
      "codeconnections:UseConnection",
      # 레거시 네임스페이스도 함께 (프로바이더/리전에 따라 codestar-connections 사용)
      "codestar-connections:GetConnection",
      "codestar-connections:GetConnectionToken",
      "codestar-connections:UseConnection",
    ]
    resources = [var.github_connection_arn]
  }

  # 의도적 부재: eks:* / ecr:* / sts:AssumeRole
  #   → 러너 컴퓨트는 클러스터에도 레지스트리에도 접근 권한이 없다.
  #   AWS 리소스 접근은 워크플로가 GitHub OIDC 로 gha-deploy-role 을 수임해 수행한다.
}

resource "aws_iam_role_policy" "codebuild_runner" {
  count  = var.codebuild_runner_enabled ? 1 : 0
  name   = "${var.project_name}-codebuild-runner"
  role   = aws_iam_role.codebuild_runner[0].id
  policy = data.aws_iam_policy_document.codebuild_runner[0].json
}

# ── CodeBuild 프로젝트 (러너 모드) ─────────────────────────
# source = GITHUB + CODECONNECTIONS. WORKFLOW_JOB_QUEUED webhook이 job을 기동한다.
# buildspec은 러너 모드에서 형식상 존재하며 실제 job 내용은 GitHub Actions가 결정한다.
resource "aws_codebuild_project" "gha_runner" {
  count         = var.codebuild_runner_enabled ? 1 : 0
  name          = "${var.project_name}-gha-deploy-runner"
  description   = "Ephemeral GitHub Actions runner for EKS deploy jobs (S6-B)"
  service_role  = aws_iam_role.codebuild_runner[0].arn
  build_timeout = 20

  artifacts { type = "NO_ARTIFACTS" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"
  }

  # ★ P0-1 수정: source = GITHUB (기존 NO_SOURCE 는 오류)
  #   러너 모드는 GitHub 의 workflow_job 이벤트를 웹훅으로 받아 기동한다.
  #   NO_SOURCE 프로젝트에는 웹훅을 붙일 수 없어 **러너가 아예 동작하지 않는다.**
  #   buildspec 은 형식상 필요할 뿐 — 실제 실행 내용은 GitHub Actions 워크플로가 정한다.
  source {
    type            = "GITHUB"
    location        = var.github_repo_url
    git_clone_depth = 1

    # ★ P0: source 인증을 CodeConnections 에 실제로 연결한다.
    #   IAM 정책에 연결 ARN 을 넣는 것만으로는 부족하다 — 그건 "이 연결을 쓸
    #   권한"이고, 여기 auth 블록이 "이 연결로 인증한다"는 실제 배선이다.
    #   둘 다 있어야 GitHub → CodeConnections → CodeBuild → ephemeral runner 가 완성된다.
    #   ⚠ PAT 를 쓰지 않는 이유가 여기 있다: CODECONNECTIONS 는 GitHub App 설치
    #     토큰(단기)을 쓰므로 AWS→GitHub 방향에 장기 자격증명이 생기지 않는다.
    auth {
      type     = "CODECONNECTIONS"
      resource = var.github_connection_arn
    }
    buildspec       = <<-YAML
      version: 0.2
      phases:
        build:
          commands:
            - echo "Replaced by GitHub Actions runner mode"
    YAML
  }

  # ★ VPC 연결 — 이것이 이 리소스의 존재 이유
  vpc_config {
    vpc_id             = nonsensitive(data.aws_ssm_parameter.vpc_id_for_runner[0].value)
    subnets            = split(",", nonsensitive(data.aws_ssm_parameter.private_subnet_ids_for_runner[0].value))
    security_group_ids = [aws_security_group.codebuild_runner[0].id]
  }

  logs_config {
    cloudwatch_logs {
      group_name = "/aws/codebuild/${var.project_name}-gha-deploy-runner"
    }
  }

  tags = { Name = "${var.project_name}-gha-deploy-runner" }
}

# ── 웹훅 — 러너 기동 트리거 (P0-1) ────────────────────────
# ★ 필터가 WORKFLOW_JOB_QUEUED 여야 한다. 다른 이벤트 타입이면
#   job 이 큐에서 영원히 움직이지 않는다(가장 흔한 함정).
resource "aws_codebuild_webhook" "gha_runner" {
  count        = var.codebuild_runner_enabled ? 1 : 0
  project_name = aws_codebuild_project.gha_runner[0].name
  build_type   = "BUILD"

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "WORKFLOW_JOB_QUEUED"
    }
  }
}

# ── 러너 SG ID 발행 (P0-2) ────────────────────────────────
# 04-eks 가 이 값을 읽어 EKS 클러스터 SG 에 인바운드 443 을 연다.
# 프라이빗 서브넷 배치만으로는 API 에 도달하지 않는다 —
# #13(노드 SG self-ingress 부재)과 같은 계열: "네트워크 배치 ≠ 도달 가능성".
resource "aws_ssm_parameter" "codebuild_runner_sg_id" {
  count       = var.codebuild_runner_enabled ? 1 : 0
  name        = "/${var.project_name}/security/codebuild_runner_sg_id"
  description = "CodeBuild deploy runner SG — consumed by 04-eks for cluster SG ingress"
  type        = "String"
  value       = try(aws_security_group.codebuild_runner[0].id, null)

  tags = { Name = "${var.project_name}-codebuild-runner-sg-id" }
}

# ── Stage 6-B 입력값 ──────────────────────────────────────
# 변수 선언은 variables.tf 에 중앙화한다.
# - codebuild_runner_enabled
# - github_repo_url
# - github_connection_arn
#
# ⚠ Stage 6-B 수동 작업 (Terraform 밖):
#   1) CodeConnections 연결 생성·승인
#   2) codebuild_runner_enabled=true + github_repo_url/github_connection_arn 입력
#   3) 레포 Variables: CODEBUILD_RUNNER / AWS_DEPLOY_ROLE_ARN / DEPLOY_ENABLED=true
#   (Stage 6-A에서는 기본 false라 이 입력들이 필요 없다. 웹훅은 Terraform이 생성한다.)

output "codebuild_runner_project_name" {
  description = "워크플로 runs-on 에 사용할 CodeBuild 프로젝트 이름"
  value       = try(aws_codebuild_project.gha_runner[0].name, null)
}

output "codebuild_runner_sg_id" {
  description = "러너 SG (04-eks 가 SSM 으로 읽어 클러스터 SG 인바운드에 사용)"
  value       = try(aws_security_group.codebuild_runner[0].id, null)
}
