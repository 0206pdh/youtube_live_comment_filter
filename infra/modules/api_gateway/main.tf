# Phase 1 keeps the API Gateway integration simple by proxying to the ALB's
# public endpoint. This avoids VPC Link complexity during the first dev rollout.
# In a later hardening step, the ALB can be made private and API Gateway can
# switch to a VPC Link without changing clients.
resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name}-http-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_headers = var.allowed_headers
    allow_methods = var.allowed_methods
    allow_origins = var.allowed_origins
    max_age       = 300
  }
}

resource "aws_apigatewayv2_integration" "proxy" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = var.target_base_url
  payload_format_version = "1.0"
  timeout_milliseconds   = 29000
}

# Forward every path to the upstream ALB. The ALB remains useful for health
# checks and future blue/green traffic shifting, while API Gateway becomes the
# public client-facing entry point.
resource "aws_apigatewayv2_route" "root" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "ANY /"
  target    = "integrations/${aws_apigatewayv2_integration.proxy.id}"
}

resource "aws_apigatewayv2_route" "proxy" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.proxy.id}"
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/apigw/${var.name}"
  retention_in_days = 30
}

resource "aws_apigatewayv2_stage" "this" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = var.stage_name
  auto_deploy = true

  default_route_settings {
    detailed_metrics_enabled = true
    throttling_burst_limit   = 200
    throttling_rate_limit    = 100
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.this.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }
}
