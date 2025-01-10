output "alb_endpoint_uri" {
  value = aws_lb.mission_app.dns_name
}

output "alb_endpoint_url" {
  value = "https://${aws_lb.mission_app.dns_name}"
}

output "cloudfront_endpoint_url" {
  value = "https://${aws_cloudfront_distribution.mission_app.domain_name}"
}