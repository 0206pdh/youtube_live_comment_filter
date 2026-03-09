output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.this.arn
}

output "service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.this.name
}

output "service_arn" {
  description = "ECS service ARN."
  value       = aws_ecs_service.this.id
}

output "task_family" {
  description = "Task definition family."
  value       = aws_ecs_task_definition.this.family
}

output "alb_dns_name" {
  description = "Public ALB DNS name for dev validation."
  value       = aws_lb.this.dns_name
}

output "alb_arn" {
  description = "ALB ARN used by WAF associations and future edge integrations."
  value       = aws_lb.this.arn
}

output "alb_zone_id" {
  description = "Hosted zone id of the ALB for future Route53 aliases."
  value       = aws_lb.this.zone_id
}
