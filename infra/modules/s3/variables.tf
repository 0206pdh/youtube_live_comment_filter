variable "bucket_name" {
  description = "S3 bucket name for training data storage."
  type        = string
}

variable "force_destroy" {
  description = "Allow bucket deletion even when it contains objects."
  type        = bool
  default     = false
}

variable "training_data_retention_days" {
  description = "Days before training data objects are expired."
  type        = number
  default     = 365
}
