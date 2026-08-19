resource "aws_cloudwatch_log_group" "app" {
  count             = var.manage_log_group ? 1 : 0
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
  alarm_actions = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  alb_ready     = var.enable_alarms && var.alb_arn_suffix != ""
  ecs_ready     = var.enable_alarms && var.ecs_cluster_name != "" && var.ecs_service_name != ""
  dlq_ready     = var.enable_alarms && var.sqs_dlq_name != ""
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

resource "aws_cloudwatch_metric_alarm" "alb_p95_latency" {
  count = local.alb_ready && var.target_group_arn_suffix != "" ? 1 : 0

  alarm_name          = "${var.log_group_name}/alb-p95-latency-high"
  alarm_description   = "ALB target response p95 exceeds 500 ms for 5 minutes."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = 0.5
  treat_missing_data  = "notBreaching"

  metric_name        = "TargetResponseTime"
  namespace          = "AWS/ApplicationELB"
  period             = 60
  extended_statistic = "p95"
  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "api_cpu_high" {
  count = local.ecs_ready ? 1 : 0

  alarm_name          = "${var.log_group_name}/api-cpu-high"
  alarm_description   = "API service CPU exceeds 80 percent for 5 minutes."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = 80
  treat_missing_data  = "notBreaching"

  metric_name = "CPUUtilization"
  namespace   = "AWS/ECS"
  period      = 60
  statistic   = "Average"
  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions
}

resource "aws_cloudwatch_dashboard" "service" {
  dashboard_name = var.dashboard_name

  dashboard_body = jsonencode({
    start          = "-PT6H"
    periodOverride = "inherit"
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title = "API latency and request volume", region = var.aws_region, view = "timeSeries", period = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.target_group_arn_suffix, { stat = "p95", label = "p95 latency" }],
            [".", "RequestCount", ".", ".", ".", ".", { stat = "Sum", yAxis = "right", label = "requests/min" }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title = "API errors", region = var.aws_region, view = "timeSeries", period = 60
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum" }],
            [".", "HTTPCode_Target_4XX_Count", ".", ".", { stat = "Sum" }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title = "ECS API and worker utilization", region = var.aws_region, view = "timeSeries", period = 60
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name, { stat = "Average", label = "API CPU" }],
            [".", ".", ".", ".", ".", var.worker_service_name, { stat = "Average", label = "Worker CPU" }],
            [".", "MemoryUtilization", ".", ".", ".", var.ecs_service_name, { stat = "Average", label = "API memory" }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title = "Training queue and DLQ", region = var.aws_region, view = "timeSeries", period = 60
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.sqs_queue_name, { stat = "Maximum", label = "queued" }],
            [".", ".", ".", var.sqs_dlq_name, { stat = "Maximum", label = "DLQ" }],
            [".", "ApproximateAgeOfOldestMessage", ".", var.sqs_queue_name, { stat = "Maximum", yAxis = "right", label = "oldest age" }]
          ]
        }
      },
      {
        type = "log", x = 0, y = 12, width = 24, height = 7
        properties = {
          title = "Recent application errors", region = var.aws_region, view = "table"
          query = "SOURCE '${var.log_group_name}' | fields @timestamp, @message | filter @message like /ERROR|Exception|Traceback/ | sort @timestamp desc | limit 50"
        }
      }
    ]
  })
}
