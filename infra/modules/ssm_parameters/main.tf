# These parameters are used by the ECS task definition as secrets/config.
# SecureString should be overwritten with real values through the console,
# CLI, or a secure CI step before exposing the service publicly.
resource "aws_ssm_parameter" "this" {
  for_each = var.parameters

  name        = each.value.name
  description = each.value.description
  type        = each.value.type
  value       = each.value.value
  overwrite   = true

  tags = {
    Name = each.value.name
  }
}
