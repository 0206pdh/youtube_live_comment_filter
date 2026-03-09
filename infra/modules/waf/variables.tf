variable "name" {
  description = "Base name used for the WAF web ACL."
  type        = string
}

variable "resource_arn" {
  description = "ARN of the protected resource, initially the public ALB."
  type        = string
}

variable "enable_ip_rate_limit" {
  description = "Whether to enable a coarse IP-based rate limit rule."
  type        = bool
  default     = true
}

variable "ip_rate_limit" {
  description = "Maximum requests per 5-minute window per IP before WAF blocks."
  type        = number
  default     = 2000
}
