terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project = "youtube-live-comment-filter"
      Env     = "prod"
      Managed = "terraform"
    }
  }
}

locals {
  app_name       = var.project_name
  log_group_name = "/ecs/${local.app_name}"
  api_allowed_origins = [
    for extension_id in var.allowed_extension_ids : "chrome-extension://${extension_id}"
  ]
}

module "network" {
  source = "../../modules/network"

  name                 = local.app_name
  vpc_cidr             = "10.50.0.0/16"
  availability_zones   = ["${var.aws_region}a", "${var.aws_region}c"]
  public_subnet_cidrs  = ["10.50.1.0/24", "10.50.2.0/24"]
  private_subnet_cidrs = ["10.50.11.0/24", "10.50.12.0/24"]
}

module "ecr" {
  source = "../../modules/ecr"
  name   = "${local.app_name}-api"
}

module "observability" {
  source         = "../../modules/observability"
  log_group_name = local.log_group_name
  retention_in_days = 90
}

module "ssm_parameters" {
  source = "../../modules/ssm_parameters"

  parameters = {
    api_key = {
      name        = "/${local.app_name}/api/API_KEY"
      description = "Shared API key used by the extension in prod."
      type        = "SecureString"
      value       = var.api_key_placeholder
    }
  }
}

module "ecs_service" {
  source = "../../modules/ecs_service"

  name               = local.app_name
  aws_region         = var.aws_region
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids
  log_group_name     = module.observability.log_group_name
  desired_count      = 2

  container_image = "${module.ecr.repository_url}:latest"

  environment = {
    HOST                         = "0.0.0.0"
    PORT                         = "8000"
    LOG_LEVEL                    = "INFO"
    LOG_PREDICTIONS              = "false"
    ENABLE_TRAFFIC_METRICS       = "true"
    METRICS_LOG_INTERVAL_SECONDS = "60"
    ENABLE_RATE_LIMIT            = "true"
    RATE_LIMIT_WINDOW_SECONDS    = "60"
    PREDICT_RATE_LIMIT           = "120"
    LOOKUP_RATE_LIMIT            = "180"
    TRAINING_DATA_RATE_LIMIT     = "30"
    ENFORCE_AUTH                 = "true"
    ALLOWED_ORIGINS              = ""
    ALLOWED_EXTENSION_IDS        = join(",", var.allowed_extension_ids)
  }

  secrets = {
    API_KEY = module.ssm_parameters.parameter_arns["api_key"]
  }
}

module "api_gateway" {
  source = "../../modules/api_gateway"

  name            = local.app_name
  target_base_url = "http://${module.ecs_service.alb_dns_name}"
  allowed_origins = local.api_allowed_origins
}

module "waf" {
  source = "../../modules/waf"

  name          = local.app_name
  resource_arn  = module.ecs_service.alb_arn
  ip_rate_limit = 5000
}

# OIDC roles are created in prod because production is where secretless CI/CD
# becomes non-negotiable. Dev can reuse the same pattern once the account-side
# trust relationship is validated.
module "github_oidc_roles" {
  count  = var.oidc_provider_arn != "" ? 1 : 0
  source = "../../modules/github_oidc_roles"

  name                       = local.app_name
  github_repository          = var.github_repository
  oidc_provider_arn          = var.oidc_provider_arn
  terraform_state_bucket_arn = var.terraform_state_bucket_arn
  terraform_lock_table_arn   = var.terraform_lock_table_arn
  ssm_parameter_arns         = [module.ssm_parameters.parameter_arns["api_key"]]
  ecr_repository_arns        = [module.ecr.repository_arn]
  ecs_cluster_arns           = [module.ecs_service.cluster_arn]
  ecs_service_arns           = [module.ecs_service.service_arn]
}

output "api_gateway_endpoint" {
  description = "Primary public endpoint that the extension should call in prod."
  value       = module.api_gateway.api_endpoint
}

output "alb_dns_name" {
  description = "Direct ALB endpoint kept for diagnostics and health checks."
  value       = module.ecs_service.alb_dns_name
}

output "ecr_repository_url" {
  description = "Repository URL used by CI for docker pushes."
  value       = module.ecr.repository_url
}

output "waf_web_acl_name" {
  description = "WAF ACL attached to the ALB for baseline request filtering."
  value       = module.waf.web_acl_name
}

output "terraform_role_arn" {
  description = "IAM role ARN assumed by the Terraform GitHub workflow."
  value       = try(module.github_oidc_roles[0].terraform_role_arn, null)
}

output "deploy_role_arn" {
  description = "IAM role ARN assumed by the application deploy workflow."
  value       = try(module.github_oidc_roles[0].deploy_role_arn, null)
}
