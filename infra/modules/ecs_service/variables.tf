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

variable "private_subnet_ids" {
  description = "Private subnets used by ECS tasks."
  type        = list(string)
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
