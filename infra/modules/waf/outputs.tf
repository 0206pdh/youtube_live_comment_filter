output "web_acl_arn" {
  description = "WAF web ACL ARN."
  value       = aws_wafv2_web_acl.this.arn
}

output "web_acl_name" {
  description = "WAF web ACL name."
  value       = aws_wafv2_web_acl.this.name
}
