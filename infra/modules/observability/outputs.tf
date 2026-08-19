output "log_group_name" {
  description = "CloudWatch log group name."
  value       = var.log_group_name
}

output "log_group_arn" {
  description = "CloudWatch log group ARN."
  value       = try(aws_cloudwatch_log_group.app[0].arn, null)
}

output "dashboard_name" {
  description = "CloudWatch operations dashboard name."
  value       = aws_cloudwatch_dashboard.service.dashboard_name
}
