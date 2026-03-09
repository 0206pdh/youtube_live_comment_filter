output "terraform_role_arn" {
  description = "IAM role ARN assumed by the Terraform GitHub workflow."
  value       = aws_iam_role.terraform.arn
}

output "deploy_role_arn" {
  description = "IAM role ARN assumed by the application deploy workflow."
  value       = aws_iam_role.deploy.arn
}
