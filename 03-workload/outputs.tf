# ============================================================
# 03-workload/outputs.tf
# ============================================================

output "alb_dns_name" {
  description = "ALB DNS"
  value       = aws_lb.main.dns_name
}

output "cloudfront_domain" {
  description = "CloudFront 도메인"
  value       = aws_cloudfront_distribution.main.domain_name
}

output "ec2_instance_id" {
  description = "EC2 Instance ID (SSM 접속용)"
  value       = aws_instance.web_test.id
}

output "nat_gateway_ip" {
  description = "NAT Gateway Public IP"
  value       = aws_eip.nat.public_ip
}

output "site_url" {
  description = "사이트 접속 URL"
  value       = "https://${var.domain_name}"
}
