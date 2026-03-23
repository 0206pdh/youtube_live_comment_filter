variable "name" {
  description = "SQS queue name."
  type        = string
}

variable "visibility_timeout_seconds" {
  description = "Seconds a message is hidden after being received."
  type        = number
  default     = 900 # 15 minutes — enough time for a training job
}

variable "message_retention_seconds" {
  description = "Seconds a message stays in the queue if not consumed."
  type        = number
  default     = 86400 # 1 day
}

variable "max_receive_count" {
  description = "Number of receives before a message moves to the DLQ."
  type        = number
  default     = 3
}
