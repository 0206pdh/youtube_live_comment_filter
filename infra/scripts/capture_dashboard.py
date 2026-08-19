"""Capture CloudWatch metric widgets as PNG evidence after a test run."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import boto3


def widget(title: str, region: str, metrics: list, y_axis: dict | None = None) -> str:
    body = {
        "width": 1200,
        "height": 500,
        "start": "-PT3H",
        "end": "P0D",
        "timezone": "+0900",
        "view": "timeSeries",
        "stacked": False,
        "region": region,
        "title": title,
        "period": 60,
        "metrics": metrics,
    }
    if y_axis:
        body["yAxis"] = y_axis
    return json.dumps(body)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--region", default="ap-northeast-2")
    parser.add_argument("--cluster", required=True)
    parser.add_argument("--api-service", required=True)
    parser.add_argument("--worker-service", required=True)
    parser.add_argument("--load-balancer-suffix", required=True)
    parser.add_argument("--target-group-suffix", required=True)
    parser.add_argument("--queue-name", required=True)
    parser.add_argument("--dlq-name", required=True)
    parser.add_argument("--out-dir", default="artifacts/cloudwatch")
    args = parser.parse_args()

    output = Path(args.out_dir)
    output.mkdir(parents=True, exist_ok=True)
    cloudwatch = boto3.client("cloudwatch", region_name=args.region)

    widgets = {
        "01-api-latency.png": widget(
            "API target latency",
            args.region,
            [
                ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", args.load_balancer_suffix, "TargetGroup", args.target_group_suffix, {"stat": "p50"}],
                ["...", {"stat": "p95"}],
                ["...", {"stat": "p99"}],
            ],
        ),
        "02-api-traffic-errors.png": widget(
            "API traffic and errors",
            args.region,
            [
                ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", args.load_balancer_suffix, {"stat": "Sum", "label": "requests"}],
                [".", "HTTPCode_Target_5XX_Count", ".", ".", {"stat": "Sum", "label": "5xx"}],
                [".", "HTTPCode_Target_4XX_Count", ".", ".", {"stat": "Sum", "label": "4xx"}],
            ],
        ),
        "03-ecs-utilization.png": widget(
            "ECS API and worker utilization",
            args.region,
            [
                ["AWS/ECS", "CPUUtilization", "ClusterName", args.cluster, "ServiceName", args.api_service, {"stat": "Average", "label": "API CPU"}],
                [".", ".", ".", ".", ".", args.worker_service, {"stat": "Average", "label": "Worker CPU"}],
                [".", "MemoryUtilization", ".", ".", ".", args.api_service, {"stat": "Average", "label": "API memory"}],
                [".", ".", ".", ".", ".", args.worker_service, {"stat": "Average", "label": "Worker memory"}],
            ],
            {"left": {"min": 0, "max": 100}},
        ),
        "04-training-queue.png": widget(
            "Training queue and DLQ",
            args.region,
            [
                ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", args.queue_name, {"stat": "Maximum", "label": "queue"}],
                [".", ".", ".", args.dlq_name, {"stat": "Maximum", "label": "DLQ"}],
                [".", "ApproximateAgeOfOldestMessage", ".", args.queue_name, {"stat": "Maximum", "label": "oldest age"}],
            ],
        ),
    }

    for filename, metric_widget in widgets.items():
        response = cloudwatch.get_metric_widget_image(MetricWidget=metric_widget)
        (output / filename).write_bytes(response["MetricWidgetImage"])
        print(output / filename)


if __name__ == "__main__":
    main()
