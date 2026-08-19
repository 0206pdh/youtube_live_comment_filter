variable "name" {
  description = "Base name used for the HTTP API and its stage."
  type        = string
}

variable "target_base_url" {
  description = "Upstream base URL that API Gateway proxies to."
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "VPC used by the private integration. Required when target_listener_arn is set."
  type        = string
  default     = ""
}

variable "vpc_link_subnet_ids" {
  description = "Private subnets used by API Gateway VPC Link ENIs."
  type        = list(string)
  default     = []
}

variable "target_listener_arn" {
  description = "Internal ALB listener ARN for an HTTP API private integration."
  type        = string
  default     = ""
}

variable "stage_name" {
  description = "Stage name exposed by API Gateway."
  type        = string
  default     = "$default"
}

variable "allowed_origins" {
  description = "CORS origins allowed by API Gateway."
  type        = list(string)
  default     = []
}

variable "allowed_headers" {
  description = "CORS headers allowed by API Gateway."
  type        = list(string)
  default     = ["authorization", "content-type", "x-api-key"]
}

variable "allowed_methods" {
  description = "CORS methods allowed by API Gateway."
  type        = list(string)
  default     = ["GET", "POST", "DELETE", "OPTIONS"]
}

variable "throttling_rate_limit" {
  description = "Steady-state request rate limit for the HTTP API stage."
  type        = number
  default     = 1000
}

variable "throttling_burst_limit" {
  description = "Burst request limit for the HTTP API stage."
  type        = number
  default     = 2000
}
