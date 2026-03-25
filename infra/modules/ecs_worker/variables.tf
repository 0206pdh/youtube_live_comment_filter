variable "name" {
  description = "Identifier prefix for all worker resources."
  type        = string
}

variable "aws_region" {
  description = "AWS region where resources are deployed."
  type        = string
}

variable "vpc_id" {
  description = "VPC where the worker Fargate task runs."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the worker Fargate task."
  type        = list(string)
}

variable "assign_public_ip" {
  description = "Assign a public IP to the worker (required when using public subnets without NAT)."
  type        = bool
  default     = false
}

variable "cluster_id" {
  description = "ECS cluster ID to run the worker in."
  type        = string
}

variable "container_image" {
  description = "Docker image URI for the worker container (same image as API, different CMD)."
  type        = string
}

variable "cpu" {
  description = "Fargate task CPU units. 1024 = 1 vCPU."
  type        = number
  default     = 1024
}

variable "memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 2048
}

variable "desired_count" {
  description = "Number of worker tasks. 0 pauses the worker without destroying it."
  type        = number
  default     = 1
}

variable "log_retention_days" {
  description = "Days to retain worker logs in CloudWatch."
  type        = number
  default     = 30
}

variable "training_data_bucket_arn" {
  description = "ARN of the S3 bucket that holds training-data/ and models/."
  type        = string
}

variable "training_queue_arn" {
  description = "ARN of the SQS training queue the worker consumes."
  type        = string
}

variable "environment" {
  description = "Plain-text environment variables for the worker container."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "SSM Parameter ARNs injected as container secrets (env name → SSM ARN)."
  type        = map(string)
  default     = {}
}

variable "secret_arns" {
  description = "Flat list of SSM Parameter ARNs the execution role is allowed to read."
  type        = list(string)
  default     = []
}
