output "api_id" {
  description = "HTTP API id."
  value       = aws_apigatewayv2_api.this.id
}

output "api_endpoint" {
  description = "Public invoke URL for the HTTP API."
  value       = aws_apigatewayv2_stage.this.invoke_url
}

output "stage_name" {
  description = "API Gateway stage name."
  value       = aws_apigatewayv2_stage.this.name
}
