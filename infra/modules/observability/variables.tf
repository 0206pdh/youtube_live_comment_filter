variable "log_group_name" {
  description = "CloudWatch log group name for the application."
  type        = string
}

variable "retention_in_days" {
  description = "How long CloudWatch should retain application logs."
  type        = number
  default     = 30
}

variable "manage_log_group" {
  description = "Create the application log group inside this module. Disable when the environment owns it to avoid dependency cycles."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Phase 4: CloudWatch Alarms
# ---------------------------------------------------------------------------

variable "enable_alarms" {
  description = "Create CloudWatch alarms. Set false in environments without an SNS topic."
  type        = bool
  default     = true
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix (the part after 'loadbalancer/'). Used for 5xx metrics."
  type        = string
  default     = ""
}

variable "ecs_cluster_name" {
  description = "ECS cluster name. Used for running-task-count alarms."
  type        = string
  default     = ""
}

variable "ecs_service_name" {
  description = "ECS API service name. Used for running-task-count alarms."
  type        = string
  default     = ""
}

variable "sqs_dlq_name" {
  description = "SQS dead-letter queue name. Alarm fires when messages accumulate."
  type        = string
  default     = ""
}

variable "sns_topic_arn" {
  description = "Optional SNS topic ARN for alarm notifications. Leave empty to skip."
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "AWS region displayed by dashboard widgets."
  type        = string
}

variable "dashboard_name" {
  description = "CloudWatch dashboard name."
  type        = string
}

variable "worker_service_name" {
  description = "ECS worker service name."
  type        = string
  default     = ""
}

variable "target_group_arn_suffix" {
  description = "ALB target group ARN suffix."
  type        = string
  default     = ""
}

variable "sqs_queue_name" {
  description = "Training queue name."
  type        = string
  default     = ""
}
