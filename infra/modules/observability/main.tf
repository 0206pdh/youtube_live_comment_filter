resource "aws_cloudwatch_log_group" "app" {
  name              = var.log_group_name
  retention_in_days = var.retention_in_days

  tags = {
    Name = var.log_group_name
  }
}

# ---------------------------------------------------------------------------
# Phase 4: CloudWatch Alarms (SLO.md § 7 — Alarm criteria)
# ---------------------------------------------------------------------------
# All alarms are created only when enable_alarms = true AND the required
# dimension variable is provided. This keeps the module safe to use in
# environments that have not yet wired up ALB/ECS/SQS references.

locals {
  alarm_actions      = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  alb_ready          = var.enable_alarms && var.alb_arn_suffix != ""
  ecs_ready          = var.enable_alarms && var.ecs_cluster_name != "" && var.ecs_service_name != ""
  dlq_ready          = var.enable_alarms && var.sqs_dlq_name != ""
}

# --- ALB: 5xx error rate ---------------------------------------------------
# Fires when the ALB returns ≥ 10 HTTP 5xx responses in a 1-minute window.
# A sustained spike here means ECS tasks are crashing or returning errors.

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  count = local.alb_ready ? 1 : 0

  alarm_name          = "${var.log_group_name}/alb-5xx-high"
  alarm_description   = "ALB HTTP 5xx count > 10 in 1 min — ECS tasks may be crashing."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 10
  treat_missing_data  = "notBreaching"

  metric_name = "HTTPCode_Target_5XX_Count"
  namespace   = "AWS/ApplicationELB"
  period      = 60
  statistic   = "Sum"
  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = {
    SLO = "availability"
  }
}

# --- ECS: running task count = 0 ------------------------------------------
# Fires when zero API tasks are running. This is the "total outage" alarm
# and should trigger an immediate response per RUNBOOK.md.

resource "aws_cloudwatch_metric_alarm" "ecs_no_tasks" {
  count = local.ecs_ready ? 1 : 0

  alarm_name          = "${var.log_group_name}/ecs-running-tasks-zero"
  alarm_description   = "ECS API service has 0 running tasks — service is down."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  threshold           = 1
  treat_missing_data  = "breaching"

  metric_name = "RunningTaskCount"
  namespace   = "ECS/ContainerInsights"
  period      = 60
  statistic   = "Average"
  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = {
    SLO = "availability"
  }
}

# --- SQS DLQ: messages visible > 0 ----------------------------------------
# Fires when the training DLQ receives any messages. This means a training
# job failed after exhausting all retries — requires manual investigation.

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  count = local.dlq_ready ? 1 : 0

  alarm_name          = "${var.log_group_name}/training-dlq-not-empty"
  alarm_description   = "Training DLQ has messages — a training job failed permanently."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  treat_missing_data  = "notBreaching"

  metric_name = "ApproximateNumberOfMessagesVisible"
  namespace   = "AWS/SQS"
  period      = 300
  statistic   = "Maximum"
  dimensions = {
    QueueName = var.sqs_dlq_name
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = {
    SLO = "training-pipeline"
  }
}
