variable "name" {
  description = "ECR repository name."
  type        = string
}

variable "image_tag_mutability" {
  description = "Whether tags such as latest can be overwritten."
  type        = string
  default     = "MUTABLE"
}

variable "scan_on_push" {
  description = "Enable image vulnerability scanning on every push."
  type        = bool
  default     = true
}

variable "lifecycle_keep_last" {
  description = "Number of recent images to keep before lifecycle cleanup."
  type        = number
  default     = 30
}
