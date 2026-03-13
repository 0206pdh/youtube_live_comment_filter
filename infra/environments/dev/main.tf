terraform {
  required_version = ">= 1.6.0"

  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # The real backend should be enabled before collaborative usage begins.
  # For the first local bootstrap you can rely on the default local backend,
  # then move the state file into S3 once the bootstrap bucket exists.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project = "youtube-live-comment-filter"
      Env     = "dev"
      Managed = "terraform"
    }
  }
}

locals {
  app_name       = var.project_name
  log_group_name = "/ecs/${local.app_name}"
  api_allowed_origins = concat(
    ["http://localhost", "http://127.0.0.1"],
    [for extension_id in var.allowed_extension_ids : "chrome-extension://${extension_id}"]
  )
}

module "network" {
  source = "../../modules/network"

  name                 = local.app_name
  vpc_cidr             = "10.40.0.0/16"
  availability_zones   = ["${var.aws_region}a", "${var.aws_region}c"]
  public_subnet_cidrs  = ["10.40.1.0/24", "10.40.2.0/24"]
  private_subnet_cidrs = ["10.40.11.0/24", "10.40.12.0/24"]
}

module "ecr" {
  source = "../../modules/ecr"
  name   = "${local.app_name}-api"
}

module "observability" {
  source         = "../../modules/observability"
  log_group_name = local.log_group_name
}

module "ssm_parameters" {
  source = "../../modules/ssm_parameters"

  parameters = {
    api_key = {
      name        = "/${local.app_name}/api/API_KEY"
      description = "Shared API key used by the extension in dev."
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

  # Phase 1 deploys latest for dev simplicity. CI later pushes both latest and
  # immutable SHA tags. Production rollout should use immutable tags only.
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
    ALLOWED_ORIGINS              = "http://localhost,http://127.0.0.1"
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

  name         = local.app_name
  resource_arn = module.ecs_service.alb_arn
}

# Dev also gets OIDC roles so GitHub Actions can run against the dev account
# without long-lived static AWS keys. This keeps the dev workflow aligned with
# the eventual prod operating model rather than using a one-off auth pattern.
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

output "alb_dns_name" {
  description = "Direct ALB endpoint kept for diagnostics and health checks."
  value       = module.ecs_service.alb_dns_name
}

output "api_gateway_endpoint" {
  description = "Primary public endpoint that the extension should call in dev."
  value       = module.api_gateway.api_endpoint
}

output "ecr_repository_url" {
  description = "Repository URL used by CI for docker pushes."
  value       = module.ecr.repository_url
}

output "ecs_cluster_name" {
  description = "Cluster name used by the app deployment workflow."
  value       = module.ecs_service.cluster_name
}

output "ecs_service_name" {
  description = "Service name used by the app deployment workflow."
  value       = module.ecs_service.service_name
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
