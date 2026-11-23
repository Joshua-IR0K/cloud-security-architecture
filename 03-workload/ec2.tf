data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_iam_role" "ec2_ssm" {
  name = "${var.project_name}-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "${var.project_name}-ec2-ssm-profile"
  role = aws_iam_role.ec2_ssm.name
}

resource "aws_instance" "web_test" {
  #checkov:skip=CKV_AWS_126:EKS 전환 전 경로이자 롤백 대상 EC2 — 상세 모니터링 비용을 들이지 않음
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.ec2_instance_type
  subnet_id              = local.private_subnet_ids[0]
  vpc_security_group_ids = [local.app_sg_id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name

  # EBS 최적화를 명시한다(t3는 기본으로 켜져 있지만 CKV_AWS_135 때문에 적어 둔다).
  ebs_optimized = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = <<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y nginx
    systemctl enable nginx
    systemctl start nginx

    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
    AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)

    cat > /usr/share/nginx/html/index.html << HTML
    <!DOCTYPE html>
    <html>
    <head><title>DMZ Walking Skeleton</title></head>
    <body style="font-family:monospace;background:#0B1120;color:#22D3EE;display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
      <div style="text-align:center">
        <h1>DMZ VPC Architecture - Walking Skeleton</h1>
        <p>Private Subnet EC2 → ALB 통신 성공!</p>
        <p>Instance ID: $INSTANCE_ID</p>
        <p>AZ: $AZ</p>
        <p style="color:#10B981;margin-top:20px">✓ Stack-separated architecture working</p>
      </div>
    </body>
    </html>
    HTML
  EOF

  user_data_replace_on_change = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    encrypted             = true
    kms_key_id            = local.ebs_kms_key_arn # 02-security의 EBS 전용 CMK
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project_name}-web-test"
    Role = "walking-skeleton"
  }
}
