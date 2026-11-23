# 배포 job 전용 러너. GitHub 호스티드 러너는 EKS 엔드포인트 허용 목록(관리자 IP) 밖이라, VPC 안에서 job마다 새로 뜨는 CodeBuild 러너를 쓴다.
# AWS와 GitHub 연결은 CodeConnections(GitHub App 단기 토큰)로 한다. PAT를 쓰면 장기 자격증명이 생긴다.

data "aws_ssm_parameter" "private_subnet_ids_for_runner" {
  name = "/${var.project_name}/network/private_subnet_ids"
}

data "aws_ssm_parameter" "vpc_id_for_runner" {
  name = "/${var.project_name}/network/vpc_id"
}

# 인바운드 없음. 러너가 GitHub에서 job을 가져오는 쪽이다.
resource "aws_security_group" "codebuild_runner" {
  name        = "${var.project_name}-codebuild-runner"
  description = "Ephemeral GitHub Actions runner for EKS deploy (egress only)"
  vpc_id      = nonsensitive(data.aws_ssm_parameter.vpc_id_for_runner.value)

  egress {
    description = "HTTPS to EKS API, ECR, GitHub, AWS APIs (via NAT)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-codebuild-runner" }
}

# 러너 배관(ENI·로그·연결) 전용 역할. 배포 권한은 안 싣는다. 클러스터 접근은 워크플로가 OIDC로 deploy 역할을 받아서 하니까,
# 러너가 뚫려도 그것만으로는 클러스터 권한이 없다.
data "aws_iam_policy_document" "codebuild_runner_trust" {
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
  name               = "${var.project_name}-codebuild-runner"
  assume_role_policy = data.aws_iam_policy_document.codebuild_runner_trust.json

  tags = { Name = "${var.project_name}-codebuild-runner" }
}

data "aws_iam_policy_document" "codebuild_runner" {
  #checkov:skip=CKV_AWS_111,CKV_AWS_356:VpcEni 의 ec2:CreateNetworkInterface·DeleteNetworkInterface 는 AWS CodeBuild 문서의 VPC 서비스 역할 권장 정책 그대로(빌드마다 CodeBuild 가 ENI 생성·삭제). 위임 경로 CreateNetworkInterfacePermission 은 서브넷·서비스 조건으로 핀포인트돼 있다
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      # Log group 자체와 그 아래 log stream. CreateLogStream/PutLogEvents는 :* 범위가 필요하다.
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.project_name}-*",
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.project_name}-*:log-stream:*",
    ]
  }

  # 프라이빗 서브넷에 붙을 때 쓰는 ENI 권한. CreateNetworkInterfacePermission은 아래 조건으로 좁힌다.
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
    resources = ["*"]  # 이 API들은 리소스 수준 제한을 지원하지 않는다
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

    # AuthorizedService만으로는 모든 서브넷이 허용된다. ec2:Subnet으로 이 프로젝트 서브넷만 남긴다.
    condition {
      test     = "ArnEquals"
      variable = "ec2:Subnet"
      values = [
        for id in split(",", nonsensitive(data.aws_ssm_parameter.private_subnet_ids_for_runner.value)) :
        "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:subnet/${id}"
      ]
    }
  }

  # 지정한 CodeConnections 연결 하나만 쓸 수 있다.
  statement {
    sid    = "UseGitHubConnectionOnly"
    effect = "Allow"
    actions = [
      "codeconnections:GetConnection",
      "codeconnections:GetConnectionToken",
      "codeconnections:UseConnection",
      # 레거시 네임스페이스도 같이 넣는다(프로바이더/리전에 따라 codestar-connections를 쓴다).
      "codestar-connections:GetConnection",
      "codestar-connections:GetConnectionToken",
      "codestar-connections:UseConnection",
    ]
    resources = [var.github_connection_arn]
  }

  # 일부러 안 준 권한: eks:* / ecr:* / sts:AssumeRole. 러너 자체는 클러스터·레지스트리 권한이 없다.
}

resource "aws_iam_role_policy" "codebuild_runner" {
  name   = "${var.project_name}-codebuild-runner"
  role   = aws_iam_role.codebuild_runner.id
  policy = data.aws_iam_policy_document.codebuild_runner.json
}

# CodeBuild 프로젝트(러너 모드)
# source = GITHUB + CODECONNECTIONS. WORKFLOW_JOB_QUEUED webhook이 job을 띄운다.
# buildspec은 러너 모드에서 형식상 있을 뿐이고, 실제 job 내용은 GitHub Actions가 정한다.
locals {
  gha_runner_buildspec = <<-YAML
    version: 0.2
    phases:
      build:
        commands:
          - echo "Replaced by GitHub Actions runner mode"
  YAML
}

resource "aws_codebuild_project" "gha_runner" {
  name          = "${var.project_name}-gha-deploy-runner"
  description   = "Ephemeral GitHub Actions runner for EKS deploy jobs (S6-B)"
  service_role  = aws_iam_role.codebuild_runner.arn
  build_timeout = 20

  artifacts { type = "NO_ARTIFACTS" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"
  }

  # source는 GITHUB여야 한다. NO_SOURCE에는 웹훅을 못 붙여서 러너가 안 뜬다.
  # 실행 내용은 워크플로가 정한다.
  source {
    type            = "GITHUB"
    location        = var.github_repo_url
    git_clone_depth = 1

    # IAM의 연결 사용 권한과는 별개로, 실제 인증을 이어 주는 건 이 auth 블록이다(GitHub App 단기 토큰, PAT 없음).
    auth {
      type     = "CODECONNECTIONS"
      resource = var.github_connection_arn
    }
    # 줄바꿈 정규화. Windows(CRLF)에서는 heredoc에 CR이 남아서 AWS·CI 값과 달라진다(athena.tf와 같은 처리).
    # trimspace는 안 쓴다. 지금 저장된 값(끝 줄바꿈 포함)과 같아야 변경이 없다.
    buildspec = replace(local.gha_runner_buildspec, "\r", "")
  }

  vpc_config {
    vpc_id             = nonsensitive(data.aws_ssm_parameter.vpc_id_for_runner.value)
    subnets            = split(",", nonsensitive(data.aws_ssm_parameter.private_subnet_ids_for_runner.value))
    security_group_ids = [aws_security_group.codebuild_runner.id]
  }

  logs_config {
    cloudwatch_logs {
      group_name = "/aws/codebuild/${var.project_name}-gha-deploy-runner"
    }
  }

  tags = { Name = "${var.project_name}-gha-deploy-runner" }
}

# 필터는 WORKFLOW_JOB_QUEUED여야 한다. 다른 이벤트면 job이 큐에서 안 움직인다.
resource "aws_codebuild_webhook" "gha_runner" {
  project_name = aws_codebuild_project.gha_runner.name
  build_type   = "BUILD"

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "WORKFLOW_JOB_QUEUED"
    }
  }
}

# 러너 SG ID 발행
# 04-eks가 이 값을 읽어서 EKS 클러스터 SG에 인바운드 443을 연다.
# 프라이빗 서브넷에 두는 것만으로는 API에 닿지 않는다.
resource "aws_ssm_parameter" "codebuild_runner_sg_id" {
  name        = "/${var.project_name}/security/codebuild_runner_sg_id"
  description = "CodeBuild deploy runner SG — consumed by 04-eks for cluster SG ingress"
  type        = "String"
  value       = aws_security_group.codebuild_runner.id

  tags = { Name = "${var.project_name}-codebuild-runner-sg-id" }
}

output "codebuild_runner_project_name" {
  description = "워크플로 runs-on 에 사용할 CodeBuild 프로젝트 이름"
  value       = aws_codebuild_project.gha_runner.name
}

output "codebuild_runner_sg_id" {
  description = "러너 SG (04-eks 가 SSM 으로 읽어 클러스터 SG 인바운드에 사용)"
  value       = aws_security_group.codebuild_runner.id
}
