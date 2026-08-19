terraform {
  required_version = ">= 1.6.0"

  backend "s3" {}

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
  aws_region           = var.aws_region
  vpc_cidr             = "10.50.0.0/16"
  availability_zones   = ["${var.aws_region}a", "${var.aws_region}c"]
  public_subnet_cidrs  = ["10.50.1.0/24", "10.50.2.0/24"]
  private_subnet_cidrs = ["10.50.11.0/24", "10.50.12.0/24"]
}

resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group_name
  retention_in_days = 90
}

module "ecr" {
  source = "../../modules/ecr"
  name   = "${local.app_name}-api"
}

module "observability" {
  source                  = "../../modules/observability"
  log_group_name          = local.log_group_name
  manage_log_group        = false
  retention_in_days       = 90
  aws_region              = var.aws_region
  dashboard_name          = "${local.app_name}-operations"
  enable_alarms           = true
  alb_arn_suffix          = module.ecs_service.alb_arn_suffix
  target_group_arn_suffix = module.ecs_service.target_group_arn_suffix
  ecs_cluster_name        = module.ecs_service.cluster_name
  ecs_service_name        = module.ecs_service.service_name
  worker_service_name     = module.ecs_worker.worker_service_name
  sqs_queue_name          = module.sqs.queue_name
  sqs_dlq_name            = module.sqs.dlq_name
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
    db_password = {
      name        = "/${local.app_name}/db/DB_PASSWORD"
      description = "RDS master password for the production training metadata database."
      type        = "SecureString"
      value       = var.db_password
    }
  }
}

module "s3" {
  source = "../../modules/s3"

  bucket_name                  = "${local.app_name}-training-data"
  force_destroy                = false
  training_data_retention_days = 365
}

module "sqs" {
  source = "../../modules/sqs"

  name                       = "${local.app_name}-training-queue"
  visibility_timeout_seconds = 3600
  message_retention_seconds  = 1209600
}

module "rds" {
  source = "../../modules/rds"

  name                      = "${local.app_name}-db"
  vpc_id                    = module.network.vpc_id
  subnet_ids                = module.network.private_subnet_ids
  allowed_security_group_id = module.ecs_service.service_security_group_id
  db_password               = var.db_password
  instance_class            = "db.t3.small"
  allocated_storage         = 50
  backup_retention_days     = 14
  skip_final_snapshot       = false
  deletion_protection       = true
  multi_az                  = true
}

module "ecs_service" {
  source = "../../modules/ecs_service"

  name                     = local.app_name
  aws_region               = var.aws_region
  vpc_id                   = module.network.vpc_id
  public_subnet_ids        = module.network.public_subnet_ids
  private_subnet_ids       = module.network.private_subnet_ids
  log_group_name           = aws_cloudwatch_log_group.app.name
  alb_internal             = true
  alb_ingress_cidrs        = ["10.50.0.0/16"]
  task_subnet_ids          = module.network.private_subnet_ids
  assign_public_ip         = false
  desired_count            = 2
  autoscaling_min_capacity = 2
  autoscaling_max_capacity = 100
  autoscaling_cpu_target   = 55

  container_image = "${module.ecr.repository_url}:latest"
  cpu             = 4096
  memory          = 8192

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
    TRAINING_DATA_BUCKET         = module.s3.bucket_name
    TRAINING_QUEUE_URL           = module.sqs.queue_url
    DB_HOST                      = module.rds.host
    DB_PORT                      = tostring(module.rds.port)
    DB_NAME                      = module.rds.db_name
    DB_USER                      = "ylcf_admin"
  }

  secrets = {
    API_KEY     = module.ssm_parameters.parameter_arns["api_key"]
    DB_PASSWORD = module.ssm_parameters.parameter_arns["db_password"]
  }
}

resource "aws_iam_role_policy" "ecs_task_data" {
  name = "${local.app_name}-task-data-policy"
  role = module.ecs_service.task_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
        Resource = [module.s3.bucket_arn, "${module.s3.bucket_arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
        Resource = [module.sqs.queue_arn]
      }
    ]
  })
}

module "ecs_worker" {
  source = "../../modules/ecs_worker"

  name             = local.app_name
  aws_region       = var.aws_region
  vpc_id           = module.network.vpc_id
  subnet_ids       = module.network.private_subnet_ids
  assign_public_ip = false
  cluster_id       = module.ecs_service.cluster_arn
  container_image  = "${module.ecr.repository_url}:latest"
  cpu              = 4096
  memory           = 8192

  training_data_bucket_arn = module.s3.bucket_arn
  training_queue_arn       = module.sqs.queue_arn
  api_service_arn          = module.ecs_service.service_arn

  environment = {
    TRAINING_DATA_BUCKET = module.s3.bucket_name
    TRAINING_QUEUE_URL   = module.sqs.queue_url
    DB_HOST              = module.rds.host
    DB_PORT              = tostring(module.rds.port)
    DB_NAME              = module.rds.db_name
    DB_USER              = "ylcf_admin"
    MODEL_DIR            = "/app/model"
    AWS_DEFAULT_REGION   = var.aws_region
    LOG_LEVEL            = "INFO"
    ECS_CLUSTER          = module.ecs_service.cluster_name
    ECS_API_SERVICE      = module.ecs_service.service_name
  }

  secrets     = { DB_PASSWORD = module.ssm_parameters.parameter_arns["db_password"] }
  secret_arns = [module.ssm_parameters.parameter_arns["db_password"]]
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_worker" {
  security_group_id            = module.rds.security_group_id
  referenced_security_group_id = module.ecs_worker.worker_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

module "api_gateway" {
  source = "../../modules/api_gateway"

  name                   = local.app_name
  vpc_id                 = module.network.vpc_id
  vpc_link_subnet_ids    = module.network.private_subnet_ids
  target_listener_arn    = module.ecs_service.alb_listener_arn
  allowed_origins        = local.api_allowed_origins
  throttling_rate_limit  = 8000
  throttling_burst_limit = 10000
}

module "waf" {
  source = "../../modules/waf"

  name                 = local.app_name
  resource_arn         = module.ecs_service.alb_arn
  enable_ip_rate_limit = false
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
  ssm_parameter_arns         = values(module.ssm_parameters.parameter_arns)
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
