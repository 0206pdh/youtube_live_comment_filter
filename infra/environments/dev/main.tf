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

  # Phase 4: wire up CloudWatch alarms.
  # alb_arn_suffix is the part after "loadbalancer/" in the ALB ARN, which is
  # what the AWS/ApplicationELB metric dimension expects.
  enable_alarms    = true
  alb_arn_suffix   = split("loadbalancer/", module.ecs_service.alb_arn)[1]
  ecs_cluster_name = module.ecs_service.cluster_name
  ecs_service_name = module.ecs_service.service_name
  sqs_dlq_name     = module.sqs.dlq_name
  # sns_topic_arn left empty — notifications can be added when an SNS topic exists.
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
    db_password = {
      name        = "/${local.app_name}/db/DB_PASSWORD"
      description = "RDS master password for the training metadata database."
      type        = "SecureString"
      value       = var.db_password
    }
  }
}

module "s3" {
  source = "../../modules/s3"

  bucket_name   = "${local.app_name}-training-data"
  force_destroy = true # dev: allow clean teardown
}

module "sqs" {
  source = "../../modules/sqs"

  name = "${local.app_name}-training-queue"
}

module "rds" {
  source = "../../modules/rds"

  name                      = "${local.app_name}-db"
  vpc_id                    = module.network.vpc_id
  subnet_ids                = module.network.private_subnet_ids
  allowed_security_group_id = module.ecs_service.service_security_group_id
  db_password               = var.db_password
  skip_final_snapshot       = true
  deletion_protection       = false
}

module "ecs_service" {
  source = "../../modules/ecs_service"

  name               = local.app_name
  aws_region         = var.aws_region
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids
  log_group_name     = module.observability.log_group_name

  # Dev: run tasks in public subnets with public IP — no NAT Gateway needed.
  task_subnet_ids  = module.network.public_subnet_ids
  assign_public_ip = true

  # Phase 1 deploys latest for dev simplicity. CI later pushes both latest and
  # immutable SHA tags. Production rollout should use immutable tags only.
  container_image = "${module.ecr.repository_url}:latest"

  cpu    = 4096
  memory = 8192

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
    # Phase 2: S3 + SQS + RDS
    TRAINING_DATA_BUCKET = module.s3.bucket_name
    TRAINING_QUEUE_URL   = module.sqs.queue_url
    DB_HOST              = module.rds.host
    DB_PORT              = tostring(module.rds.port)
    DB_NAME              = module.rds.db_name
    DB_USER              = "ylcf_admin"
  }

  secrets = {
    API_KEY     = module.ssm_parameters.parameter_arns["api_key"]
    DB_PASSWORD = module.ssm_parameters.parameter_arns["db_password"]
  }
}

# Grant the ECS task role access to S3 and SQS for Phase 2 data pipeline.
resource "aws_iam_role_policy" "ecs_task_phase2" {
  name = "${local.app_name}-task-phase2-policy"
  role = module.ecs_service.task_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:DeleteObject",
        ]
        Resource = [
          module.s3.bucket_arn,
          "${module.s3.bucket_arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = [module.sqs.queue_arn]
      },
    ]
  })
}

# Allow the execution role to read the DB password from SSM.
resource "aws_iam_role_policy" "execution_db_ssm" {
  name = "${local.app_name}-execution-db-ssm"
  role = "${local.app_name}-execution-role"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameters", "ssm:GetParameter"]
        Resource = [module.ssm_parameters.parameter_arns["db_password"]]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Phase 3: Training Worker
# ---------------------------------------------------------------------------
# The worker runs the same Docker image as the API but overrides the CMD to
# run worker.py. It consumes jobs from the SQS training queue so that BERT
# fine-tuning never competes with /predict for CPU on the API tasks.

module "ecs_worker" {
  source = "../../modules/ecs_worker"

  name       = local.app_name
  aws_region = var.aws_region
  vpc_id     = module.network.vpc_id

  # Dev: public subnets, public IP (no NAT Gateway) — same pattern as API.
  subnet_ids       = module.network.public_subnet_ids
  assign_public_ip = true

  cluster_id      = module.ecs_service.cluster_arn
  container_image = "${module.ecr.repository_url}:latest"

  # Worker is CPU-heavy (BERT fine-tuning). Give it more headroom than the
  # API task so training doesn't starve while the API is also running.
  cpu    = 1024
  memory = 2048

  training_data_bucket_arn = module.s3.bucket_arn
  training_queue_arn       = module.sqs.queue_arn

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
  }

  secrets = {
    DB_PASSWORD = module.ssm_parameters.parameter_arns["db_password"]
  }

  secret_arns = [module.ssm_parameters.parameter_arns["db_password"]]
}

# Allow the worker to reach RDS on 5432.
# The RDS module only accepts one primary SG; this rule adds the worker as
# a second trusted source without modifying the module interface.
resource "aws_vpc_security_group_ingress_rule" "rds_from_worker" {
  security_group_id            = module.rds.security_group_id
  referenced_security_group_id = module.ecs_worker.worker_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "Allow training worker to reach PostgreSQL."
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

output "training_data_bucket" {
  description = "S3 bucket for training data."
  value       = module.s3.bucket_name
}

output "training_queue_url" {
  description = "SQS queue URL for async training triggers."
  value       = module.sqs.queue_url
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint."
  value       = module.rds.endpoint
}

output "ecs_worker_service_name" {
  description = "ECS worker service name used by CI/CD to force worker redeployment."
  value       = module.ecs_worker.worker_service_name
}

output "worker_log_group_name" {
  description = "CloudWatch log group for training worker output."
  value       = module.ecs_worker.worker_log_group_name
}

output "terraform_role_arn" {
  description = "IAM role ARN assumed by the Terraform GitHub workflow."
  value       = try(module.github_oidc_roles[0].terraform_role_arn, null)
}

output "deploy_role_arn" {
  description = "IAM role ARN assumed by the application deploy workflow."
  value       = try(module.github_oidc_roles[0].deploy_role_arn, null)
}
