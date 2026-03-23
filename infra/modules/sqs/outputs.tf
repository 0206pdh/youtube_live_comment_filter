output "queue_url" {
  description = "SQS queue URL used by producers and consumers."
  value       = aws_sqs_queue.this.url
}

output "queue_arn" {
  description = "SQS queue ARN used for IAM policy statements."
  value       = aws_sqs_queue.this.arn
}

output "dlq_arn" {
  description = "Dead-letter queue ARN."
  value       = aws_sqs_queue.dlq.arn
}
