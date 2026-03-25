output "worker_security_group_id" {
  description = "Security group ID of the worker task. Add this to the RDS ingress rules."
  value       = aws_security_group.worker.id
}

output "worker_service_name" {
  description = "ECS worker service name — used by CI/CD to force a redeployment."
  value       = aws_ecs_service.worker.name
}

output "worker_task_role_name" {
  description = "IAM task role name for the worker (attach extra policies if needed)."
  value       = aws_iam_role.task.name
}

output "worker_log_group_name" {
  description = "CloudWatch log group for worker container output."
  value       = aws_cloudwatch_log_group.worker.name
}
