variable "log_group_name" {
  description = "CloudWatch log group name for the application."
  type        = string
}

variable "retention_in_days" {
  description = "How long CloudWatch should retain application logs."
  type        = number
  default     = 30
}
