variable "aws_region" {
  description = "AWS region for the dev environment."
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "Project prefix used across AWS resources."
  type        = string
  default     = "ylcf-dev"
}

variable "github_repository" {
  description = "GitHub repository in owner/name format for OIDC trust later."
  type        = string
  default     = "owner/repo"
}

variable "allowed_extension_ids" {
  description = "Chrome extension ids allowed by the backend CORS configuration."
  type        = list(string)
  default     = []
}

variable "api_key_placeholder" {
  description = "Initial placeholder API key stored in SSM before secret rotation."
  type        = string
  sensitive   = true
  default     = "CHANGE_ME_BEFORE_PUBLIC_ACCESS"
}

variable "oidc_provider_arn" {
  description = "Existing GitHub OIDC provider ARN."
  type        = string
  default     = ""
}

variable "terraform_state_bucket_arn" {
  description = "Terraform remote state bucket ARN."
  type        = string
  default     = ""
}

variable "terraform_lock_table_arn" {
  description = "Terraform lock table ARN."
  type        = string
  default     = ""
}
