variable "name" {
  description = "Base name for ECS, ALB, and IAM resources."
  type        = string
}

variable "aws_region" {
  description = "AWS region used for logs and image pulls."
  type        = string
}

variable "vpc_id" {
  description = "VPC id where ALB and ECS will run."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets used by the ALB."
  type        = list(string)
}

variable "alb_internal" {
  description = "Create an internal ALB for API Gateway VPC Link integration."
  type        = bool
  default     = true
}

variable "alb_ingress_cidrs" {
  description = "CIDRs allowed to reach the ALB listener. Use the VPC CIDR for a private ALB."
  type        = list(string)
  default     = []
}

variable "private_subnet_ids" {
  description = "Private subnets used by ECS tasks (default) or passed through to task_subnet_ids."
  type        = list(string)
}

variable "task_subnet_ids" {
  description = "Subnets where ECS tasks run. Defaults to private_subnet_ids. Override with public subnets when NAT Gateway is absent."
  type        = list(string)
  default     = []
}

variable "assign_public_ip" {
  description = "Assign a public IP to ECS tasks. Required when tasks run in public subnets without a NAT Gateway."
  type        = bool
  default     = false
}

variable "container_image" {
  description = "Container image URI deployed into ECS."
  type        = string
}

variable "container_port" {
  description = "Container port exposed by the FastAPI application."
  type        = number
  default     = 8000
}

variable "desired_count" {
  description = "Desired ECS task count."
  type        = number
  default     = 1
}

variable "autoscaling_min_capacity" {
  description = "Minimum number of API tasks."
  type        = number
  default     = 2
}

variable "autoscaling_max_capacity" {
  description = "Maximum number of API tasks."
  type        = number
  default     = 10
}

variable "autoscaling_cpu_target" {
  description = "Target average ECS CPU utilization percentage."
  type        = number
  default     = 55
}

variable "cpu" {
  description = "Task CPU units."
  type        = number
  default     = 512
}

variable "memory" {
  description = "Task memory in MiB."
  type        = number
  default     = 1024
}

variable "log_group_name" {
  description = "CloudWatch log group name."
  type        = string
}

variable "environment" {
  description = "Plain-text environment variables for the container."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Secrets injected from SSM Parameter Store."
  type        = map(string)
  default     = {}
}
