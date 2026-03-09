variable "name" {
  description = "Base name used for the HTTP API and its stage."
  type        = string
}

variable "target_base_url" {
  description = "Upstream base URL that API Gateway proxies to."
  type        = string
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
