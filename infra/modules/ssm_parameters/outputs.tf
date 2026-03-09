output "parameter_arns" {
  description = "ARNs of created parameters keyed by logical name."
  value       = { for key, param in aws_ssm_parameter.this : key => param.arn }
}

output "parameter_names" {
  description = "Names of created parameters keyed by logical name."
  value       = { for key, param in aws_ssm_parameter.this : key => param.name }
}
