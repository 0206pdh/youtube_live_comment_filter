locals {
  private_integration = var.target_listener_arn != ""
}

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

resource "aws_security_group" "vpc_link" {
  count = local.private_integration ? 1 : 0

  name_prefix = "${var.name}-apigw-vpclink-"
  description = "API Gateway VPC Link egress to the internal ALB."
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_apigatewayv2_vpc_link" "this" {
  count = local.private_integration ? 1 : 0

  name               = "${var.name}-vpc-link"
  subnet_ids         = var.vpc_link_subnet_ids
  security_group_ids = [aws_security_group.vpc_link[0].id]
}

resource "aws_apigatewayv2_integration" "proxy" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = local.private_integration ? var.target_listener_arn : var.target_base_url
  connection_type        = local.private_integration ? "VPC_LINK" : "INTERNET"
  connection_id          = local.private_integration ? aws_apigatewayv2_vpc_link.this[0].id : null
  payload_format_version = "1.0"
  timeout_milliseconds   = 29000

  request_parameters = {
    "overwrite:path" = "$request.path"
  }
}

# Forward every path to the internal ALB through VPC Link.
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
    throttling_burst_limit   = var.throttling_burst_limit
    throttling_rate_limit    = var.throttling_rate_limit
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
