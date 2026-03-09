variable "name" {
  description = "Base name used for GitHub OIDC IAM roles."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository in owner/name format."
  type        = string
}

variable "oidc_provider_arn" {
  description = "Existing GitHub OIDC provider ARN in the target AWS account."
  type        = string
}

variable "terraform_state_bucket_arn" {
  description = "S3 bucket ARN used for Terraform remote state."
  type        = string
  default     = ""
}

variable "terraform_lock_table_arn" {
  description = "DynamoDB table ARN used for Terraform state locking."
  type        = string
  default     = ""
}

variable "ssm_parameter_arns" {
  description = "SSM parameters that GitHub workflows are allowed to read."
  type        = list(string)
  default     = []
}

variable "ecr_repository_arns" {
  description = "ECR repositories used by application deployment workflows."
  type        = list(string)
  default     = []
}

variable "ecs_cluster_arns" {
  description = "ECS cluster ARNs deployment workflows can operate on."
  type        = list(string)
  default     = []
}

variable "ecs_service_arns" {
  description = "ECS service ARNs deployment workflows can update."
  type        = list(string)
  default     = []
}
