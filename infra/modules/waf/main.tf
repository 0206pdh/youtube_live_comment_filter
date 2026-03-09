# WAF is attached to the ALB first because that is the resource type with the
# least integration risk in Phase 1. Once the edge design matures, this ACL can
# either remain on the ALB as defense-in-depth or be complemented by additional
# protections at API Gateway.
resource "aws_wafv2_web_acl" "this" {
  name  = "${var.name}-web-acl"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-web-acl"
    sampled_requests_enabled   = true
  }

  # Managed rules provide a reasonable baseline without custom signature work.
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-common"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = var.enable_ip_rate_limit ? [1] : []
    content {
      name     = "IpRateLimit"
      priority = 2

      action {
        block {}
      }

      statement {
        rate_based_statement {
          aggregate_key_type = "IP"
          limit              = var.ip_rate_limit
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name}-ip-rate"
        sampled_requests_enabled   = true
      }
    }
  }
}

resource "aws_wafv2_web_acl_association" "this" {
  resource_arn = var.resource_arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}
