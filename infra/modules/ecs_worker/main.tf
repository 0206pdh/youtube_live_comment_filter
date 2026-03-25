# Training Worker ECS service.
#
# Runs as a single Fargate task that polls the SQS training queue and
# executes server/worker.py. No ALB — outbound-only traffic to SQS, S3,
# and RDS.
#
# Phase 3 rationale: separating training from the inference API means
# BERT fine-tuning never competes for CPU with /predict requests.

data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# --- Execution role (pulls image, reads SSM secrets) ----------------------

resource "aws_iam_role" "execution" {
  name               = "${var.name}-worker-execution-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "execution_default" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_ssm" {
  name = "${var.name}-worker-execution-ssm"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameters", "ssm:GetParameter"]
      Resource = var.secret_arns
    }]
  })
}

# --- Task role (runtime AWS API calls) ------------------------------------

resource "aws_iam_role" "task" {
  name               = "${var.name}-worker-task-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy" "task_data" {
  name = "${var.name}-worker-task-data"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Read labelled data files and write versioned model artifacts
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
        ]
        Resource = [
          var.training_data_bucket_arn,
          "${var.training_data_bucket_arn}/*",
        ]
      },
      {
        # Consume jobs from the training queue
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = [var.training_queue_arn]
      },
    ]
  })
}

# --- CloudWatch log group -------------------------------------------------

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/${var.name}-worker"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "/ecs/${var.name}-worker"
  }
}

# --- Security group (egress only) ----------------------------------------

resource "aws_security_group" "worker" {
  name_prefix = "${var.name}-worker-"
  description = "Training worker — egress only (SQS/S3 via HTTPS, RDS on 5432)."
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic."
  }

  tags = { Name = "${var.name}-worker-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Task definition ------------------------------------------------------

locals {
  container_environment = [
    for k, v in var.environment : { name = k, value = v }
  ]
  container_secrets = [
    for k, v in var.secrets : { name = k, valueFrom = v }
  ]
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "worker"
    image     = var.container_image
    essential = true

    # Override the API server CMD; worker.py is bundled in the same image.
    command = ["python", "/app/server/worker.py"]

    environment = local.container_environment
    secrets     = local.container_secrets

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.worker.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "worker"
      }
    }
  }])
}

# --- ECS service ----------------------------------------------------------

resource "aws_ecs_service" "worker" {
  name            = "${var.name}-worker"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # No load balancer — this service only polls SQS outbound.
  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.worker.id]
    assign_public_ip = var.assign_public_ip
  }
}
